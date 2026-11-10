# shellcheck shell=bash
# 各阶段实现。对应 Python 版 n56patcher.py 的 Flow。

require_root() {
    [ "$(id -u)" -eq 0 ] || die "$1 需要写设备存储，请用 sudo 运行：sudo ./n61.sh $1"
}

dry() { [ "${OPT_DRY_RUN:-0}" -eq 1 ]; }

# data_protection 的唯一判断入口（n61.sh 负责缺省与合法性校验）
data_is_encrypted() { [ "${T_DATA_PROTECTION:-}" = "encrypted" ]; }

# 选挂清单文件：dry-run 用临时文件，避免"只演练却写工作目录"
patch_selection_file() {
    if dry; then
        mktemp -t n61-patches || die "无法创建临时清单文件"
    else
        printf '%s\n' "$WK/patches-selected.txt"
    fi
}

# 选挂清单 → 排序后的 patch id（build 时与安装时对比，不一致就警告）
selection_ids() {   # listfile
    awk -F'\t' '{ print $3 }' "$1" | LC_ALL=C sort
}

# ---------- 构建/安装前置检查（放在设备操作之前，避免写入 25 分钟后才失败）----------

preflight_derived() {
    derived_path ibss_src >/dev/null
    derived_path ibec_dec >/dev/null
    derived_path j96_kernel >/dev/null
    derived_path trustcache >/dev/null
}

preflight_donor_ipsw() {
    local kind entry ipsw var override seen="" kinds="n66 j96"
    # UI donor（n71/n66）只在选了 ui 相关 feature 时才需要
    case " ${OPT_FEATURES:-} " in
        *" ui "*) kinds="$kinds ${T_UI_DONOR:-n66}" ;;
    esac
    for kind in $kinds; do
        case " $seen " in *" $kind "*) continue ;; esac
        seen="$seen $kind"
        case "$kind" in
            n66) entry="${T_ROOTFS_ENTRY_N66:-}"; ipsw="${T_IPSW_N66:-}"; var=N56_ROOTFS_N66 ;;
            n71) entry="${T_ROOTFS_ENTRY_N71:-}"; ipsw="${T_IPSW_N71:-}"; var=N56_ROOTFS_N71 ;;
            j96) entry="${T_ROOTFS_ENTRY_J96:-}"; ipsw="${T_IPSW_J96:-}"; var=N56_ROOTFS_J96 ;;
            n61) entry="${T_ROOTFS_ENTRY_N61:-}"; ipsw="${T_IPSW_N61:-}"; var=N56_ROOTFS_N61 ;;
            *)   continue ;;
        esac
        eval "override=\${$var:-}"
        [ -n "$override" ] && continue
        [ -n "$entry" ] && [ -n "$ipsw" ] ||
            die "清单缺少 ${kind} 的 rootfs_entry/ipsw 声明"
        [ -f "$REPO/ipsw/cache/$entry" ] || [ -f "$REPO/ipsw/$ipsw" ] ||
            die "缺少 ${kind} donor：ipsw/${ipsw}（或缓存 ipsw/cache/${entry}）"
    done
}

preflight_common_assets() {
    preflight_donor_ipsw
    case " ${OPT_FEATURES:-} " in
        *" checkra1n "*)
            [ -d "$(checkra1n_assets)" ] || die "缺少 checkra1n 资产: $(checkra1n_assets)（先跑 tools/setup.py）"
            ;;
    esac
}

preflight_build_inputs() {
    preflight_common_assets
    preflight_derived
    [ -f "$REGISTRY" ] || die "缺少补丁注册表: $REGISTRY"
    [ -f "$REPO/patches/dtdata/$(dt_board).meta" ] ||
        die "缺少 DeviceTree 资产: patches/dtdata/$(dt_board).meta（先跑 python3 tools/export_dtdata.py）"
}

