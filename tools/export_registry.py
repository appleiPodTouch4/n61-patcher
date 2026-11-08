#!/usr/bin/env python3
"""把 Python 补丁注册表导出成 bash 版读取的静态数据。

改动 patches/*.py 之后跑一次：
    python3 tools/export_registry.py

产出：
    patches/registry.tsv          补丁元数据（layer/role/id/feature/scope/requires/after/manual/note）
    patches/overlays/<id>.conf    SourceOverlay 的文件清单（bash overlay 引擎消费）
    patches/lists/<id>.paths      overlay 的固定路径表（UI 资源类，bash 按 donor 实况展开）
    patches/blobs.tsv             二进制补丁（installd / backupd / bluetoothd）元数据
    patches/blobs/<id>.conf       二进制补丁的字节替换行（offset/before/after）
"""
import importlib
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

from core import patch as patchmod          # noqa: E402
from core.overlay import SourceOverlay      # noqa: E402


def write_dir(rel):
    path = os.path.join(REPO, rel)
    os.makedirs(path, exist_ok=True)
    return path


def export_overlays(patches):
    out = write_dir("patches/overlays")
    lists = write_dir("patches/lists")
    count = 0
    for cls in patches:
        p = cls()
        if not isinstance(p, SourceOverlay):
            continue
        # check 的取值决定是否校验（exists/nonzero 缺省为真，delete 条目显式关掉），
        # 早先只导出了键名，bash 端无法区分，这里带值导出。
        items = []
        for it in p.items:
            check = ",".join(
                "%s=%d" % (k, 1 if v else 0) for k, v in sorted(it.check.items())
            ) if it.check else ""
            items.append("\t".join([
                it.source, it.dest, it.op,
                "" if it.mode is None else "%o" % it.mode,
                "" if it.uid is None else str(it.uid),
                "" if it.gid is None else str(it.gid),
                "" if it.offset is None else "0x%x" % it.offset,
                it.before or "", it.after or "",
                check,
            ]))
        path = os.path.join(out, "%s.conf" % p.id)
        if items:
            with open(path, "w") as f:
                f.write("\n".join(items) + "\n")
            count += 1
        elif os.path.exists(path):
            os.unlink(path)          # 动态清单：条目在运行期展开

        paths = getattr(cls, "PATHS", None)
        if paths is None:
            # 注册表用的是装载器注入的合成模块名，按 id 回源到真实模块
            module = sys.modules.get(cls.__module__)
            if module is None:
                try:
                    module = importlib.import_module(
                        "patches.rootfs." + p.id.split(".", 1)[1])
                except Exception:
                    module = None
            paths = getattr(module, "PATHS", None) if module else None
        if paths:
            with open(os.path.join(lists, "%s.paths" % p.id), "w") as f:
                f.write("\n".join(paths) + "\n")
    print("overlay 清单: %d 个静态项" % count)


def export_blobs():
    """二进制补丁：固定偏移字节替换（+ 可选重签名）。"""
    from patches.impl.rootfs import (backupd_empty_snapshot as bk,
                                     installd_empty_containers as ic)

    rows, blobs = [], []

    def emit(pid, src, kind, sign, size, sha, out_size, out_sha, edits):
        rows.append("\t".join([
            pid, src, kind, "1" if sign else "0",
            "" if size is None else str(size), sha or "",
            "" if out_size is None else str(out_size), out_sha or "",
        ]))
        blobs.append((pid, edits))

    emit("installd-empty-containers", ic.SOURCE, "j96", True, None, None, None, None,
         [("0x%x" % ic.OFFSET, ic.BEFORE.hex(), ic.AFTER.hex())])
    emit("backupd-empty-snapshot", bk.SOURCE, "j96", True, None, None, None, None,
         [("0x%x" % bk.OFFSET, bk.BEFORE.hex(), bk.AFTER.hex())])

    manifest_path = os.path.join(
        REPO, "patches/impl/rootfs/bluetoothd-16H88-xpc13.json")
    manifest = json.load(open(manifest_path))
    edits = [("0x%x" % e["offset"], e["before"], e["after"]) for e in manifest["patches"]]
    emit("bluetoothd", "usr/sbin/bluetoothd", "device_s1", False,
         manifest["source_size"], manifest["source_sha256"],
         manifest["output_size"], manifest["output_sha256"], edits)

    out = write_dir("patches/blobs")
    for pid, edits in blobs:
        with open(os.path.join(out, "%s.conf" % pid), "w") as f:
            f.write("\n".join("\t".join(e) for e in edits) + "\n")
    with open(os.path.join(REPO, "patches/blobs.tsv"), "w") as f:
        f.write("\n".join(rows) + "\n")
    print("二进制补丁: %d 个（%d 处替换）" %
          (len(rows), sum(len(e) for _, e in blobs)))


