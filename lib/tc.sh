# shellcheck shell=bash
# TrustCache（对应 core/trustcache.py 的 build_full / 静态 TC 两条路）。
#
# iOS13 的 launchd 只运行 mrm 缓存里列出的守护进程，launchd_cache_loader 还会校验
# 分离签名并要求 cdhash 在 TrustCache 里。所以「完整 TC」= 原版静态 TC ∪ 本次新增
# 二进制（mrm 缓存、打包后的 dyld 缓存、installd/backupd、checkra1n、Health 库、
# N66 的界面 App 与设置）的 cdhash，按 cdhash 排序后重新写出（v1，22 字节/条）。
#
# 静态数据（由 tools/export_kcdata.py 导出，带回放校验）：
#   patches/tcdata/trustcache-extra.tsv   原版 TC 之外必须放行的 cdhash
#   patches/tcdata/dyld-edits.tsv         离线改 dyld_shared_cache_arm64 的字节补丁
#
# 注意：所有「收集路径」的循环都用 < <(...) / <"$file" 而不是管道，这样 tc_cdhash
# 里的 die 能终止整个脚本，而不是只杀掉一个子 shell。

TCD="${REPO}/patches/tcdata"

# 这两条与 Python 版一致：iOS13 上必须放行、但不在任何本地二进制里的 cdhash
TC_FIXED="4c18c48ad1d24e694c5ab4b70a1c54040759fd1e 06716767d351ae0c876b7d57cf59069d895c3373"

tc_cdhash() {   # path [detached_sig] → 40 位 hex（读不到就停）
    local out h
    if [ -n "${2:-}" ]; then
        out="$(codesign -d -vvvv --detached "$2" "$1" 2>&1 >/dev/null)"
    else
        out="$(codesign -d -vvvv "$1" 2>&1 >/dev/null)"
    fi
    h="$(printf '%s\n' "$out" |
        sed -n 's/.*CandidateCDHash sha256=\([0-9a-f]\{40\}\).*/\1/p' | head -1)"
    [ -n "$h" ] || die "读不到 cdhash：${1}（codesign 没输出 CandidateCDHash）"
    printf '%s\n' "$h"
}

tc_is_macho() {   # file（批量场景请用 bin_macho_list，别对每个文件起进程）
    case "$(bin_hex "$1" 0 4)" in
        cffaedfe|cefaedfe|feedfacf|cafebabe|bebafeca) return 0 ;;
    esac
    return 1
}

# 原版静态 TC（IM4P → raw）→ 设 TC_STOCK
# 用全局而不是 echo：函数里的 die 在 $( ) 里只会杀掉子 shell，错误会被吞掉。
tc_stock() {
    TC_STOCK="$WK/trustcache.stock.raw"
    "$(tool img4)" -i "$(derived_path trustcache)" -o "$TC_STOCK" >/dev/null 2>&1 ||
        die "静态 TrustCache 解包失败"
    [ -s "$TC_STOCK" ] || die "静态 TrustCache 解包后没有产物"
}

# 打补丁后的 dyld 共享缓存（基带 H2 + Health 两处），cdhash 要进 TC → 设 TC_DYLD
tc_dyld_cache() {
    TC_DYLD="$WK/dyld_shared_cache_arm64.combined"
    if [ -s "$TC_DYLD" ]; then
        return 0
    fi
    local src
    src="$(donor_mount j96)/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64"
    [ -f "$src" ] || die "j96 rootfs 里没有 dyld_shared_cache_arm64"
    log "  准备 dyld 共享缓存（APFS 克隆 + 5 处离线补丁）…"
    # APFS 同卷克隆，1.7GB 也是瞬间完成；跨卷时退回复制
    cp -c "$src" "$TC_DYLD" 2>/dev/null || cp "$src" "$TC_DYLD" || die "复制 dyld 缓存失败"
    bin_apply_tsv "$TC_DYLD" "$TCD/dyld-edits.tsv" >/dev/null
}

# Health 库产物：由 Python 工具链（health_toolchain）派生，bash 侧复用其缓存
# 解析逻辑统一放在 lib/health.sh（与 patch-rootfs 的部署共用一份缓存）
tc_health_libs() {   # → 打印目录（没有就空行）
    health_libs_dir || printf '\n'
}

# N66 上被搬到 iOS13 的界面 App 里的 Mach-O
tc_app_machos() {   # n66 → 每行一个路径
    local n66="$1" app
    for app in Health.app MobilePhone.app Passbook.app; do
        [ -d "$n66/Applications/$app" ] || continue
        bin_macho_list "$n66/Applications/$app"
    done
}

