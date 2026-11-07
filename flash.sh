#!/usr/bin/env bash
# flash.sh — iPhone 6 / 6 Plus 第二系统刷写流程入口。
#
# 封装 n56patcher.py 的各阶段，默认把 install/build/boot 共享在同一个
# build/<target>-latest 工作目录里，分步执行时 boot 直接复用 build 的产物，
# 不需要手动传 --workdir。
#
# 用法：
#   sudo ./flash.sh all                 # 端到端：安装 → 构建 → 启动
#   sudo ./flash.sh install             # 全新安装（建卷 + 写 rootfs + 收尾）
#   ./flash.sh build                    # 构建启动组件
#   ./flash.sh boot                     # DFU 引导进第二系统
#   ./flash.sh status                   # ramdisk 下列出各卷 role
#   ./flash.sh list                     # 列出当前目标选挂的补丁
#
# 阶段：ramdisk extract-im4m volumes rootfs patch-rootfs install build boot all status list
#
# 选项：
#   --target NAME            目标清单（默认 n61-ios13，N56 用 n56-ios13）
#   --features a,b,c         覆盖 feature 选挂
#   --patches id,id          覆盖 KC 补丁选择（空串 = 基础 KC）
#   --exclude id,id          排除补丁
#   --bootargs "..."         覆盖 boot-args
#   --data-protection MODE   none | encrypted（默认 encrypted）
#   --allow-manual           执行 manual 补丁
#   --dry-run                只演练，不碰设备、不产出
#   --no-identity-check      boot 时不校验设备身份
#   --workdir DIR            自定义工作目录
#   --fresh                  本次用带时间戳的新工作目录（不复用 -latest）
#   -y, --yes                跳过所有确认提示
set -euo pipefail

cd "$(dirname "$0")"

# ---------- 输出 ----------
if [ -t 1 ]; then
    C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
    C_B=$'\033[1;34m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
info() { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$1"; }
ok()   { printf '%s[ok]%s %s\n' "$C_G" "$C_0" "$1"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$1" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$1" >&2; exit 1; }

# ---------- 参数 ----------
TARGET="n61-ios13"
STAGE=""
WORKDIR=""
FRESH=0
ASSUME_YES=0
PASS_ARGS=()

SUDO_STAGES="rootfs install all"
CONFIRM_STAGES="volumes rootfs patch-rootfs install boot all"
DFU_STAGES="boot all"
ALL_STAGES="ramdisk extract-im4m volumes rootfs patch-rootfs install build boot all status list"

usage() { sed -n '2,26p' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --fresh) FRESH=1 ;;
        --target) TARGET="$2"; shift ;;
        --workdir) WORKDIR="$2"; shift ;;
        --features|--patches|--exclude|--bootargs|--data-protection)
            [ $# -ge 2 ] || die "$1 需要一个参数"
            PASS_ARGS+=("$1" "$2"); shift ;;
        --allow-manual|--dry-run|--no-identity-check)
            PASS_ARGS+=("$1") ;;
        -*) die "未知选项: $1（--help 查看用法）" ;;
        *)
            [ -z "$STAGE" ] || die "只能指定一个阶段（已有 ${STAGE}，又来 $1）"
            STAGE="$1" ;;
    esac
    shift
done

[ -n "$STAGE" ] || { usage; exit 1; }
case " $ALL_STAGES " in *" $STAGE "*) ;; *) die "未知阶段: $STAGE";; esac

# ---------- 前置检查 ----------
PY="$(command -v python3 || true)"
[ -n "$PY" ] || die "未找到 python3"
[ -f n56patcher.py ] || die "请在仓库根目录运行（找不到 n56patcher.py）"

case " $SUDO_STAGES " in *" $STAGE "*)
    [ "$(id -u)" -eq 0 ] || die "$STAGE 需要写设备存储，请用 sudo 运行：sudo ./flash.sh $STAGE"
    ;;
esac

# ---------- 工作目录 ----------
if [ -n "$WORKDIR" ]; then
    : # 用户显式指定
