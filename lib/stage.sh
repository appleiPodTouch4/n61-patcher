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

# ---------- patch-rootfs（Phase B）----------
stage_patch_rootfs() {
    die "patch-rootfs 的 bash 版在 Phase B 实现（overlay + finish + 改 role）。当前请用 Python 版：sudo python3 n56patcher.py patch-rootfs --workdir $WK"
}

# ---------- build（Phase C）----------
stage_build() {
    die "build 的 bash 版在 Phase C 实现（KC/DT 二进制变换尚未移植）。现阶段请用 Python 版构建：python3 n56patcher.py build --workdir $WK，产物 boot_*.img4 本脚本的 boot 阶段可直接使用。"
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
    die "build 阶段在 Phase C 实现（KC/DT 二进制变换）。install 已完成，可用 Python 版构建后再 ./n61.sh boot。"
}
