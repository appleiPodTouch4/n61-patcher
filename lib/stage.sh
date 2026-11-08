# shellcheck shell=bash
# 各阶段实现。对应 Python 版 n56patcher.py 的 Flow。

require_root() {
    [ "$(id -u)" -eq 0 ] || die "$1 需要写设备存储，请用 sudo 运行：sudo ./n61.sh $1"
}

dry() { [ "${OPT_DRY_RUN:-0}" -eq 1 ]; }

# ---------- list ----------
stage_list() {
    log "目标 $T_NAME  features=[$OPT_FEATURES]"
    select_patches "$OPT_FEATURES" "$OPT_PATCHES" "$OPT_EXCLUDE" "$T_BASE_DT" "$T_BASE_KC" |
        while IFS="$(printf '\t')" read -r layer role id feat; do
            printf '  [%-6s] %-9s %-9s %s\n' "$layer" "$role" "$feat" "$id"
        done
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
    local disk2 out
    if dry; then log "dry-run：跳过重提 IM4M。"; return 0; fi
    ssh_ensure
    mkdir -p "$REPO/state"
    disk2="$REPO/state/disk2.bin"
    out="$REPO/state/IM4M.bin"
    log "从 NOR(/dev/disk2) 读取 4MB 并提取 IM4M…"
    ssh_run "dd if=/dev/disk2 bs=256 count=16384 2>/dev/null" >"$disk2" ||
        die "NOR 读取失败"
    [ "$(wc -c <"$disk2" | tr -d ' ')" -ge 4096 ] ||
        die "NOR 读取异常，仅 $(wc -c <"$disk2" | tr -d ' ') 字节；确认 ramdisk 已就绪且 /dev/disk2 存在"
    "$(tool img4)" -i "$disk2" -m "$out" || die "IM4M 提取失败"
    ok "新 IM4M: $out ($(wc -c <"$out" | tr -d ' ') 字节)"
}

# ---------- volumes ----------
stage_volumes() {
    local encrypt=0
    if dry; then log "dry-run：跳过创建卷。"; return 0; fi
    ssh_ensure
    [ "${T_DATA_PROTECTION:-encrypted}" = "encrypted" ] && encrypt=1
    apfs_create_volumes "$T_VOL_CREATE" "$encrypt"
    [ "$encrypt" -eq 1 ] && apfs_report_data_encryption "DataB"
}

# ---------- rootfs ----------
stage_rootfs() {
    local dmg mnt ro_line
    if dry; then log "dry-run：跳过 rootfs 写入。"; return 0; fi
    require_root rootfs
    ssh_ensure
    dmg="$(rootfs_dmg j96)"
    mnt="$WK/mounts/j96"
    mkdir -p "$mnt"
    log "挂载 rootfs DMG（owners 模式）…"
    hdiutil attach -readonly -owners on -nobrowse -mountpoint "$mnt" "$dmg" >/dev/null ||
        die "rootfs DMG 挂载失败: $dmg"
    if /sbin/mount | grep -q " on $mnt .*noowners"; then
        hdiutil detach "$mnt" >/dev/null 2>&1
        die "rootfs 未以 owners 模式挂载"
    fi

    mount_vol "$T_MNT_SYSTEM_B" /mnt6
    log "清空目标卷 /mnt6…"
    rsh 'test "$(/sbin/mount | /usr/bin/grep -c "/dev/disk0s1s'"$T_MNT_SYSTEM_B"' on /mnt6")" -eq 1 && /bin/rm -rf /mnt6/.[!.]* /mnt6/*'

    log "流式写入 rootfs（约 25 分钟）…"
    /usr/bin/tar -cpf - -C "$mnt" . | ssh_run "/usr/bin/tar --numeric-owner -xpf - -C /mnt6" ||
        die "rootfs 流式写入失败"
    hdiutil detach "$mnt" >/dev/null 2>&1 || true

    ssh_ensure
    log "$(rsh 'ls -ln /mnt6/sbin/launchd /mnt6/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64')"
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
    local layer role id feat note ran=0 list="$WK/patches-selected.txt"
    if dry; then log "dry-run：跳过 rootfs 补丁。"; return 0; fi
    ssh_ensure
    select_patches "$OPT_FEATURES" "$OPT_PATCHES" "$OPT_EXCLUDE" \
        "$T_BASE_DT" "$T_BASE_KC" >"$list"
    mount_vol "$T_MNT_SYSTEM_B" "$OV_MNT"
    while IFS="$(printf '\t')" read -r layer role id feat; do
        [ "$layer" = "rootfs" ] || continue
        case "$role" in overlay|finalize) ;; *) continue ;; esac
        note="$(patch_note "$id")"
        log "→ $id  (${note})"
        patch_apply "$id"
        ran=$(( ran + 1 ))
    done <"$list"
    sync_dev
    donor_umount_all
    ok "rootfs 补丁完成，共 ${ran} 个。"
}