preflight_install_inputs() {
    preflight_common_assets
    case " ${OPT_FEATURES:-} " in
        *" health "*)
            health_libs_dir >/dev/null || die "缺少 Health 库缓存（50 个文件），rootfs.health 无法完整部署。
  用 N56_HEALTH_LIBS=/path 指定，或先跑一次 Python 版 patch-rootfs 做一次性派生；
  不想装 Health 时在 --features 里去掉 health。"
            ;;
    esac
    [ -n "${T_DONOR_APFS14:-}" ] || die "清单未定义 T_DONOR_APFS14"
    [ -d "$(donor_dir)/${T_DONOR_APFS14}" ] ||
        die "缺少 iOS14 fsck 资产: $(donor_dir)/${T_DONOR_APFS14}"
}

preflight_ramdisk_assets() {
    local dir name
    dir="$REPO/${T_RAMDISK_DIR}"
    for name in iBSS iBEC ramdisk devicetree trustcache kernelcache; do
        [ -f "$dir/$name.img4" ] || die "缺少 ramdisk 组件: $dir/$name.img4"
    done
}

# ---------- list ----------
stage_list() {
    local f layer role id feat
    # 用临时文件：list 不能覆盖 build/patch-rootfs 的选挂清单
    f="$(mktemp -t n61-list)" || die "无法创建临时清单文件"
    log "目标 $T_NAME  features=[$OPT_FEATURES]"
    select_patches "$OPT_FEATURES" "$OPT_PATCHES" "$OPT_EXCLUDE" "$T_BASE_DT" "$T_BASE_KC" \
        "${OPT_PATCHES_SET:-0}" "${T_PATCHES:-}" >"$f" ||
        { rm -f "$f"; die "补丁选择失败"; }
    while IFS="$(printf '\t')" read -r layer role id feat; do
        printf '  [%-6s] %-9s %-9s %s\n' "$layer" "$role" "$feat" "$id"
    done <"$f"
    rm -f "$f"
    return 0
}

# ---------- status ----------
stage_status() {
    if dry; then log "dry-run：跳过读取卷信息。"; return 0; fi
    ssh_ensure
    apfs_list
}

# ---------- ramdisk ----------
stage_ramdisk() {
    if dry; then log "dry-run：跳过设备发送。"; return 0; fi
    log "进入 iOS12.5.8 SSH ramdisk…"
    send_ramdisk_chain
}

# ---------- extract-im4m ----------
stage_extract_im4m() {
    local disk2 out size
    if dry; then log "dry-run：跳过重提 IM4M。"; return 0; fi
    ssh_ensure
    mkdir -p "$REPO/state" || die "无法创建 state/ 目录"
    disk2="$REPO/state/disk2.bin"
    out="$REPO/state/IM4M.bin"
    log "从 NOR(/dev/disk2) 读取 4MB 并提取 IM4M…"
    rm -f "$disk2"
    local rc=0
    ssh_run_timeout 120 "dd if=/dev/disk2 bs=256 count=16384 2>/dev/null" >"$disk2" || rc=$?
    [ "$rc" -eq 0 ] || {
        rm -f "$disk2"
        [ "$rc" -eq 124 ] && die "NOR 读取超时（120s）：重启设备进 DFU 后重跑 ramdisk/extract-im4m"
        die "NOR 读取失败"
    }
    size="$(wc -c <"$disk2" | tr -d ' ')"
    [ "$size" -ge 4096 ] ||
        { rm -f "$disk2"; die "NOR 读取异常，仅 ${size} 字节；确认 ramdisk 已就绪且 /dev/disk2 存在"; }
    "$(tool img4)" -i "$disk2" -m "$out" || die "IM4M 提取失败"
    [ -s "$out" ] || die "IM4M 提取失败：${out} 为空"
    ok "新 IM4M: $out ($(wc -c <"$out" | tr -d ' ') 字节)"
}

