#!/bin/bash
# n61.sh — iPhone 6（N61AP）iOS 13.7 第二系统工具（纯 bash）
#
# 阶段：
#   ramdisk        进 iOS12.5.8 SSH ramdisk（DFU→gaster→发送 SSHRD 链→SSH 就绪）
#   extract-im4m   刷机后重提本机 IM4M（读 NOR）→ state/IM4M.bin   [需 ramdisk]
#   volumes        建 s4 SystemB / s5 DataB（role 0）              [需 ramdisk]
#   rootfs         把 iOS13.7 rootfs 流式写入 s4（~25 分钟）        [需 ramdisk + sudo]
#   patch-rootfs   overlay + 收尾 + 改 role
#   fix-icons      修复已安装 iOS13 的主屏图标（从 UI donor 补 staged App 图标）
#   build          构建五个启动组件 boot_*.img4（iBSS/iBEC/DT/TC/KC）
#   install        = volumes + rootfs + patch-rootfs
#   boot           经 DFU 发送已构建的启动链（缺组件时先 build）
#   status         ramdisk 下列出各卷 role / 加密状态 / 已用空间
#   list           列出当前目标选挂的补丁
#   all            ramdisk → extract-im4m → install → build → boot
#
# 选项：
#   --target NAME            目标清单（默认 n61-ios13）
#   --features a,b,c         覆盖 feature 选挂（空串 = 不选任何 feature）
#   --patches id,id          覆盖 KC 补丁选择（空串 = 只选基础 KC）
#   --exclude id,id          排除补丁（与清单 exclude 合并）
#   --bootargs "..."         覆盖 boot-args
#   --data-protection MODE   none | encrypted（默认 encrypted）
#   --workdir DIR            工作目录（默认 build/<target>-latest，跨阶段复用）
#   --fresh                  本次用带时间戳的新工作目录（不能与 --workdir 同用）
#   --dry-run                只演练：校验选挂/依赖，不碰设备、不产出
#   --allow-manual           执行标记为 manual 的补丁
#   --recreate-data          volumes 前删除已有 DataB（上次建卷中断/加密状态不符时用）
#   --no-identity-check      boot 时不校验设备身份
#   -y, --yes                跳过破坏性阶段的确认
#
# 注：bash 版目前只提供 N61（iPhone 6）清单；N56 清单仅 Python 版提供。
set -uo pipefail