# ---------- finish（rootfs.finish）----------
stage_finish() {
    local apfs14 encrypted=0 keybags
    apfs14="$(donor_dir)/$T_DONOR_APFS14"
    [ -d "$apfs14" ] || die "缺少 iOS14 fsck 资产: $apfs14"
    [ "$T_DATA_PROTECTION" = "encrypted" ] && encrypted=1

    mount_vol "$T_MNT_SYSTEM_B" /mnt6
    mount_vol "$T_MNT_SYSTEM12" /mnt1 ro
    if [ "$encrypted" -eq 1 ]; then
        ensure_systembag
    else
        mount_vol "$T_MNT_DATA_B" /mnt7
    fi

    log "private/var → DataB…"
    rsh "/bin/cp -a /mnt6/private/var/. /mnt7/"

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
        rsh "test -s /mnt7/keybags/systembag.kb"
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
    "$(tool img4)" -i "$(derived_path ibss_src)" -A -T ibss -M "$(im4m_path)" -o "$1" \
        >/dev/null || die "iBSS 签名失败"
}

# iBEC：iBoot64Patcher 注入 boot-args → kairos 让 iBoot 认 rd= 根分区 → 签 ibec
build_ibec() {   # out
    local patched="$WK/iBEC.patched" kaired="$WK/iBEC.kairos"
    "$(tool iBoot64Patcher)" "$(derived_path ibec_dec)" "$patched" \
        -b "$T_BOOTARGS" -n >/dev/null 2>&1 || die "iBoot64Patcher 失败"
    "$(tool kairos)" "$patched" "$kaired" -d "$T_ROOT_PART" >/dev/null 2>&1 ||
        die "kairos 失败"
    "$(tool img4)" -i "$kaired" -A -T ibec -M "$(im4m_path)" -o "$1" >/dev/null ||
        die "iBEC 签名失败"
}

# KernelCache：基底 → 变换链 → mkcomplzss + watchtower → 签 rkrn（含 roundtrip 校验）
build_kc() {   # out list
    local out="$1" list="$2" id
    kc_base
    for id in $(awk -F'\t' '$1 == "kc" && $2 == "transform" { print $3 }' "$list"); do
        log "  kc transform: $id"
        kc_transform "$id" "$KC_ART" "$WK/$(kc_out_name "$id")"
        KC_ART="$WK/$(kc_out_name "$id")"
    done
    kc_pack "$KC_ART" "$out"
}

stage_build() {
    local list="$WK/patches-selected.txt" n
    if dry; then log "dry-run：跳过构建。"; return 0; fi
    select_patches "$OPT_FEATURES" "$OPT_PATCHES" "$OPT_EXCLUDE" \
        "$T_BASE_DT" "$T_BASE_KC" >"$list"
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
        log "TrustCache（原版静态 TC 直接签 rtsc）…"
        "$(tool img4)" -i "$(derived_path trustcache)" -A -T rtsc -M "$(im4m_path)" \
            -o "$WK/boot_TC.img4" >/dev/null || die "TrustCache 签名失败"
    fi

    log "KernelCache（基底 + 变换 + mkcomplzss + watchtower + 签 rkrn）…"
    build_kc "$WK/boot_KC.img4" "$list"

    log "已构建的组件："
    for n in iBSS iBEC DT TC KC; do
        printf '  boot_%s.img4  %s\n' "$n" \
            "$([ -f "$WK/boot_$n.img4" ] && bin_len "$WK/boot_$n.img4" || echo 缺)"
    done
}

# ---------- install ----------
stage_install() {
    stage_volumes
    stage_rootfs
    stage_patch_rootfs
}

# ---------- boot ----------
stage_boot() {
    if dry; then log "dry-run：跳过设备发送。"; return 0; fi
    send_boot_chain
}

# ---------- all ----------
stage_all() {
    stage_ramdisk
    stage_extract_im4m
    stage_install
    stage_build
}