# ---------- volumes ----------
stage_volumes() {
    local encrypt=0 state=0 data_name
    data_name="$(printf '%s' "${T_VOL_CREATE:-DataB}" | awk '{print $2}')"
    [ -n "$data_name" ] || data_name="DataB"
    if dry; then log "dry-run：跳过创建卷。"; return 0; fi
    ssh_ensure
    data_is_encrypted && encrypt=1

    if [ "${OPT_RECREATE_DATA:-0}" -eq 1 ] && apfs_vol_exists "$T_MNT_DATA_B"; then
        # 先把可能残留的挂载卸掉，否则 apfs_deletefs 会 resource busy
        umount_vols /mnt7 /mnt1
        log "删除已有 ${data_name}（--recreate-data）…"
        rsh_timeout 120 "/sbin/apfs_deletefs /dev/disk0s1s${T_MNT_DATA_B}"
    fi

    if apfs_vol_exists "$T_MNT_DATA_B"; then
        apfs_vol_exists "$T_MNT_SYSTEM_B" ||
            die "卷布局异常：存在 s${T_MNT_DATA_B} 但没有 s${T_MNT_SYSTEM_B}，请先处理卷再重试"
        apfs_name_encrypted "$data_name"
        state=$?
        case "$state" in
            0) [ "$encrypt" -eq 1 ] ||
                   die "${data_name} 已存在且为 encrypted，但本次 --data-protection 不是 encrypted。
  换保护模式需要重建 DataB：加 --recreate-data 重跑 volumes（会删除 DataB 数据）。" ;;
            1) [ "$encrypt" -eq 0 ] ||
                   die "${data_name} 已存在且为 UNENCRYPTED，但本次 --data-protection 是 encrypted。
  换保护模式需要重建 DataB：加 --recreate-data 重跑 volumes（会删除 DataB 数据）。" ;;
            *) die "找不到已存在的 ${data_name} 卷状态，无法确认加密模式" ;;
        esac
        log "s4/s5 已存在且加密模式一致，跳过建卷。"
    fi

    apfs_create_volumes "$T_VOL_CREATE" "$encrypt"
    if [ "$encrypt" -eq 1 ]; then
        apfs_report_data_encryption "$data_name"
    fi
    return 0
}

# ---------- rootfs ----------
stage_rootfs() {
    local mnt
    if dry; then log "dry-run：跳过 rootfs 写入。"; return 0; fi
    require_root rootfs
    preflight_install_inputs
    ssh_ensure
    # donor_mount 负责 owners 模式、复用已挂载点、校验 rootfs build 号（17H35）；
    # 卸载交给 EXIT trap（donor_umount_all），避免失败/中断时留下挂载。
    mnt="$(donor_mount j96)" || die "rootfs DMG 挂载失败"
    [ -n "$mnt" ] || die "rootfs DMG 挂载失败（空挂载点）"
    mount_vol "$T_MNT_SYSTEM_B" /mnt6
    log "清空目标卷 /mnt6…"
    rsh 'test "$(/sbin/mount | /usr/bin/grep -c "/dev/disk0s1s'"$T_MNT_SYSTEM_B"' on /mnt6")" -eq 1 && /bin/rm -rf /mnt6/.[!.]* /mnt6/*'

    log "流式写入 rootfs（约 25 分钟）…"
    /usr/bin/tar -cpf - -C "$mnt" . | ssh_run "/usr/bin/tar --numeric-owner -xpf - -C /mnt6" ||
        die "rootfs 流式写入失败"

    ssh_ensure
    log "$(rsh 'ls -ln /mnt6/sbin/launchd /mnt6/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64')"
    return 0
}

# ---------- patch-rootfs ----------
# 与 Python 版一致：只跑 rootfs 层里 role ∈ {overlay, finalize} 的补丁，
# 顺序取自注册表（已做 role 排序 + 同层依赖拓扑）。
patch_apply() {   # id
    case "$1" in
        rootfs.finish)    stage_finish ;;
        rootfs.set_roles) stage_set_roles ;;
        *)                ov_apply "$1" ;;
    esac
}