elif [ "$FRESH" -eq 1 ] || [ "$STAGE" = "list" ]; then
    WORKDIR=""
    [ "$FRESH" -eq 1 ] && WORKDIR="build/${TARGET}-$(date +%Y%m%d-%H%M%S)"
else
    WORKDIR="build/${TARGET}-latest"   # install/build/boot 共享，分步跑可复用产物
fi

# ---------- 设备检查 ----------
device_check() {
    local irec out
    # 优先用仓库自带的 irecovery（Homebrew 版可能缺 libplist 跑不起来）
    for irec in tools/SSHRD_Script/Darwin/irecovery "$(command -v irecovery || true)"; do
        [ -n "$irec" ] && [ -x "$irec" ] && break
        irec=""
    done
    if [ -z "$irec" ]; then
        warn "未找到 irecovery，跳过设备预检（n56patcher 会在 boot 时再校验）。"
        return 0
    fi
    out="$("$irec" -q 2>/dev/null || true)"
    if ! printf '%s' "$out" | grep -q "CPID"; then
        if [ "$ASSUME_YES" -eq 1 ]; then
            warn "未检测到设备，继续执行（-y）。"
            return 0
        fi
        printf '%s[?]写入/引导阶段需要设备处于 DFU 模式。%s\n' "$C_Y" "$C_0" >&2
        read -r -p "确认设备已进入 DFU 并连接？[y/N] " ans
        case "$ans" in y|Y|yes|Yes) return 0 ;; *) die "已取消。请让设备进入 DFU 后重试。" ;; esac
    fi
    if printf '%s' "$out" | grep -q "PWND"; then
        ok "设备已就绪（DFU + pwned）。"
    else
        info "设备在 DFU，尚未 pwn（boot 流程会用 gaster pwn）。"
    fi
}

DRY_RUN=0
case " ${PASS_ARGS[*]:-} " in *" --dry-run "*) DRY_RUN=1 ;; esac

case " $DFU_STAGES " in *" $STAGE "*)
    [ "$DRY_RUN" -eq 1 ] || device_check
    ;;
esac

# ---------- 破坏性操作确认 ----------
case " $CONFIRM_STAGES " in *" $STAGE "*)
    if [ "$ASSUME_YES" -eq 0 ]; then
        warn "阶段 $STAGE 会改动设备（建卷/写盘/引导）。操作前请自行备份。"
        read -r -p "继续？[y/N] " ans
        case "$ans" in y|Y|yes|Yes) ;; *) die "已取消。" ;; esac
    fi
    ;;
esac

# ---------- 执行 ----------
CMD=("$PY" n56patcher.py "$STAGE" --target "$TARGET")
if [ -n "$WORKDIR" ]; then
    CMD+=(--workdir "$WORKDIR")
    info "工作目录: $WORKDIR"
fi
if [ "${#PASS_ARGS[@]}" -gt 0 ]; then
    CMD+=("${PASS_ARGS[@]}")
fi

printf '%s$ %s%s\n' "$C_B" "${CMD[*]}" "$C_0"
START=$SECONDS
if "${CMD[@]}"; then
    ELAPSED=$(( SECONDS - START ))
    printf '%s[ok] %s 完成，用时 %dm%02ds%s\n' "$C_G" "$STAGE" \
        $(( ELAPSED / 60 )) $(( ELAPSED % 60 )) "$C_0"
else
    rc=$?
    die "${STAGE} failed, exit code ${rc}. See log output above for details."
fi

# ---------- 收尾提示 ----------
case "$STAGE" in
    extract-im4m)
        info "后续 build 用新 IM4M 签名；分步构建直接 ./flash.sh build 即可。"
        ;;
    install)
        info "安装完成。下一步：./flash.sh build && ./flash.sh boot（同一工作目录，直接复用）。"
        ;;
    build)
        info "组件在 ${WORKDIR}。下一步：./flash.sh boot。"
        ;;
    boot)
        ok "启动链已发送，观察设备屏幕。"
        ;;
esac
