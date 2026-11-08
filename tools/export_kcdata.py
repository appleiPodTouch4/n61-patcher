#!/usr/bin/env python3
"""导出 bash 版内核缓存（kernelcache）补丁阶段所需的静态改写数据。

    python3 tools/export_kcdata.py --chain <黄金链目录>

`<黄金链目录>` 由 Python 版逐阶段产出（kc.j96.clean.raw → kc.pmu.raw → …），
文件名约定见 STAGES。工具会把每个阶段「输入 → 输出」的差异拆成两部分：

1. `patches/kcdata/<stage>.writes.tsv` —— 预链接 plist 段之外的全部改写，
   按偏移/字节给出（kext 代码搬迁、头命令、指针槽等）。
2. plist 段本身：
   - `surgery`：只存插入的那段 kext 字典与新增的 KASLR 槽，运行期用
     「base64 替换 + 定点插入」复现（sn2400 / chestnut / vibration）；
   - `blob`：整段以 gzip 存下（audio，它的 plist 是被 ElementTree 整段重排的，
     逐字节复现不值当）。

导出后会用同一套规则把每个阶段重放一遍，与黄金产物逐字节比对，不一致就报错。
"""

import argparse
import base64
import gzip
import hashlib
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
KCD = REPO / "patches/kcdata"
KEY_KASLR = b"_PrelinkLinkKASLROffsets"
KEY_INFO = b"_PrelinkInfoDictionary"

# stage → (前一阶段的产物文件名, 本阶段产物文件名, plist 处理方式, 是否先做字符串内联)
# 顺序必须与 kc_transform 的实际执行顺序一致（注册表拓扑序）：
#   pmu → sn2400 → chestnut → mt → wifi → vibration → legacy_sep → audio
# 只有「静态改写表」阶段在这里；pmu / mt / wifi / legacy_sep 是算法阶段，不导出数据。
STAGES = [
    ("sn2400", "kc.pmu.raw", "kc.sn2400.raw", "surgery", False),
    ("chestnut", "kc.sn2400.raw", "kc.chestnut.raw", "surgery", False),
    ("vibration", "kc.wifi.raw", "kc.vibration.raw", "surgery", True),
    ("audio", "kc.legacy-sep.raw", "kc.audio.raw", "blob", False),
]


# ---------------------------------------------------------------- Mach-O
def segments(data):
    n, _ = struct.unpack_from("<II", data, 16)
    off, out = 32, []
    for _ in range(n):
        cmd, length = struct.unpack_from("<II", data, off)
        if cmd == 25:
            name = data[off + 8:off + 24].rstrip(b"\0").decode()
            vm, vs, fo, fs = struct.unpack_from("<QQQQ", data, off + 24)
            out.append(dict(name=name, vm=vm, vs=vs, fo=fo, fs=fs))
        off += length
    return out


def seg_by_name(segs, name):
    return next(s for s in segs if s["name"] == name)


def plist_xml(data):
    s = seg_by_name(segments(data), "__PRELINK_INFO")
    return data[s["fo"]:s["fo"] + s["fs"]].rstrip(b"\0")