stage_patch_rootfs() {
    local layer role id feat note ran=0 skipped=0 expected=0 list
    local saw_finish=0 saw_roles=0
    list="$(patch_selection_file)" || die "无法创建补丁清单文件"
    select_patches "$OPT_FEATURES" "$OPT_PATCHES" "$OPT_EXCLUDE" \
        "$T_BASE_DT" "$T_BASE_KC" "${OPT_PATCHES_SET:-0}" "${T_PATCHES:-}" >"$list" ||
        { rm -f "$list"; die "补丁选择失败"; }

    expected="$(awk -F'\t' '$1 == "rootfs" && ($2 == "overlay" || $2 == "finalize")' "$list" |
        wc -l | tr -d ' ')"
    [ "$expected" -gt 0 ] ||
        { rm -f "$list"; die "选挂里没有 rootfs overlay/finalize 补丁（检查 --features/--exclude）"; }

    if dry; then
        # 用 fd 3 读清单：循环体里的命令（尤其 ssh）会继承 stdin，
        # 如果清单在 stdin 上，远端命令会把剩余行吃掉，导致只跑前几个补丁。
        while IFS="$(printf '\t')" read -r -u 3 layer role id feat; do
            [ "$layer" = "rootfs" ] || continue
            case "$role" in overlay|finalize) ;; *) continue ;; esac
            if [ "$(patch_manual "$id")" = "1" ] && [ "${OPT_ALLOW_MANUAL:-0}" -ne 1 ]; then
                warn "跳过 manual patch ${id}（加 --allow-manual 才执行）；$(patch_note "$id")"
                continue
            fi
            log "→ $id  ($(patch_note "$id"))"
        done 3<"$list"
        log "dry-run：选挂已校验（${expected} 个 rootfs 补丁），跳过 rootfs 补丁应用。"
        [ "$list" = "$WK/patches-selected.txt" ] || rm -f "$list"
        return 0
    fi

    ssh_ensure
    mount_vol "$T_MNT_SYSTEM_B" "$OV_MNT"
    while IFS="$(printf '\t')" read -r -u 3 layer role id feat; do
        [ "$layer" = "rootfs" ] || continue
        case "$role" in overlay|finalize) ;; *) continue ;; esac
        case "$id" in
            rootfs.finish)    saw_finish=1 ;;
            rootfs.set_roles) saw_roles=1 ;;
        esac
        if [ "$(patch_manual "$id")" = "1" ] && [ "${OPT_ALLOW_MANUAL:-0}" -ne 1 ]; then
            warn "跳过 manual patch ${id}（加 --allow-manual 才执行）；$(patch_note "$id")"
            skipped=$(( skipped + 1 ))
            continue
        fi
        note="$(patch_note "$id")"
        log "→ $id  (${note})"
        patch_apply "$id"
        ran=$(( ran + 1 ))
    done 3<"$list"
    sync_dev
    donor_umount_all

    # 完整性闸门：之前这里被 ssh 吃掉 stdin，只跑了前两个补丁却报"完成"，
    # 导致 rootfs 没有 finish/set_roles（开机即挂）。
    [ $(( ran + skipped )) -eq "$expected" ] ||
        die "rootfs 补丁只执行了 $((ran + skipped))/${expected} 个（stdin 被吃掉或中途退出），rootfs 不完整；请重跑 patch-rootfs"
    if awk -F'\t' '$3 == "rootfs.finish" { f = 1 } END { exit !f }' "$list"; then
        [ "$saw_finish" -eq 1 ] || die "rootfs.finish 未执行，rootfs 不完整"
    fi
    if awk -F'\t' '$3 == "rootfs.set_roles" { f = 1 } END { exit !f }' "$list"; then
        [ "$saw_roles" -eq 1 ] || die "rootfs.set_roles 未执行，role 未设置"
    fi

    # 记录安装时的选挂，供 build 对比（避免构建组件与已安装 rootfs 不一致却无提示）
    selection_ids "$list" >"$WK/install-selection.txt"
    cp "$list" "$WK/patches-install.txt" 2>/dev/null || true
    ok "rootfs 补丁完成，共 ${ran} 个（跳过 manual ${skipped} 个，共 ${expected} 个）。"
    return 0
}

