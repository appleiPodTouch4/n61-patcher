#!/bin/bash
# n61.sh — iPhone 6（N61AP）/ 6 Plus（N56AP）iOS 13.7 第二系统工具（纯 bash）
#
# 阶段：
#   ramdisk        进 iOS12.5.8 SSH ramdisk（DFU→gaster→发送 SSHRD 链→SSH 就绪）
#   extract-im4m   刷机后重提本机 IM4M（读 NOR）→ state/IM4M.bin   [需 ramdisk]
#   volumes        建 s4 SystemB / s5 DataB（role 0）              [需 ramdisk]
#   rootfs         把 iOS13.7 rootfs 流式写入 s4（~25 分钟）        [需 ramdisk + sudo]
#   patch-rootfs   overlay + 收尾 + 改 role
#   build          构建五个启动组件 boot_*.img4（iBSS/iBEC/DT/TC/KC）
#   install        = volumes + rootfs + patch-rootfs
#   boot           经 DFU 发送已构建的启动链（iBSS/iBEC/DT/TC/KC）
#   status         ramdisk 下列出各卷 role / 加密状态 / 已用空间
#   list           列出当前目标选挂的补丁
#   all            ramdisk → extract-im4m → install → build
#
# 选项：
#   --target NAME            目标清单（默认 n61-ios13）
#   --features a,b,c         覆盖 feature 选挂
#   --patches id,id          覆盖 KC 补丁选择
#   --exclude id,id          排除补丁
#   --bootargs "..."         覆盖 boot-args
#   --data-protection MODE   none | encrypted
#   --workdir DIR            工作目录（默认 build/<target>-latest，跨阶段复用）
#   --fresh                  本次用带时间戳的新工作目录
#   --dry-run                只演练，不碰设备
#   --no-identity-check      boot 时不校验设备身份
#   -y, --yes                跳过确认
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
export REPO

OPT_TARGET="n61-ios13"
OPT_WORKDIR=""
OPT_FRESH=0
OPT_DRY_RUN=0
OPT_FEATURES=""
OPT_PATCHES=""
OPT_FEATURES_SET=0
OPT_PATCHES_SET=0
OPT_EXCLUDE=""
OPT_ALLOW_MANUAL=0
OPT_NO_IDENTITY=0
OPT_BOOTARGS=""
OPT_DATA_PROTECTION=""
STAGE=""

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --target) OPT_TARGET="$2"; shift ;;
        --features) OPT_FEATURES="$2"; OPT_FEATURES_SET=1; shift ;;
        --patches) OPT_PATCHES="$2"; OPT_PATCHES_SET=1; shift ;;
        --exclude) OPT_EXCLUDE="$2"; shift ;;
        --bootargs) OPT_BOOTARGS="$2"; shift ;;
        --data-protection) OPT_DATA_PROTECTION="$2"; shift ;;
        --workdir) OPT_WORKDIR="$2"; shift ;;
        --fresh) OPT_FRESH=1 ;;
        --dry-run) OPT_DRY_RUN=1 ;;
        --allow-manual) OPT_ALLOW_MANUAL=1 ;;
        --no-identity-check) OPT_NO_IDENTITY=1 ;;
        -y|--yes) : ;;
        -*) die "未知选项: $1（--help 查看用法）" ;;
        *)
            [ -z "$STAGE" ] || die "只能指定一个阶段（已有 ${STAGE}，又来 $1）"
            STAGE="$1"
            ;;
    esac
    shift
done

[ -n "$STAGE" ] || { usage; exit 1; }

# shellcheck source=/dev/null
. "$REPO/lib/log.sh"
. "$REPO/lib/target.sh"
. "$REPO/lib/tools.sh"
. "$REPO/lib/bin.sh"
. "$REPO/lib/macho.sh"
. "$REPO/lib/kc.sh"
. "$REPO/lib/dt.sh"
. "$REPO/lib/tc.sh"
. "$REPO/lib/ssh.sh"
. "$REPO/lib/apfs.sh"
. "$REPO/lib/patch.sh"
. "$REPO/lib/mounts.sh"
. "$REPO/lib/overlay.sh"
. "$REPO/lib/mrm.sh"
. "$REPO/lib/systembag.sh"
. "$REPO/lib/checkra1n.sh"
. "$REPO/lib/device.sh"
. "$REPO/lib/stage.sh"

load_target "$OPT_TARGET"

# ---- 选项落到目标清单 ----
[ "$OPT_FEATURES_SET" -eq 1 ] || OPT_FEATURES="$T_FEATURES"
[ "$OPT_PATCHES_SET" -eq 1 ] || OPT_PATCHES=""
[ -n "$OPT_EXCLUDE" ] || OPT_EXCLUDE="$T_EXCLUDE"
[ -n "$OPT_BOOTARGS" ] || OPT_BOOTARGS="$T_BOOTARGS"
[ -n "$OPT_DATA_PROTECTION" ] || OPT_DATA_PROTECTION="$T_DATA_PROTECTION"
T_DATA_PROTECTION="$OPT_DATA_PROTECTION"
T_BOOTARGS="$OPT_BOOTARGS"
# feature 允许逗号或空格分隔
OPT_FEATURES="$(printf '%s' "$OPT_FEATURES" | tr ',' ' ')"
OPT_PATCHES="$(printf '%s' "$OPT_PATCHES" | tr ',' ' ')"
OPT_EXCLUDE="$(printf '%s' "$OPT_EXCLUDE" | tr ',' ' ')"

LIOS_BIN="${LIOS_BIN:-$HOME/Desktop/Legacy-iOS-Kit_Latest/bin/macos}"
export LIOS_BIN

setup_workdir

trap 'donor_umount_all; apfs_cleanup' EXIT

case "$STAGE" in
    list)         stage_list ;;
    status)       stage_status ;;
    ramdisk)      stage_ramdisk ;;
    extract-im4m) stage_extract_im4m ;;
    volumes)      stage_volumes ;;
    rootfs)       stage_rootfs ;;
    patch-rootfs) stage_patch_rootfs ;;
    build)        stage_build ;;
    install)      stage_install ;;
    boot)         stage_boot ;;
    all)          stage_all ;;
    *)            die "未知阶段: ${STAGE}（--help 查看用法）" ;;
esac