def kaslr_words(xml):
    k = xml.index(KEY_KASLR)
    s = xml.index(b"<data>", k) + 6
    e = xml.index(b"</data>", s)
    raw = base64.b64decode(xml[s:e])
    return struct.unpack("<" + "I" * (len(raw) // 4), raw), (s, e)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------- 差异切分
def writes_of(before, after, skip):
    """返回 [(offset, bytes)]，跳过 skip=(lo,hi) 区间；相邻/近邻差异合并成段。"""
    lo, hi = skip
    out, i, n = [], 0, len(before)
    while i < n:
        if before[i] == after[i] or lo <= i < hi:
            i += 1
            continue
        start = i
        while i < n and i - start < 4096:
            if lo <= i < hi:
                break
            if before[i] != after[i]:
                i += 1
                continue
            # 差异之间的小空洞并进来（同段改写，省条目）
            gap = 0
            while i + gap < n and gap < 8 and not (lo <= i + gap < hi) \
                    and before[i + gap] == after[i + gap]:
                gap += 1
            if gap >= 8 or i + gap >= n:
                break
            i += gap
        out.append((start, after[start:i]))
    return out


# ---------------------------------------------------------------- plist 手术
def intern_strings(xml):
    """与 vibration/transplant.py 的 intern_strings 等价：共享重复长字符串。"""
    import re
    counts = {}
    for m in re.finditer(rb"<string>([^<]*)</string>", xml):
        counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    ids = [int(x) for x in re.findall(rb' ID="([0-9]+)"', xml)]
    next_id = [max(ids, default=-1) + 1]
    shared = {}

    def replace(m):
        value = m.group(1)
        if len(value) < 12 or counts[value] < 3:
            return m.group(0)
        if value in shared:
            return b'<string IDREF="' + shared[value] + b'"/>'
        identifier = str(next_id[0]).encode()
        next_id[0] += 1
        shared[value] = identifier
        return b'<string ID="' + identifier + b'">' + value + b"</string>"

    return re.sub(rb"<string>([^<]*)</string>", replace, xml)


def apply_plist(xml, added, blob, base, intern=False):
    """按 patch_plist 的规则改写：先（可选）内联字符串，再换 KASLR 表、插入字典。"""
    if intern:
        xml = intern_strings(xml)
    words, (s, e) = kaslr_words(xml)
    old = list(words[1:])
    offsets = old + [a - base for a in added]
    payload = struct.pack("<" + "I" * (len(offsets) + 1), len(offsets), *offsets)
    xml = xml[:s] + base64.b64encode(payload) + xml[e:]
    at = xml.index(b"<array>", xml.index(KEY_INFO)) + 7
    return xml[:at] + blob + xml[at:]


# ---------------------------------------------------------------- 导出
def export_one(chain, name, prev, cur, mode, intern):
    before = (chain / prev).read_bytes()
    after = (chain / cur).read_bytes()
    pi = seg_by_name(segments(before), "__PRELINK_INFO")
    skip = (pi["fo"], pi["fo"] + pi["fs"])
    writes = writes_of(before, after, skip)

    xml_before, xml_after = plist_xml(before), plist_xml(after)
    base = seg_by_name(segments(before), "__PRELINK_TEXT")["vm"]
    meta = dict(in_sha=sha256(before), out_sha=sha256(after), plist_mode=mode,
                plist_intern="1" if intern else "0")

    if mode == "blob":
        (KCD / (name + ".plist.gz")).write_bytes(gzip.compress(xml_after, 9))
        meta["plist_gz"] = name + ".plist.gz"
        rebuilt = xml_after
    else:
        # 新增 KASLR 槽 = 表尾多出来的那一段
        w_before, _ = kaslr_words(xml_before)
        w_after, _ = kaslr_words(xml_after)
        old_n = w_before[0]
        added = [base + v for v in w_after[1 + old_n:]]
        # 插入的字典：把 KASLR 块抹平后，比较「插入点之后」的长度差
        norm = intern_strings(xml_before) if intern else xml_before
        _, (s, e) = kaslr_words(norm)
        a = norm[:s] + b"@@" + norm[e:]
        _, (s2, e2) = kaslr_words(xml_after)
        b = xml_after[:s2] + b"@@" + xml_after[e2:]
        grow = len(b) - len(a)
        at = a.index(b"<array>", a.index(KEY_INFO)) + 7
        if grow <= 0 or a[:at] != b[:at] or a[at:] != b[at + grow:]:
            raise SystemExit(f"{name}: plist 变更不是「单点插入 + KASLR 表重写」"
                             "（需要改回 blob 存储）")
        blob = b[at:at + grow]
        (KCD / (name + ".dict")).write_bytes(blob)
        meta.update(plist_added=",".join("%016x" % v for v in added),
                    plist_blob=name + ".dict")
        rebuilt = apply_plist(xml_before, added, blob, base, intern)

    # 回放校验：改写表 + plist → 必须与黄金产物逐字节相同
    replay = bytearray(before)
    for off, chunk in writes:
        replay[off:off + len(chunk)] = chunk
    s = pi["fo"]
    replay[s:s + pi["fs"]] = rebuilt.ljust(pi["fs"], b"\0")
    if bytes(replay) != after:
        diff = [i for i in range(len(after)) if replay[i] != after[i]]
        raise SystemExit(f"{name}: 回放与黄金产物不一致，{len(diff)} 字节；"
                         f"首处 0x{diff[0]:x}")

    with open(KCD / (name + ".writes.tsv"), "w") as f:
        for off, chunk in writes:
            f.write("%x\t%s\n" % (off, chunk.hex()))
    meta["writes"] = name + ".writes.tsv"
    with open(KCD / (name + ".meta"), "w") as f:
        for k in ("in_sha", "out_sha", "writes", "plist_mode", "plist_intern",
                  "plist_added", "plist_blob", "plist_gz"):
            if k in meta:
                f.write("%s=%s\n" % (k, meta[k]))
    print("%-10s writes %4d 段 / %7d 字节   plist=%s%s"
          % (name, len(writes), sum(len(c) for _, c in writes), mode,
             "（内联）" if intern else ""))


def export_pmu_tables():
    """D2186 / D2207 的 LDO 电压表（硬件常量，来自 pmu_d2186.py）。"""
    sys.path.insert(0, str(REPO))
    from patches.impl.kc import pmu_d2186 as P
    with open(KCD / "pmu_ldo.tsv", "w") as f:
        f.write("d2186\t%s\n" % P.D2186_LDO_TABLE.hex())
        f.write("d2207\t%s\n" % P.D2207_LDO_TABLE.hex())
    print("pmu        LDO 表（d2186 / d2207）已导出")


# ---------------------------------------------------------------- TrustCache 数据
# bash 版组装完整 TC 需要两份静态数据：
#   trustcache-extra.tsv  —— 原版 TC 之外必须放行的 cdhash（health_toolchain 给的清单）
#   dyld-edits.tsv        —— 离线改 dyld_shared_cache_arm64 的字节补丁（基带 + Health）
TCD = REPO / "patches/tcdata"

HEALTH_DYLD_EDITS = (
    (104, "0100000000000000", "0000000000000000"),
    (1705017567,
     "eb9880e86f1527e1674347bda9933653d3ccfbf4f35b7afc58d9dc03b4c9f7d9",
     "ee66a62a874080f3f2e11f4ee246662faae59cc3fda82a508fd8c64f3ba29d1b"),
)


def export_tcdata(golden):
    import json
    import subprocess

    TCD.mkdir(parents=True, exist_ok=True)
    source = REPO / "patches/impl/rootfs/health_toolchain/trustcache-extra.json"
    data = json.loads(source.read_text())
    with open(TCD / "trustcache-extra.tsv", "w") as f:
        for key in ("full", "repair_v1"):
            for digest in data[key]:
                f.write("%s\t%s\n" % (key, digest))
    print("tc         cdhash 清单 %d 条（full %d / repair_v1 %d）"
          % (len(data["full"]) + len(data["repair_v1"]),
             len(data["full"]), len(data["repair_v1"])))

    from patches.rootfs.baseband import EDITS
    edits = list(EDITS) + list(HEALTH_DYLD_EDITS)
    with open(TCD / "dyld-edits.tsv", "w") as f:
        # 偏移用十进制（与 patches/blobs/*.conf 一致，bash 侧直接 $(( off ))）
        for offset, before, after in edits:
            f.write("%d\t%s\t%s\n" % (offset, before, after))
    print("tc         dyld cache 字节补丁 %d 处" % len(edits))

    # 回放校验：stock TC + full 清单 → 必须等于 Python 的 trustcache.base.raw
    stock = golden / "trustcache.stock.raw"
    expect = golden / "trustcache.base.raw"
    if not (stock.is_file() and expect.is_file()):
        print("tc         跳过回放校验（黄金产物里没有 stock/base）")
        return
    listing = TCD / ".replay-full.txt"
    listing.write_text("".join(d + "\n" for d in data["full"]))
    replay = TCD / ".replay-base.raw"
    subprocess.run(["perl", str(REPO / "lib/trustcache.pl"),
                    str(stock), str(replay), str(listing)], check=True)
    if replay.read_bytes() != expect.read_bytes():
        raise SystemExit("tc: 回放与 Python 的 trustcache.base.raw 不一致")
    listing.unlink()
    replay.unlink()
    print("tc         回放校验通过（与 trustcache.base.raw 逐字节相同）")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--chain", required=True, type=Path,
                    help="含 kc.*.raw 的黄金链目录")
    ap.add_argument("--golden", type=Path, default=REPO / "build/golden-py",
                    help="Python 黄金产物目录（TrustCache 回放校验用）")
    args = ap.parse_args()
    KCD.mkdir(parents=True, exist_ok=True)
    export_pmu_tables()
    for name, prev, cur, mode, intern in STAGES:
        if not (args.chain / cur).is_file():
            raise SystemExit("缺少黄金产物: %s" % (args.chain / cur))
        export_one(args.chain, name, prev, cur, mode, intern)
    export_tcdata(args.golden)
    print("导出完成 →", KCD)


if __name__ == "__main__":
    main()