# ---------- fix-icons（已安装系统的主屏图标修复）----------
# iOS13 的 Mail/Maps/Notes 等系统 App 在 DataB 的 /staged_system_apps 下，
# 安装时用的是 j96(iPad) 的 Assets.car（只有 pad idiom），iPhone 会显示白色占位图标。
# 这里只替换这些 App 的图标资源 + 清 SpringBoard 图标缓存，不动用户数据。
stage_fix_icons() {
    local donor j96 list tmp n
    if dry; then log "dry-run：跳过图标修复。"; return 0; fi
    ssh_ensure
    donor="$(donor_mount "$T_UI_DONOR")" || die "挂载 UI donor 失败: $T_UI_DONOR"
    j96="$(donor_mount j96)" || die "挂载 j96 rootfs 失败"
    list="$WK/phone-ui/fix-staged-icons.txt"
    tmp="$WK/phone-ui/fix-staged-icons.deploy.txt"
    ov_icon_scan_root "$donor" "$j96" "private/var/staged_system_apps" "$list"
    [ -s "$list" ] || die "没有找到需要修复的 staged App 图标（UI donor 不匹配？）"
    sed 's#^private/var/##' "$list" >"$tmp"

    mount_vol "$T_MNT_SYSTEM12" /mnt1 ro
    ensure_sep
    mount_data_b
    ssh_run "test -d /mnt7/staged_system_apps" >/dev/null 2>&1 ||
        die "DataB 上没有 /staged_system_apps（系统尚未完成安装？）"

    n="$(wc -l <"$tmp" | tr -d ' ')"
    log "更新 ${n} 份 staged App 图标（来自 ${T_UI_DONOR}）…"
    # iOS 可能给 staged App 加 uchg/schg（或 DataB 挂载为只读），先清掉再写
    ssh_run "/usr/bin/chflags -R nouchg /mnt7/staged_system_apps" >/dev/null 2>&1 || true
    ssh_run "/usr/bin/chflags -R noschg /mnt7/staged_system_apps" >/dev/null 2>&1 || true

    # 先确认目标目录能"新建并写入"文件：iOS 首次启动后给 staged App 加的保护
    # 会同时禁止覆盖和新建，这种情况下 ramdisk 改不了，只能重建 DataB 让 finish 写入。
    tdir="/mnt7/$(dirname "$(head -1 "$tmp")")"
    if ! ssh_run "echo x > \"$tdir/.n61-wt\" && rm -f \"$tdir/.n61-wt\"" >/dev/null 2>&1; then
        warn "目标目录属性: $(ssh_run "ls -ldO \"$tdir\"" 2>&1 || true)"
        die "DataB 上的 staged App 目录不允许新建/写入文件（iOS 数据保护）。
  ramdisk 下无法覆盖这类文件，请改用重建 DataB（图标会在 finish 时写入）：
    sudo ./n61.sh -y volumes --recreate-data
    sudo ./n61.sh -y patch-rootfs
  （DataB 上的数据/激活记录会丢）
  之后 DFU 重新 boot。"
    fi

    # DataB 上的 staged App 受 iOS 数据保护时，"覆盖写"会 EPERM，但 unlink 通常仍允许。
    # 先把旧的 Assets.car 删掉，再让 tar 新建，绕过“覆盖已保护文件”的限制。
    if ! ssh_run "cd /mnt7 && while IFS= read -r f; do /bin/rm -f \"\$f\" || exit 1; done" <"$tmp"; then
        warn "目标文件属性: $(ssh_run "ls -ldO \"/mnt7/$(head -1 "$tmp")\"" 2>&1 || true)"
        die "无法删除旧 staged 图标（文件受 flags/数据保护）。
  可改用重建 DataB（在保护生效前写入）：
    sudo ./n61.sh -y volumes --recreate-data
    sudo ./n61.sh -y patch-rootfs
  （DataB 上的数据/激活记录会丢失）"
    fi
    log "  已删除旧图标，重新写入…"

    deploy_relative_paths "$donor/private/var" "/mnt7" "$tmp"

    log "清理 SpringBoard 图标缓存…"
    rsh "/bin/rm -rf /mnt7/mobile/Library/Caches/com.apple.IconsCache"
    sync_dev
    umount_vols /mnt1 /mnt7
    ok "图标修复完成（${n} 个文件）。重新 boot 进 iOS13 后生效。"
}

