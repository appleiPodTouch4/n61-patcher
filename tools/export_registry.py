#!/usr/bin/env python3
"""把 Python 补丁注册表导出成 bash 版读取的静态数据。

改动 patches/*.py 之后跑一次：
    python3 tools/export_registry.py

产出：
    patches/registry.tsv          补丁元数据（layer/role/id/feature/scope/requires/after/manual/note）
    patches/overlays/<id>.conf    SourceOverlay 的文件清单（Phase B 的 overlay 引擎消费）
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

from core import patch as patchmod          # noqa: E402
from core.overlay import SourceOverlay      # noqa: E402


def export():
    patches = patchmod.discover()
    os.makedirs(os.path.join(REPO, "patches/overlays"), exist_ok=True)
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
        if isinstance(p, SourceOverlay):
            items = []
            for it in p.items:
                items.append("\t".join([
                    it.source, it.dest, it.op,
                    "" if it.mode is None else "%o" % it.mode,
                    "" if it.uid is None else str(it.uid),
                    "" if it.gid is None else str(it.gid),
                    "" if it.offset is None else "0x%x" % it.offset,
                    it.before or "", it.after or "",
                    ",".join(sorted(it.check.keys())) if it.check else "",
                ]))
            with open(os.path.join(REPO, "patches/overlays/%s.conf" % p.id), "w") as f:
                f.write("\n".join(items) + "\n")
    with open(os.path.join(REPO, "patches/registry.tsv"), "w") as f:
        f.write("\n".join(rows) + "\n")
    print("导出 %d 个补丁 → patches/registry.tsv" % len(rows))


if __name__ == "__main__":
    export()
