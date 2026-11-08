#!/bin/bash
# 逐阶段生成 Python 版的「黄金链」，供 bash 移植导出静态数据 / 对拍。
#
#   tools/golden_kc_chain.sh [--out DIR] [--checkra1n]
#
# 默认从 j96 干净内核起跑完整 8 个变换；--checkra1n 时先在基底上叠加 checkra1n KPF
# 与 kerninfo（即默认 features 的真实现），再从 kc.kerninfo.raw 继续。
#
# 产物目录随后喂给导出工具：
#   python3 tools/export_kcdata.py --chain <DIR>
#   python3 tools/export_dtdata.py            # 设备树走另一条（golden-py 目录）
#
# 注意：这里刻意用 Python 实现而不是 bash，导入数据时才有一个独立参照。
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/kc-golden"
WITH_CHECKRA1N=0
BOARD="n61ap"
MODEL="n61"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift ;;
        --checkra1n) WITH_CHECKRA1N=1 ;;
        --board) BOARD="$2"; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$OUT"
export N56_DONORS="$REPO/donors"
export N56_DERIVED="$REPO/ipsw/cache/derived"
export N56_WORK="$OUT"
export N56_BOARD="$BOARD"
export N56_MODEL="$MODEL"
export PYTHONPATH="$REPO/patches/impl:$REPO/patches/impl/common:$REPO/patches/impl/kc/sn2400:$REPO/patches/impl/kc/vibration:$REPO/tools/bin/pydeps"

step() { printf '\n=== %s\n' "$*"; }
big() { /usr/bin/stat -f %z "$1"; }

# ---- 1. j96 干净内核 ----
if [ ! -f "$OUT/kc.j96.clean.raw" ]; then
    step "img4 -i → kc.j96.raw"
    "$REPO/tools/img4lib/img4" -i \
        "$REPO/ipsw/cache/derived/extracted/j96ap_ios13/kernelcache.release.ipad5" \
        -o "$OUT/kc.j96.raw" >/dev/null || exit 1
    step "KPlooshFinder"
    "$REPO/tools/SSHRD_Script/Darwin/KPlooshFinder" \
        "$OUT/kc.j96.raw" "$OUT/kc.j96.kploosh" >/dev/null 2>&1 || exit 1
    step "Kernel64Patcher -b13 -n"
    "$REPO/tools/dualra1n/binaries/Darwin/Kernel64Patcher" \
        "$OUT/kc.j96.kploosh" "$OUT/kc.j96.clean.raw" -b13 -n >/dev/null 2>&1 || exit 1
    python3 - "$OUT" <<'PY'
import sys
from pathlib import Path
o = Path(sys.argv[1])
raw = (o / "kc.j96.raw").read_bytes()
out = bytearray((o / "kc.j96.clean.raw").read_bytes())
out[0xaa6577] = raw[0xaa6577]
(o / "kc.j96.clean.raw").write_bytes(out)
print("restored 0xaa6577 =", hex(raw[0xaa6577]))
PY
fi

CUR="$OUT/kc.j96.clean.raw"

# ---- 2.（可选）checkra1n KPF 合并 + kerninfo ----
if [ "$WITH_CHECKRA1N" = "1" ] && [ ! -f "$OUT/kc.kerninfo.raw" ]; then
    step "checkra1n KPF 合并 + kerninfo"
    python3 - "$REPO" "$OUT" <<'PY' || exit 1
import sys
from pathlib import Path
repo, out = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(repo))

class Ctx:
    """只给 apply_profile 用的最小上下文。"""
    t = {"features": ["checkra1n"]}
    def wk(self, name):
        return str(out / name)

from patches.impl.kc.checkra1n import apply_profile
from patches.impl.kc.kerninfo import apply as apply_kerninfo

ctx = Ctx()
merged = apply_profile(ctx, str(out / "kc.j96.raw"), str(out / "kc.j96.clean.raw"))
(out / "kc.kerninfo.raw").write_bytes(apply_kerninfo(Path(merged).read_bytes()))
print("kerninfo ->", out / "kc.kerninfo.raw")
PY
fi
[ -f "$OUT/kc.kerninfo.raw" ] && CUR="$OUT/kc.kerninfo.raw"

# ---- 3. 变换链（顺序与 ./n61.sh list 一致）----
run_flat() {   # name script
    [ -f "$OUT/kc.$1.raw" ] && { step "$1（已存在）"; CUR="$OUT/kc.$1.raw"; return 0; }
    step "$1"
    N56_INPUT="$CUR" N56_OUTPUT="$OUT" \
        python3 "$REPO/patches/impl/kc/$2" "$CUR" "$OUT/kc.$1.raw" || exit 1
    CUR="$OUT/kc.$1.raw"
}

run_dir() {   # name script extra
    [ -f "$OUT/kc.$1.raw" ] && { step "$1（已存在）"; CUR="$OUT/kc.$1.raw"; return 0; }
    step "$1"
    mkdir -p "$OUT/$1"
    N56_INPUT="$CUR" N56_OUTPUT="$OUT/$1" \
        python3 "$REPO/patches/impl/kc/$2" --input "$CUR" --out "$OUT/$1" $3 || exit 1
    cp "$OUT/$1/kernelcache.$1.raw" "$OUT/kc.$1.raw"
    CUR="$OUT/kc.$1.raw"
}

run_flat pmu        pmu_d2186.py
run_dir  sn2400     sn2400/port.py            --write
run_dir  chestnut   chestnut/transplant.py    ""
run_flat mt         mt_n56.py
run_dir  wifi       wifi/hashstore_patch.py   ""
run_dir  vibration  vibration/transplant.py   ""
run_flat legacy-sep legacy_sep.py
run_dir  audio      audio/transplant_audio.py ""

step "完成"
for f in "$OUT"/kc.*.raw; do
    printf '%-28s %10s  %s\n' "$(basename "$f")" "$(big "$f")" \
        "$(shasum -a 256 "$f" | cut -c1-16)"
done
echo
echo "下一步：python3 tools/export_kcdata.py --chain $OUT"
