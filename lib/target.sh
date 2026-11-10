# shellcheck shell=bash
# 目标清单加载与路径解析。
#
# 清单是纯 shell 文件（targets/<name>.sh），只定义 T_* 变量；
# 这与 Python 版 targets/*.py 一一对应，便于两边并行维护。

load_target() {
    local name="$1" path
    case "$name" in
        /*) path="$name" ;;
        *)
            path="${REPO}/targets/${name//-/_}.sh"
            [ -f "$path" ] || path="${REPO}/targets/$name.sh"
            ;;
    esac
    if [ ! -f "$path" ]; then
        local py=""
        if [ -f "${path%.sh}.py" ]; then
            py="${path%.sh}.py"
        elif [ "${name#/}" = "$name" ] && [ -f "${REPO}/targets/${name//-/_}.py" ]; then
            py="${REPO}/targets/${name//-/_}.py"
        fi
        if [ -n "$py" ]; then
            die "找不到 bash 目标清单: ${path}（仓库里只有 Python 清单 ${py}；bash 版尚未提供该机型清单）"
        fi
        die "找不到目标清单: ${name}（${REPO}/targets/）"
    fi
    # shellcheck disable=SC1090
    . "$path"
    T_PATH="$path"
    [ -n "${T_NAME:-}" ] || die "$path 未定义 T_NAME"
}

# 仓库内文件（必须存在）
repo_file() {
    [ -e "$REPO/$1" ] || die "缺少本地文件: $1"
    printf '%s\n' "$REPO/$1"
}

# donor 目录
donor_dir() { printf '%s\n' "${N56_DONORS:-$REPO/${T_SOURCE_ROOT:-donors}}"; }

# 从 IPSW 派生的构建输入（与 Python 版 core/context.py 的 derived 等价）
derived_path() {
    local key="$1" rel p
    case "$key" in
        ibss_src)  rel="$T_DERIVED_IBSS" ;;
        ibec_dec)  rel="$T_DERIVED_IBEC" ;;
        j96_kernel) rel="$T_DERIVED_J96_KERNEL" ;;
        trustcache) rel="$T_DERIVED_TRUSTCACHE" ;;
        *) die "未声明派生输入: $key" ;;
    esac
    p="$REPO/ipsw/cache/derived/$rel"
    [ -f "$p" ] || die "缺少派生输入 ${key}: ${p}
  bash 版不从 IPSW 现场派生（iBSS/iBEC 解密需要设备处于 DFU）。请先用 Python 版生成：
    sudo python3 n56patcher.py all --target ${T_NAME}
  或把文件放到上述路径。"
    printf '%s\n' "$p"
}

# IM4M（刷机后重提，build 签名用）
im4m_path() {
    local p="$REPO/state/IM4M.bin"
    [ -f "$p" ] || die "缺少 state/IM4M.bin：请先运行 ./n61.sh extract-im4m"
    printf '%s\n' "$p"
}

# 某 profile（n61/n66/n71/j96）对应的系统 build 号
target_build() {
    case "$1" in
        n61) printf '%s\n' "$T_BUILD_N61" ;;
        n66) printf '%s\n' "$T_BUILD_N66" ;;
        n71) printf '%s\n' "$T_BUILD_N71" ;;
        j96) printf '%s\n' "$T_BUILD_J96" ;;
        *)   printf '\n' ;;
    esac
}

# rootfs DMG：优先 ipsw/cache/，否则从 IPSW 提取
rootfs_dmg() {
    local kind="$1" entry name ipsw cache override
    # 目录外的 DMG 可直接指定：N56_ROOTFS_N66=/path/to/x.dmg ./n61.sh …
    eval "override=\${N56_ROOTFS_$(printf '%s' "$kind" | tr 'a-z' 'A-Z'):-}"
    if [ -n "$override" ]; then
        [ -f "$override" ] || die "N56_ROOTFS_ 指定的 DMG 不存在: $override"
        printf '%s\n' "$override"
        return 0
    fi
    case "$kind" in
        n61) entry="$T_ROOTFS_ENTRY_N61"; ipsw="$T_IPSW_N61" ;;
        n66) entry="$T_ROOTFS_ENTRY_N66"; ipsw="$T_IPSW_N66" ;;
        n71) entry="$T_ROOTFS_ENTRY_N71"; ipsw="$T_IPSW_N71" ;;
        j96) entry="$T_ROOTFS_ENTRY_J96"; ipsw="$T_IPSW_J96" ;;
        *) die "未知 rootfs 类型: $kind" ;;
    esac
    cache="$REPO/ipsw/cache/$entry"
    [ -f "$cache" ] && { printf '%s\n' "$cache"; return; }
    [ -f "$REPO/ipsw/$ipsw" ] || die "找不到 $kind IPSW: ipsw/$ipsw"
    log "从 $kind IPSW 提取 ${entry}…" >&2
    mkdir -p "$REPO/ipsw/cache"
    ( cd "$REPO/ipsw/cache" && unzip -o -q "../$ipsw" "$entry" ) || die "IPSW 提取失败: $entry"
    [ -f "$cache" ] || die "IPSW 中没有 $entry"
    printf '%s\n' "$cache"
}

# 本次工作目录（产物）
setup_workdir() {
    if [ -n "${OPT_WORKDIR:-}" ]; then
        WORK="$OPT_WORKDIR"
    elif [ "${OPT_FRESH:-0}" -eq 1 ]; then
        WORK="$REPO/build/${T_NAME}-$(date +%Y%m%d-%H%M%S)"
    else
        WORK="$REPO/build/${T_NAME}-latest"
    fi
    case "$WORK" in /*) ;; *) WORK="$REPO/$WORK" ;; esac
    if [ "${OPT_DRY_RUN:-0}" -ne 1 ]; then
        mkdir -p "$WORK" || die "无法创建工作目录: ${WORK}"
    fi
    WK="$WORK"
}

wk() { printf '%s\n' "$WK/$1"; }

# state/（IM4M、keybags 等跨阶段状态）
state_dir() {
    mkdir -p "$REPO/state"
    printf '%s\n' "$REPO/state"
}