# ---------- finish（rootfs.finish）----------
stage_finish() {
    local apfs14 encrypted=0 keybags
    [ -n "${T_DONOR_APFS14:-}" ] || die "清单未定义 T_DONOR_APFS14"
    apfs14="$(donor_dir)/$T_DONOR_APFS14"
    [ -d "$apfs14" ] || die "缺少 iOS14 fsck 资产: $apfs14"
    data_is_encrypted && encrypted=1

    mount_vol "$T_MNT_SYSTEM_B" /mnt6
    mount_vol "$T_MNT_SYSTEM12" /mnt1 ro
    if [ "$encrypted" -eq 1 ]; then
        ensure_systembag
    else
        mount_vol "$T_MNT_DATA_B" /mnt7
    fi
    # 兜底：确认 /mnt7 真的是 DataB（防止把 var/keybags 写进 ramdisk 根）
    rsh "/sbin/mount | /usr/bin/grep -q \"/dev/disk0s1s${T_MNT_DATA_B} on /mnt7\"" ||
        die "DataB 未挂载到 /mnt7，拒绝写入 private/var/keybags"

    log "private/var → DataB…"
    rsh "/bin/cp -a /mnt6/private/var/. /mnt7/"
    # 清掉旧的 SpringBoard 图标缓存（staged App 图标来自 UI donor）
    rsh "/bin/rm -rf /mnt7/mobile/Library/Caches/com.apple.IconsCache"

    log "xarts / preboot 目录…"
    rsh "mkdir -p /mnt6/private/xarts /mnt6/private/preboot && chmod 755 /mnt6/private/xarts /mnt6/private/preboot"

    log "换 iOS14 fsck + apfs.fs（原文件改名 *Backup）…"
    rsh "cd /mnt6 && { [ -e sbin/fsckBackup ] || mv sbin/fsck sbin/fsckBackup; } &&
        { [ -e System/Library/Filesystems/apfs.fsBackup ] ||
          mv System/Library/Filesystems/apfs.fs System/Library/Filesystems/apfs.fsBackup; }"
    COPYFILE_DISABLE=1 /usr/bin/tar --uid 0 --gid 0 --no-xattrs -cf - \
        -C "$apfs14" ./sbin/fsck ./System/Library/Filesystems/apfs.fs |
        ssh_run "/usr/bin/tar --numeric-owner -xpf - -C /mnt6 &&
            chmod 755 /mnt6/System/Library/Filesystems/apfs.fs" ||
        die "fsck/apfs.fs 替换失败"

    log "SEP 固件（来自 iOS12 s1）…"
    rsh "/bin/cp -a /mnt1/usr/standalone/firmware/sep-firmware.img4 /mnt6/usr/standalone/firmware/"

    if [ "$encrypted" -eq 1 ]; then
        log "保留本次为加密 DataB 创建的 systembag…"
        ssh_run "test -s /mnt7/keybags/systembag.kb" ||
            die "systembag 缺失：加密 DataB 需要 SEP 正常加载并成功执行 create_systembag（检查上面的 SEP/ensure_systembag 输出）"
    else
        keybags="$(state_dir)/keybags.tar"
        [ -f "$keybags" ] || die "缺少 ${keybags}（--data-protection none 时需自备越狱 iOS12 的 keybags）"
        log "keybags → DataB…"
        ssh_run "/usr/bin/tar --numeric-owner -xpf - -C /mnt7" <"$keybags" ||
            die "keybags 写入失败"
    fi

    log "$(rsh "ls -ln /mnt6/sbin/fsck /mnt6/usr/standalone/firmware/sep-firmware.img4 /mnt7/keybags/systembag.kb")"
    sync_dev
    umount_vols /mnt1 /mnt7 /mnt6
    log "finish 完成，卷已卸载。"
}

