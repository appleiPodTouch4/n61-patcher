# shellcheck shell=bash
# Health 部署（对应 Python 版 patches/rootfs/health.py 的 apply）。
#
# Python 版的 Health.apply 在静态 items 之外还会动态部署两批文件：
#   1) n66 donor 上 50 个 Health/Phone 库各自 bundle 里的非 Mach-O 资源；
#   2) repair-v7 派生出来的 50 个库（Python 工具链一次性产物）。
# 导出的 patches/overlays/rootfs.health.conf 只能携带静态 items，所以 bash
# 侧必须自己补上这两步，否则 patch-rootfs 会"成功"但系统缺件。
#
# 50 个库不是 bash 能派生的（依赖 Python 工具链），这里只消费缓存：
#   $N56_HEALTH_LIBS
#   $WK/health-derive/project/phone_apps_bringup/20261029/full/repair-v7/libraries
#   $REPO/state/health-libraries
#   任意 build/*/health-derive/.../libraries（按修改时间取最新）
# 找不到就报错并给出出路，不再静默跳过。

health_libs_ok() {   # dir
    [ -n "${1:-}" ] || return 1
    [ -d "$1" ] || return 1
    [ "$(find "$1" -type f 2>/dev/null | wc -l | tr -d ' ')" = "50" ]
}

health_libs_dir() {   # → 打印目录；找不到返回 1
    local cand
    for cand in "${N56_HEALTH_LIBS:-}" \
        "${WK:-}/health-derive/project/phone_apps_bringup/20261029/full/repair-v7/libraries" \
        "$REPO/state/health-libraries"; do
        if health_libs_ok "$cand"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    while IFS= read -r cand; do
        if health_libs_ok "$cand"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done < <(ls -dt "$REPO"/build/*/health-derive/project/phone_apps_bringup/20261029/full/repair-v7/libraries 2>/dev/null)
    return 1
}

# rootfs.health：资源 → 50 个库 → 静态 items（顺序与 Python 版一致）
health_apply() {
    local libs n66 bundles raw res b f rel
    libs="$(health_libs_dir)" || die "缺少 Health 库产物（50 个文件），无法完整部署 rootfs.health。
  可用 N56_HEALTH_LIBS=/path 指定，或先跑一次 Python 版 patch-rootfs 做一次性派生。
  不想装 Health 时：在 --features 里去掉 health。"
    n66="$(donor_mount n66)" || die "Health 资源需要 n66 rootfs donor"

    mkdir -p "$WK/health"
    bundles="$WK/health/bundles.txt"
    raw="$WK/health/resources.raw"
    res="$WK/health/resources.txt"

    # 50 个库的父目录 → bundle 目录（与 Python bundle_resource_paths 的取法一致）
    ( cd "$libs" && find . -type f -print ) |
        sed 's|^\./||; s|/[^/]*$||' |
        LC_ALL=C sort -u >"$bundles" ||
        die "生成 Health bundle 清单失败: $libs"

    : >"$raw"
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        [ -d "$n66/$b" ] || die "n66 缺少 Health bundle 目录: $b"
        while IFS= read -r f; do
            rel="${f#"$n66"/}"
            case "$rel" in
                */_CodeSignature/*|*/_CodeSignature) continue ;;
            esac
            ov_is_macho "$f" && continue
            printf '%s\n' "$rel" >>"$raw"
        done < <(find "$n66/$b" -type f)
    done <"$bundles"
    LC_ALL=C sort -u "$raw" >"$res"

    log "  部署 $(wc -l <"$res" | tr -d ' ') 份 Health bundle 资源…"
    deploy_relative_paths "$n66" "$OV_MNT" "$res"

    log "  部署 50 个 Health 库（$(printf '%s' "$libs" | sed "s|^$REPO/||")）…"
    deploy_path "$libs" "$OV_MNT" 0 0

    log "  Health 静态项（healthappd / plist / dyld 补丁）…"
    ov_apply_items_file "$REPO/patches/overlays/rootfs.health.conf"
    sync_dev
}
