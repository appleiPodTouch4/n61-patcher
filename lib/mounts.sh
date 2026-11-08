# shellcheck shell=bash
# 源 rootfs（IPSW 里的 DMG）只读挂载。
#
# 必须 -owners on：overlay 部署后要按源文件真实属主（0:0 等）chown 到设备，
# 若挂成 noowners，所有文件都会以调用者身份（501:20）出现，rootfs 属主被污染。
# 由于该限制 + rootfs 属主保真，patch-rootfs 阶段要求 root。
#
# 缓存用标记文件（$WK/mounts/.<kind>），因为捐赠挂载点在 $(...) 子 shell 里被调用，
# 函数内变量无法跨子 shell 保留。

donor_mounts_dir() {
    mkdir -p "$WK/mounts"
    printf '%s\n' "$WK/mounts"
}

# donor_mount <kind> → 挂载点
donor_mount() {
    local kind="$1" mark mnt dmg build expect
    mark="$(donor_mounts_dir)/.$kind"
    if [ -f "$mark" ]; then
        mnt="$(cat "$mark")"
        if [ -d "$mnt" ] && /sbin/mount | grep -q " on $mnt "; then
            printf '%s\n' "$mnt"
            return 0
        fi
        rm -f "$mark"
    fi
    dmg="$(rootfs_dmg "$kind")"
    mnt="$(donor_mounts_dir)/$kind"
    mkdir -p "$mnt"
    # 复用已挂好的（上一次运行中断时常见），避免重复 attach 撞 "资源忙"
    if /sbin/mount | grep -q " on $mnt " &&
        [ -f "$mnt/System/Library/CoreServices/SystemVersion.plist" ]; then
        printf '%s\n' "$mnt" >"$mark"
        printf '%s\n' "$mnt"
        return 0
    fi
    hdiutil attach -readonly -owners on -nobrowse -mountpoint "$mnt" "$dmg" >/dev/null ||
        die "${kind} rootfs DMG 挂载失败: $dmg"
    if /sbin/mount | grep -q " on $mnt .*noowners"; then
        hdiutil detach "$mnt" >/dev/null 2>&1 || true
        die "${kind} rootfs 未以 owners 模式挂载（需 sudo 运行）"
    fi
    # 挂载点必须真的是 rootfs 根（镜像残留挂载/损坏时这里就不是空的）
    if [ ! -f "$mnt/System/Library/CoreServices/SystemVersion.plist" ]; then
        hdiutil detach "$mnt" >/dev/null 2>&1 || true
        die "${kind} rootfs 挂载后看不到 SystemVersion.plist（${mnt}）：可能是同一镜像已残留挂载，先 reboot 或手动 hdiutil detach"
    fi
    expect="$(target_build "$kind")"
    if [ -n "$expect" ]; then
        build="$(/usr/bin/plutil -extract ProductBuildVersion raw -o - \
            "$mnt/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null)"
        if [ "$build" != "$expect" ]; then
            hdiutil detach "$mnt" >/dev/null 2>&1 || true
            die "${kind} rootfs build 为 ${build:-未知}，当前 profile 需要 $expect"
        fi
    fi
    printf '%s\n' "$mnt" >"$mark"
    printf '%s\n' "$mnt"
}

donor_umount_all() {
    local dir m name
    dir="$(donor_mounts_dir)"
    for m in "$dir"/.[a-z]*; do
        [ -f "$m" ] || continue
        name="$(basename "$m")"
        name="${name#.}"
        [ -d "$dir/$name" ] && hdiutil detach "$dir/$name" >/dev/null 2>&1
        rm -f "$m"
    done
}

# 本机 SystemA（iOS12.5.8 系统卷）只读挂载 + 版本校验，对应 Python 的 verify_device_system。
DEVICE_S1_VERIFIED=0
verify_device_system() {
    [ "$DEVICE_S1_VERIFIED" -eq 1 ] && return 0
    mount_vol "$T_MNT_SYSTEM12" /mnt1 ro
    local actual expect path
    path="/mnt1/System/Library/CoreServices/SystemVersion.plist"
    actual="$(ssh_run "/binpack/usr/bin/plutil -extract ProductBuildVersion raw -o - \"$path\" 2>/dev/null" 2>/dev/null || true)"
    if [ -z "$actual" ]; then
        actual="$(ssh_run "cat \"$path\"" 2>/dev/null | tr -d '\000' |
            awk '/ProductBuildVersion/{getline; gsub(/[^A-Za-z0-9]/,""); print; exit}')"
    fi
    expect="$(target_build "${T_MODEL%ap}")"
    if [ -n "$expect" ] && [ "$actual" != "$expect" ]; then
        die "SystemA build 为 ${actual:-未知}，当前 profile 需要 $expect"
    fi
    [ -n "$actual" ] || warn "未能读出 SystemA 的 build（继续）。"
    DEVICE_S1_VERIFIED=1
}