# ---------- set_roles（rootfs.set_roles，必须最后一步、卷未挂载）----------
stage_set_roles() {
    apfs_set_roles "$T_ROLES" 1
}

# ---------- build（Phase C）----------

# iBSS：iOS12 已打过 n61 补丁的 iBSS，直接签 ibss
build_ibss() {   # out
    local src im4m
    src="$(derived_path ibss_src)" || die "缺少派生输入 ibss_src"
    im4m="$(im4m_path)" || die "缺少 IM4M（先跑 ./n61.sh extract-im4m）"
    "$(tool img4)" -i "$src" -A -T ibss -M "$im4m" -o "$1" >/dev/null ||
        die "iBSS 签名失败"
}

# iBEC：iBoot64Patcher 注入 boot-args → kairos 让 iBoot 认 rd= 根分区 → 签 ibec
build_ibec() {   # out
    local patched="$WK/iBEC.patched" kaired="$WK/iBEC.kairos" src im4m
    src="$(derived_path ibec_dec)" || die "缺少派生输入 ibec_dec"
    im4m="$(im4m_path)" || die "缺少 IM4M（先跑 ./n61.sh extract-im4m）"
    "$(tool iBoot64Patcher)" "$src" "$patched" -b "$T_BOOTARGS" -n >/dev/null 2>&1 ||
        die "iBoot64Patcher 失败"
    "$(tool kairos)" "$patched" "$kaired" -d "$T_ROOT_PART" >/dev/null 2>&1 ||
        die "kairos 失败"
    "$(tool img4)" -i "$kaired" -A -T ibec -M "$im4m" -o "$1" >/dev/null ||
        die "iBEC 签名失败"
}

# KernelCache：基底 → 变换链 → mkcomplzss + watchtower → 签 rkrn（含 roundtrip 校验）
build_kc() {   # out list
    local out="$1" list="$2" id base
    base="$(awk -F'\t' '$1 == "kc" && $2 == "base" { print $3; exit }' "$list")"
    [ "$base" = "kc.j96_clean" ] ||
        warn "kc base 为 ${base:-无}，bash 版构建链按 kc.j96_clean 实现，产物可能不符合预期"
    kc_base
    for id in $(awk -F'\t' '$1 == "kc" && $2 == "transform" { print $3 }' "$list"); do
        log "  kc transform: $id"
        kc_transform "$id" "$KC_ART" "$WK/$(kc_out_name "$id")"
        KC_ART="$WK/$(kc_out_name "$id")"
    done
    kc_pack "$KC_ART" "$out"
}