def export_kc():
    """内核补丁的静态数据：bash 版只移植算法，数据和地址表从这里导出。"""
    out = write_dir("patches/kcdata")

    # legacy_sep：VA + before/after（两条硬编码在 kc/legacy_sep.py 里）
    import struct
    legacy = [
        ("fffffff0069123d8", "686a40f9088d42f9",
         struct.pack('<II', 0x52800008, 0x14000069).hex()),
        ("fffffff006a14d7c", "ff8300d1fd7b01a9",
         struct.pack('<II', 0x52800000, 0xd65f03c0).hex()),
    ]
    profile = json.load(open(os.path.join(
        REPO, "patches/impl/kc/legacy_data.json")))
    for p in profile["patches"]:
        legacy.append((p["address"][2:].lower(), p["before"], p["after"]))
    with open(os.path.join(out, "legacy-sep.tsv"), "w") as f:
        f.write("\n".join("\t".join(r) for r in legacy) + "\n")

    # mt_n56：J96 personality → N56/N61，等长就地替换
    from patches.impl.kc import mt_n56 as mt
    rows = []
    for board, edits in sorted(mt.PROFILES.items()):
        rows.append((board, "anchor", mt.ANCHOR.hex(), ""))
        rows.append((board, "end", b"</dict></dict>".hex(), ""))
        for old, new in edits:
            assert len(old) == len(new)
            rows.append((board, "edit", old.hex(), new.hex()))
    with open(os.path.join(out, "mt_n56.tsv"), "w") as f:
        f.write("\n".join("\t".join(r) for r in rows) + "\n")

    # kerninfo：BSD 初始化里发布 offsetcache 的载荷（常量 + 表项）
    from patches.impl.kc import kerninfo as ki
    rows = [(name, "%x" % value, kind) for name, value, kind in ki.ENTRIES]
    with open(os.path.join(out, "kerninfo.tsv"), "w") as f:
        f.write("# name\tvalue\tkind\n")
        f.write("\n".join("\t".join(r) for r in rows) + "\n")
        f.write("# const\tUNSLID_KERNEL_TASK=%x\n" % ki.UNSLID_KERNEL_TASK)
        f.write("# const\tUNSLID_VM_KERNEL_SLIDE=%x\n" % ki.UNSLID_VM_KERNEL_SLIDE)
        f.write("# const\tUNSLID_KERNEL_BASE=%x\n" % ki.UNSLID_KERNEL_BASE)
        f.write("# const\tTASK_OFF_AI_ADDR=%x\n" % ki.TASK_OFF_AI_ADDR)
        f.write("# const\tTASK_OFF_AI_SIZE=%x\n" % ki.TASK_OFF_AI_SIZE)
        f.write("# const\tDATA_FOFF=%x\n" % ki.DATA_FOFF)
        f.write("# const\tDATA_CAPACITY=%x\n" % ki.DATA_CAPACITY)
        f.write("# const\tUNSLID_FLAGS_KADDR=%x\n" % ki.UNSLID_FLAGS_KADDR)
        f.write("# const\tSHELLCODE_VMADDR=%x\n" % ki.SHELLCODE_VMADDR)
        f.write("# const\tSHELLCODE_FOFF=%x\n" % ki.SHELLCODE_FOFF)
        f.write("# const\tHOOK_VMADDR=%x\n" % ki.HOOK_VMADDR)
        f.write("# const\tHOOK_FOFF=%x\n" % ki.HOOK_FOFF)

    print("内核补丁数据: legacy-sep %d 项 / mt_n56 %d 项 / kerninfo %d 项"
          % (len(legacy), len(rows), len(ki.ENTRIES)))


def export():
    patches = patchmod.discover()
    rows = []
    for cls in patches:
        p = cls()
        rows.append("\t".join([
            p.layer, p.role, p.id, p.feature, p.scope,
            ",".join(getattr(p, "requires", ()) or ()),
            ",".join(getattr(p, "after", ()) or ()),
            "1" if getattr(p, "manual", False) else "0",
            (getattr(p, "note", "") or "").replace("\t", " "),
        ]))
    with open(os.path.join(REPO, "patches/registry.tsv"), "w") as f:
        f.write("\n".join(rows) + "\n")
    print("导出 %d 个补丁 → patches/registry.tsv" % len(rows))
    export_overlays(patches)
    export_blobs()
    export_kc()


if __name__ == "__main__":
    export()