# 设置 App 相关：N66 上「与 J96 不同」的 Mach-O（这些会覆盖到 SystemB，需要放行）
tc_settings_binaries() {   # n66 j96 → 每行一个路径
    local n66="$1" j96="$2" fw scope f rel
    local -a scopes=(
        "Applications/Preferences.app"
        "System/Library/PreferenceBundles"
        "System/Library/PrivateFrameworks/Settings"
        "System/Library/ProductDocuments/Notices"
    )
    fw="$n66/System/Library/PrivateFrameworks"
    if [ -d "$fw" ]; then
        while IFS= read -r scope; do
            [ -n "$scope" ] || continue
            scopes+=("System/Library/PrivateFrameworks/$scope")
        done < <(cd "$fw" && ls -d *Settings*.framework *Preferences*.framework 2>/dev/null | sort)
    fi
    for scope in "${scopes[@]}"; do
        [ -d "$n66/$scope" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            case "$f" in */_CodeSignature/*) continue ;; esac
            rel="${f#"$n66"/}"
            if [ ! -f "$j96/$rel" ] ||
                [ "$(shasum -a 256 "$f" | awk '{print $1}')" != \
                  "$(shasum -a 256 "$j96/$rel" | awk '{print $1}')" ]; then
                printf '%s\n' "$f"
            fi
        done < <(bin_macho_list "$n66/$scope")
    done
}

# 收集「要放行的文件」→ $WK/trustcache.paths.txt（cdhash 由 tc_digests 统一算）
tc_paths() {   # out_paths
    local pl="$1" libs n66 j96
    : >"$pl"

    log "  收集需要放行的二进制…"
    build_mrm
    printf '%s\n' "$WK/mrm/mrm.plist" >>"$pl"

    tc_dyld_cache
    [ -s "$TC_DYLD" ] || die "dyld 共享缓存没准备好"
    printf '%s\n' "$TC_DYLD" >>"$pl"

    printf '%s\n' "$(blob_build installd-empty-containers)" >>"$pl"
    printf '%s\n' "$(blob_build backupd-empty-snapshot)" >>"$pl"

    if kc_has_feature checkra1n; then
        checkra1n_prepare
        bin_macho_list "$CHECKRA1N_ROOT" >>"$pl"
    fi

    libs="$(tc_health_libs)"
    if [ -n "$libs" ]; then
        find "$libs" -type f 2>/dev/null | sort >>"$pl"
        log "    Health 库：$libs"
    else
        warn "没找到 Health 库产物，TC 将不含 Health 库的 cdhash（health 功能会受限）"
        warn "  期望：\$WK/health-derive/project/phone_apps_bringup/20261029/full/repair-v7/libraries"
        warn "  或用 N56_HEALTH_LIBS=/path 指定；由 Python 工具链一次性派生"
    fi

    n66="$(donor_mount n66)"
    j96="$(donor_mount j96)"
    tc_app_machos "$n66" >>"$pl"
    tc_settings_binaries "$n66" "$j96" >>"$pl"

    log "  待放行文件：$(wc -l <"$pl" | tr -d ' ') 个"
}

# 路径清单 → cdhash 清单（mrm 要带分离签名，单独处理）
tc_digests() {   # paths → digests
    local pl="$1" f="$2" p
    : >"$f"
    local h
    for h in $TC_FIXED ${T_PROFILE_CDHASHES:-}; do
        printf '%s\n' "$h" >>"$f"
    done
    awk -F'\t' '$1 == "full" { print $2 }' "$TCD/trustcache-extra.tsv" >>"$f"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ "$p" = "$WK/mrm/mrm.plist" ]; then
            tc_cdhash "$p" "$WK/mrm/mrm.plist.sig" >>"$f"
        else
            tc_cdhash "$p" >>"$f"
        fi
    done <"$pl"
    log "  cdhash 清单：$(wc -l <"$f" | tr -d ' ') 条"
}

# 完整 TrustCache：原版 TC ∪ 清单 → 排序 → raw → rtsc
build_tc() {   # out
    local out="$1" raw="$WK/trustcache.full.raw"
    local pl="$WK/trustcache.paths.txt" dg="$WK/trustcache.digests.txt"
    [ -f "$TCD/trustcache-extra.tsv" ] ||
        die "缺少 $TCD/trustcache-extra.tsv（先跑 tools/export_kcdata.py）"
    tc_paths "$pl"
    tc_digests "$pl" "$dg"
    tc_stock
    "$PERL" "$REPO/lib/trustcache.pl" "$TC_STOCK" "$raw" "$dg" ||
        die "TrustCache 组装失败"
    "$(tool img4)" -i "$raw" -A -T rtsc -M "$(im4m_path)" -o "$out" >/dev/null ||
        die "TrustCache 签名失败"
    log "  TrustCache: $(bin_len "$out") 字节"
}