stage_build() {
    local list sig n
    list="$(patch_selection_file)" || die "无法创建补丁清单文件"
    select_patches "$OPT_FEATURES" "$OPT_PATCHES" "$OPT_EXCLUDE" \
        "$T_BASE_DT" "$T_BASE_KC" "${OPT_PATCHES_SET:-0}" "${T_PATCHES:-}" >"$list" ||
        { rm -f "$list"; die "补丁选择失败"; }

    if dry; then
        log "dry-run：选挂已校验（$(wc -l <"$list" | tr -d ' ') 项），跳过构建。"
        [ "$list" = "$WK/patches-selected.txt" ] || rm -f "$list"
        return 0
    fi

    preflight_build_inputs
    awk -F'\t' '$1 == "kc" && $2 == "base"' "$list" | grep -q . ||
        die "未选中 kc base（清单 bases['kc']）"
    awk -F'\t' '$1 == "dt" && $2 == "base"' "$list" | grep -q . ||
        die "未选中 dt base（清单 bases['dt']）"

    sig="$(selection_ids "$list")"
    if [ -f "$WK/install-selection.txt" ] && [ "$(cat "$WK/install-selection.txt")" != "$sig" ]; then
        warn "本次选挂与上次 patch-rootfs 不同，构建出的启动组件可能与已安装 rootfs 不匹配。"
        warn "  安装时 $(wc -l <"$WK/install-selection.txt" | tr -d ' ') 项；本次 $(printf '%s\n' "$sig" | wc -l | tr -d ' ') 项"
        warn "  安装清单: $WK/install-selection.txt；本次清单: $list"
    fi

    log "构建启动组件 → $WK"

    log "iBSS…"
    build_ibss "$WK/boot_iBSS.img4"

    log "iBEC（boot-args + kairos + 签名）…"
    build_ibec "$WK/boot_iBEC.img4"

    log "DeviceTree（dt patch 资产 + 签 rdtr）…"
    build_dt "$WK/boot_DT.img4" "$list"

    if [ "${T_FULL_TRUSTCACHE:-0}" = "1" ]; then
        log "TrustCache（完整：原版 TC ∪ 本次新增二进制）…"
        build_tc "$WK/boot_TC.img4"
    else
        local tc im4m
        tc="$(derived_path trustcache)" || die "缺少派生输入 trustcache"
        im4m="$(im4m_path)" || die "缺少 IM4M（先跑 ./n61.sh extract-im4m）"
        log "TrustCache（原版静态 TC 直接签 rtsc）…"
        "$(tool img4)" -i "$tc" -A -T rtsc -M "$im4m" \
            -o "$WK/boot_TC.img4" >/dev/null || die "TrustCache 签名失败"
    fi

    log "KernelCache（基底 + 变换 + mkcomplzss + watchtower + 签 rkrn）…"
    build_kc "$WK/boot_KC.img4" "$list"

    log "已构建的组件："
    for n in iBSS iBEC DT TC KC; do
        printf '  boot_%s.img4  %s\n' "$n" \
            "$([ -f "$WK/boot_$n.img4" ] && bin_len "$WK/boot_$n.img4" || echo 缺)"
    done
    return 0
}

# ---------- install ----------
stage_install() {
    # 独立跑 install 时也要在写盘前检查（Health 缓存/donor/APFS14）
    if ! dry; then
        preflight_install_inputs
    fi
    stage_volumes || return 1
    stage_rootfs || return 1
    stage_patch_rootfs || return 1
    return 0
}

# ---------- boot ----------
stage_boot() {
    local n missing=0
    if dry; then log "dry-run：跳过设备发送。"; return 0; fi
    for n in iBSS iBEC DT TC KC; do
        [ -f "$WK/boot_$n.img4" ] || missing=1
    done
    if [ "$missing" -eq 1 ]; then
        log "缺少启动组件，先构建…"
        stage_build || return 1
    fi
    send_boot_chain
}

# ---------- all ----------
stage_all() {
    if ! dry; then
        preflight_install_inputs
        preflight_build_inputs
        preflight_ramdisk_assets
    fi
    stage_ramdisk || return 1
    stage_extract_im4m || return 1
    stage_install || return 1
    stage_build || return 1
    stage_boot || return 1
    return 0
}