# ---------- 定位仓库（支持 symlink / PATH 调用）----------
SELF="$0"
_depth=0
while [ -L "$SELF" ] && [ "$_depth" -lt 40 ]; do
    _link="$(readlink "$SELF")" || break
    case "$_link" in
        /*) SELF="$_link" ;;
        *)  SELF="$(cd "$(dirname "$SELF")" && pwd -P)/$_link" ;;
    esac
    _depth=$(( _depth + 1 ))
done
unset _depth _link
REPO="$(cd "$(dirname "$SELF")" && pwd -P)" || { printf '[x] 无法定位脚本目录\n' >&2; exit 1; }
SELF="$REPO/$(basename "$SELF")"
export REPO

# 说明：不启用 set -e —— lib 里大量用 `[ 条件 ] && 命令` 做可选动作，-e 会误杀；
# 所有关键失败路径都显式 `|| die`/返回值检查（见各阶段与 deploy_path）。
#
# 参数解析阶段就会 die，所以先加载日志模块（其余 lib 在读到目标清单后再加载）
# shellcheck source=lib/log.sh
. "$REPO/lib/log.sh" || { printf '[x] 无法加载 %s/lib/log.sh\n' "$REPO" >&2; exit 1; }

usage() {
    awk 'NR == 1 { next } /^set -/ { exit } { sub(/^# ?/, ""); print }' "$SELF"
}

# ---------- 选项默认值 ----------
OPT_TARGET="n61-ios13"
OPT_WORKDIR=""
OPT_FRESH=0
OPT_DRY_RUN=0
OPT_YES=0
OPT_FEATURES=""
OPT_PATCHES=""
OPT_FEATURES_SET=0
OPT_PATCHES_SET=0
OPT_EXCLUDE=""
OPT_ALLOW_MANUAL=0
OPT_RECREATE_DATA=0
OPT_NO_IDENTITY=0
OPT_BOOTARGS=""
OPT_DATA_PROTECTION=""
STAGE=""

while [ $# -gt 0 ]; do
    # 支持 --opt=value（与 --opt value 等价；不再静默丢弃）
    case "$1" in
        --target=*|--features=*|--patches=*|--exclude=*|--bootargs=*|--data-protection=*|--workdir=*)
            set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --target|--features|--patches|--exclude|--bootargs|--data-protection|--workdir)
            [ $# -ge 2 ] || die "选项 $1 需要一个参数"
            case "$1" in
                --target)            OPT_TARGET="$2" ;;
                --features)          OPT_FEATURES="$2"; OPT_FEATURES_SET=1 ;;
                --patches)           OPT_PATCHES="$2"; OPT_PATCHES_SET=1 ;;
                --exclude)           OPT_EXCLUDE="$2" ;;
                --bootargs)          OPT_BOOTARGS="$2" ;;
                --data-protection)   OPT_DATA_PROTECTION="$2" ;;
                --workdir)           OPT_WORKDIR="$2" ;;
            esac
            shift ;;
        --fresh)              OPT_FRESH=1 ;;
        --dry-run)            OPT_DRY_RUN=1 ;;
        --allow-manual)       OPT_ALLOW_MANUAL=1 ;;
        --recreate-data)      OPT_RECREATE_DATA=1 ;;
        --no-identity-check)  OPT_NO_IDENTITY=1 ;;
        -y|--yes)             OPT_YES=1 ;;
        -*) die "未知选项: $1（--help 查看用法）" ;;
        *)
            [ -z "$STAGE" ] || die "只能指定一个阶段（已有 ${STAGE}，又来 $1）"
            STAGE="$1"
            ;;
    esac
    shift
done

[ -n "$STAGE" ] || { usage; exit 1; }
case "$STAGE" in
    ramdisk|extract-im4m|volumes|rootfs|patch-rootfs|fix-icons|build|boot|install|all|status|list) ;;
    *) die "未知阶段: ${STAGE}（--help 查看用法）" ;;
esac

# ---------- 目标清单 + 其余库 ----------
# shellcheck source=/dev/null
. "$REPO/lib/target.sh" || die "无法加载 lib/target.sh"
load_target "$OPT_TARGET"

# 清单必填项：缺了直接给出可读信息，而不是 set -u 的 "unbound variable"
T_UI_DONOR="${T_UI_DONOR:-n66}"
for _v in T_MODEL T_ROOT_PART T_VOL_CREATE T_ROLES T_MNT_SYSTEM_B T_MNT_DATA_B \
          T_MNT_SYSTEM12 T_RAMDISK_PORT T_RAMDISK_DIR T_BASE_DT T_BASE_KC \
          T_DONOR_APFS14 T_IPSW_N66 T_IPSW_J96 T_ROOTFS_ENTRY_N66 T_ROOTFS_ENTRY_J96 \
          T_DERIVED_IBSS T_DERIVED_IBEC T_DERIVED_J96_KERNEL T_DERIVED_TRUSTCACHE \
          T_WIFI_SRCDIR T_WIFI_FILES; do
    eval "[ -n \"\${$_v:-}\" ]" || die "目标清单 ${T_NAME} 缺少变量 ${_v}"
done
unset _v

# load_target 之后再加载：lib/ssh.sh 在 source 时读取 T_RAMDISK_PORT 等
for _lib in tools bin macho kc dt tc ssh apfs patch mounts overlay mrm systembag \
            checkra1n device health stage; do
    # shellcheck source=/dev/null
    . "$REPO/lib/$_lib.sh" || die "无法加载 lib/$_lib.sh"
done
unset _lib

# ---------- 选项落到目标清单（与 Python 版 make_flow 对齐）----------
[ "$OPT_FEATURES_SET" -eq 1 ] || OPT_FEATURES="${T_FEATURES:-}"

# exclude：清单 + CLI 合并（Python 版是 list + CLI，不是覆盖）
if [ -n "$OPT_EXCLUDE" ]; then
    OPT_EXCLUDE="${T_EXCLUDE:-} $OPT_EXCLUDE"
else
    OPT_EXCLUDE="${T_EXCLUDE:-}"
fi

[ -n "$OPT_BOOTARGS" ] || OPT_BOOTARGS="${T_BOOTARGS:-}"
[ -n "$OPT_BOOTARGS" ] || die "清单未定义 boot-args，且未用 --bootargs 指定"

if [ -n "$OPT_DATA_PROTECTION" ]; then
    T_DATA_PROTECTION="$OPT_DATA_PROTECTION"
elif [ -z "${T_DATA_PROTECTION+set}" ]; then
    T_DATA_PROTECTION="encrypted"
fi
case "${T_DATA_PROTECTION}" in
    none|encrypted) ;;
    "") die "data_protection 为空：清单里应写 none 或 encrypted" ;;
    *)  die "--data-protection 只接受 none 或 encrypted（当前: '${T_DATA_PROTECTION}'）" ;;
esac
T_BOOTARGS="$OPT_BOOTARGS"
T_PATCHES="${T_PATCHES:-}"

# feature / patch / exclude 允许逗号或空格分隔
OPT_FEATURES="$(printf '%s' "$OPT_FEATURES" | tr ',' ' ')"
OPT_PATCHES="$(printf '%s' "$OPT_PATCHES" | tr ',' ' ')"
OPT_EXCLUDE="$(printf '%s' "$OPT_EXCLUDE" | tr ',' ' ')"

if [ "$OPT_FRESH" -eq 1 ] && [ -n "$OPT_WORKDIR" ]; then
    die "--workdir 与 --fresh 不能同时使用"
fi

# Legacy-iOS-Kit 兜底路径：sudo 下 $HOME 会变成 /var/root，优先用原用户 home
if [ -z "${LIOS_BIN:-}" ]; then
    for _cand in "$HOME/Desktop/Legacy-iOS-Kit_Latest/bin/macos" \
                 "/Users/${SUDO_USER:-}/Desktop/Legacy-iOS-Kit_Latest/bin/macos"; do
        [ -d "$_cand" ] || continue
        LIOS_BIN="$_cand"
        break
    done
    unset _cand
fi
export LIOS_BIN

setup_workdir
if [ "$OPT_DRY_RUN" -eq 1 ]; then
    log "工作目录（dry-run，不创建）: $WK"
else
    log "工作目录: $WK"
fi

# ---------- 工作目录锁：避免两个 n61.sh 同时操作同一 -latest 目录 ----------
LOCK_DIR=""
LOCKED=0
lock_workdir() {
    [ "$OPT_DRY_RUN" -eq 1 ] && return 0
    # 目录不可写多半是 sudo 运行留下的属主（后续 build 会全部失败，先给出修复命令）
    if [ ! -w "$WK" ]; then
        die "工作目录不可写: ${WK}
  多半是 sudo 运行创建的。修复：
    sudo chown -R $(id -u):$(id -g) \"${WK}\"
  或改用 --workdir 指定新目录。"
    fi
    LOCK_DIR="$WK/.lock"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        LOCKED=1
        return 0
    fi
    local pid=""
    [ -f "$LOCK_DIR/pid" ] && pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        die "工作目录 ${WK} 正被 pid ${pid} 的 n61.sh 使用；等它结束或换 --workdir"
    fi
    if rm -rf "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        LOCKED=1
        warn "发现残留工作目录锁（pid ${pid:-未知} 已退出），已清理"
        return 0
    fi
    # 清理失败：常见于 root 属主的锁目录；不要因此把正常阶段卡死
    warn "残留锁无法清理（可能是 sudo 运行创建）：${LOCK_DIR}"
    warn "  修复：sudo rm -rf \"${LOCK_DIR}\" && sudo chown -R $(id -u):$(id -g) \"$WK\""
    warn "  本次继续执行但不加锁。"
    LOCKED=0
    return 0
}
lock_workdir

# ---------- 清理：先装 trap，保证 root/确认失败时也能释放锁与挂载 ----------
cleanup() {
    local rc=$?
    trap - EXIT
    if [ "${OPT_DRY_RUN:-0}" -eq 1 ]; then
        apfs_cleanup || true
        exit "$rc"
    fi
    # 失败退出时把 ramdisk 里的系统挂载也卸掉（否则下一次 apfs_deletefs/mount 会撞 resource busy）
    ssh_run_timeout 8 "/sbin/umount /mnt1 2>/dev/null; /sbin/umount /mnt7 2>/dev/null; /sbin/umount /mnt6 2>/dev/null; true" >/dev/null 2>&1 || true
    donor_umount_all || true
    if [ -n "${IPROXY_PID:-}" ]; then
        kill "$IPROXY_PID" 2>/dev/null || true
    fi
    if [ "${LOCKED:-0}" -eq 1 ] && [ -n "${LOCK_DIR:-}" ] && [ -f "$LOCK_DIR/pid" ] &&
        [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
        rm -rf "$LOCK_DIR"
    fi
    # sudo 运行结束后把工作目录/state 交还给调用用户，避免之后的 ./n61.sh build 无法写
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
        chown -R "$SUDO_UID:$SUDO_GID" "$WK" 2>/dev/null || true
        [ -d "$REPO/state" ] && chown -R "$SUDO_UID:$SUDO_GID" "$REPO/state" 2>/dev/null || true
    fi
    apfs_cleanup || true
    exit "$rc"
}
trap cleanup EXIT

# ---------- 前置：root / 确认 ----------
case "$STAGE" in
    rootfs|install|all)
        [ "$OPT_DRY_RUN" -eq 1 ] || require_root "$STAGE"
        ;;
esac

confirm_stage() {
    [ -t 0 ] || die "阶段 ${STAGE} 会改动设备；非交互环境请加 -y"
    warn "阶段 ${STAGE} 会改动设备（建卷/写盘/引导）。操作前请自行备份。"
    printf '%s[?]%s 继续？[y/N] ' "${C_Y:-}" "${C_0:-}" >&2
    local ans=""
    read -r ans || ans=""
    case "$ans" in
        y|Y|yes|Yes) ;;
        *) die "已取消。" ;;
    esac
}

if [ "$OPT_DRY_RUN" -eq 0 ]; then
    case " volumes rootfs patch-rootfs fix-icons install boot all " in
        *" $STAGE "*)
            [ "$OPT_YES" -eq 1 ] || confirm_stage
            ;;
    esac
fi

case "$STAGE" in
    list)         stage_list ;;
    status)       stage_status ;;
    ramdisk)      stage_ramdisk ;;
    extract-im4m) stage_extract_im4m ;;
    volumes)      stage_volumes ;;
    rootfs)       stage_rootfs ;;
    patch-rootfs) stage_patch_rootfs ;;
    fix-icons)    stage_fix_icons ;;
    build)        stage_build ;;
    install)      stage_install ;;
    boot)         stage_boot ;;
    all)          stage_all ;;
esac
_rc=$?
exit "$_rc"
