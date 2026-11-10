# shellcheck shell=bash
# 为新建的加密 DataB 创建 systembag，并保留设备全局 BAG1
# （对应 Python 版 patches/impl/rootfs/systembag.py）。
#
# 关键点：ramdisk 里 MobileKeyBag 的 KBSaveSystemBagHandle 第 5 个参数写死 0，
# 会重新生成 BAG1、破坏与已有数据的一致性；把 mov w4,#0 改成 #1 就沿用现有 BAG1 包裹材料。

SYSTEMBAG_FRAMEWORK="/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag"
SYSTEMBAG_REMOTE="/mnt6/.n56-bootstrap"
# 偏移与字节：mov w4, #0 → mov w4, #1
SYSTEMBAG_OFFSET=0x8d20
SYSTEMBAG_BEFORE="04008052"
SYSTEMBAG_AFTER="24008052"

# 本地文件按十六进制区间打补丁
file_patch_hex() {   # file offset before after
    local file="$1" off=$(( $2 )) before="$3" after="$4" cur esc i
    cur="$(dd if="$file" bs=1 skip="$off" count=$(( ${#before} / 2 )) 2>/dev/null |
        od -An -v -tx1 | tr -d ' \n')"
    [ "$cur" = "$before" ] ||
        die "打补丁失败：$(basename "$file")+0x$(printf '%x' "$off") 期望 ${before}，实际 $cur"
    esc=""
    i=0
    while [ "$i" -lt "${#after}" ]; do
        esc="$esc\\x${after:$i:2}"
        i=$(( i + 2 ))
    done
    printf '%b' "$esc" | dd of="$file" bs=1 seek="$off" conv=notrunc 2>/dev/null
}

ensure_systembag() {
    local device mode helper framework sdk native out
    ensure_sep     # 需已只读挂载 /mnt1
    # 必须确认挂载成功且可写：挂载失败时 /mnt7 只是 ramdisk 里的空目录，
    # 继续写 systembag/private/var 会静默写进 ramdisk，DataB 仍是空的（开机即挂）。
    mount_data_b
    if [ "$(ssh_run 'test -s /mnt7/keybags/systembag.kb && echo yes || true' 2>/dev/null)" = "yes" ]; then
        log "  systembag 已存在，跳过创建。"
        return 0
    fi

    log "  创建 systembag（保留 BAG1）…"
    sdk="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"
    [ -n "$sdk" ] || die "找不到 iPhoneOS SDK（需要 Xcode 命令行工具）"
    mkdir -p "$WK/systembag"
    helper="$WK/systembag/create_systembag"
    clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=12.0 -O2 \
        "$REPO/tools/systembag/create_systembag.c" -o "$helper" ||
        die "编译 create_systembag 失败"
    codesign -s - -f --entitlements "$REPO/tools/systembag/create_systembag.entitlements" \
        "$helper" >/dev/null 2>&1 || die "签名 create_systembag 失败"

    native="$WK/systembag/MobileKeyBag.native"
    out="$WK/systembag/MobileKeyBag.preserve-BAG1"
    pull_file "$SYSTEMBAG_FRAMEWORK" "$native"
    cp "$native" "$out"
    file_patch_hex "$out" "$SYSTEMBAG_OFFSET" "$SYSTEMBAG_BEFORE" "$SYSTEMBAG_AFTER"
    codesign -s - -f "$out" >/dev/null 2>&1 || die "签名 MobileKeyBag 失败"

    deploy_file "$helper" "$SYSTEMBAG_REMOTE/create_systembag"
    deploy_file "$out" "$SYSTEMBAG_REMOTE/MobileKeyBag.preserve-BAG1"
    rsh "chmod 755 \"$SYSTEMBAG_REMOTE/create_systembag\" \"$SYSTEMBAG_REMOTE/MobileKeyBag.preserve-BAG1\";
        mkdir -p /mnt7/keybags && chmod 700 /mnt7/keybags"
    log "$(rsh "\"$SYSTEMBAG_REMOTE/create_systembag\" --create /mnt7 \"$SYSTEMBAG_REMOTE/MobileKeyBag.preserve-BAG1\"")"
    rsh "rm -rf \"$SYSTEMBAG_REMOTE\"; test -s /mnt7/keybags/systembag.kb"
    sync_dev
}
