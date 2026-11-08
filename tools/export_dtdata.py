#!/usr/bin/env python3
"""导出 bash 版 DeviceTree（dt.base）所需的静态数据。

    python3 tools/export_dtdata.py [--golden build/golden-py] [--board n61ap]

dt.base 是把「本机 iOS12.5.8 设备树（DT12）」改造成「目标板 iOS13 设备树」的一整套
JSON 手术（patches/impl/dt/dt_patch.py，含节点移植、phandle 重编号、/chosen 属性、
/filesystems/fstab 等）。bash 侧不做 JSON 手术，而是把 Python 版产出的 JSONC 作为
资产随仓库保存，运行期用仓库自带的 devicetree-repack 重新打包成二进制：

    DT12.jsonc  ──(Python 版手术，离线一次性)──▶  DeviceTree.<board>_native.jsonc
                                                 │
                          devicetree-repack ─────┘──▶ .bin ── img4 -T rdtr ──▶ boot_DT.img4

导出时做两件事：
  1. 记录两个输入 JSONC 的 sha256 —— 输入一变就说明资产过期，运行期会直接报错；
  2. 回放校验：用 devicetree-repack 把资产 JSONC 打成 .bin，与 Python 版的 .bin
     逐字节比对（顺带记录 .bin 的 sha256，运行期打完包再校验一次）。
"""

import argparse
import hashlib
import shutil
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DTD = REPO / "patches/dtdata"


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--golden", type=Path, default=REPO / "build/golden-py",
                    help="含 DeviceTree.<board>_native.{jsonc,bin} 的目录")
    ap.add_argument("--board", default="n61ap")
    args = ap.parse_args()
    board = args.board

    dt12 = REPO / f"ipsw/cache/derived/extracted/{board}_ios12/DeviceTree.{board}.jsonc"
    n66 = REPO / "ipsw/cache/derived/extracted/n66ap_ios13/DeviceTree.n66ap.jsonc"
    src_jsonc = args.golden / f"DeviceTree.{board}_native.jsonc"
    src_bin = args.golden / f"DeviceTree.{board}_native.bin"
    for path in (dt12, n66, src_jsonc, src_bin):
        if not path.is_file():
            raise SystemExit("缺少文件: %s" % path)

    DTD.mkdir(parents=True, exist_ok=True)
    out_jsonc = DTD / f"DeviceTree.{board}_native.jsonc"
    shutil.copyfile(src_jsonc, out_jsonc)

    # 回放：JSONC → bin，必须与 Python 版产物逐字节相同
    repack = REPO / "tools/devicetree-parse/devicetree-repack"
    tmp = DTD / f".replay-{board}.bin"
    import subprocess
    subprocess.run([str(repack), str(out_jsonc), str(tmp)], check=True,
                   capture_output=True)
    replay = tmp.read_bytes()
    expect = src_bin.read_bytes()
    tmp.unlink()
    if replay != expect:
        raise SystemExit(f"{board}: devicetree-repack 回放与 Python 产物不一致")

    meta = DTD / f"{board}.meta"
    meta.write_text(
        "board=%s\n"
        "in_dt12_sha=%s\n"
        "in_n66_sha=%s\n"
        "jsonc=%s\n"
        "out_bin_sha=%s\n"
        "out_bin_size=%d\n"
        % (board, sha256(dt12), sha256(n66), out_jsonc.name,
           sha256(src_bin), len(expect)))
    print("dt         %s：资产 %d 字节，回放通过（bin %d 字节）"
          % (board, out_jsonc.stat().st_size, len(expect)))


if __name__ == "__main__":
    main()
