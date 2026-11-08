# shellcheck shell=bash
# checkra1n 引导层与 Cydia（对应 Python 版
# patches/impl/rootfs/checkra1n.py 与 patches/impl/rootfs/cydia.py）。
#
# 产物布局（$WK/checkra1n/rootfs 直接 tar 到 /mnt6）：
#   binpack/…                          checkra1n overlay-files
#   usr/local/share/checkra1n/ramdisk  checkra1n ramdisk-files（checkra1nd payload）
#   Applications/loader.app            checkra1n Loader
#   binpack/n56-init.sh                自定义 init（拉起 dropbear + 首次 dpkg 配置）
#   binpack/usr/bin/n56-jb-info        越狱信息小工具（现编译 + 伪签名）

CHECKRA1N_ROOT=""
LABEL="com.n56.checkra1n"
LOADER_LABEL="com.apple.checkra1nd"

checkra1n_assets() {
    printf '%s\n' "${N56_CHECKRA1N_ASSETS:-$(donor_dir)/checkra1n}"
}

# 生成 checkra1n overlay 根目录（幂等：已生成则直接返回）
checkra1n_prepare() {
    local assets root mark sdk
    if [ -n "$CHECKRA1N_ROOT" ] && [ -d "$CHECKRA1N_ROOT" ]; then
        return 0
    fi
    assets="$(checkra1n_assets)"
    root="$WK/checkra1n/rootfs"
    mark="$WK/checkra1n/.prepared"
    if [ -f "$mark" ] && [ -d "$root" ]; then
        CHECKRA1N_ROOT="$root"
        return 0
    fi
    [ -d "$assets" ] || die "缺少 checkra1n 资产: ${assets}（先跑 tools/setup.py）"

    log "  准备 checkra1n overlay…"
    rm -rf "$root"
    mkdir -p "$root/binpack" "$root/usr/local/share/checkra1n/ramdisk" \
        "$root/Applications" "$root/System/Library/LaunchDaemons" "$root/Library/LaunchDaemons"
    cp -a "$assets/overlay-files/." "$root/binpack/" ||
        die "复制 checkra1n overlay-files 失败"
    cp -a "$assets/ramdisk-files/." "$root/usr/local/share/checkra1n/ramdisk/" ||
        die "复制 checkra1n ramdisk-files 失败"
    if [ -d "$assets/loader.app" ]; then
        cp -a "$assets/loader.app" "$root/Applications/loader.app" ||
            die "复制 checkra1n loader.app 失败"
    fi

    cat >"$root/binpack/n56-init.sh" <<'INITEOF'
#!/binpack/bin/bash
export PATH=/binpack/usr/bin:/binpack/bin:/binpack/usr/sbin:/binpack/sbin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/var/root
umask 077
mkdir -p /private/var/run /private/var/root
/binpack/bin/launchctl load /Library/LaunchDaemons/com.apple.checkra1nd.plist
if [ -e /.n56-cydia-pending ]; then
    (
        sleep 30
        mount -uw /
        /usr/bin/dpkg --configure -a > /var/log/n56-cydia.log 2>&1 &&
            /binpack/usr/bin/uicache -p /Applications/Cydia.app >> /var/log/n56-cydia.log 2>&1 &&
            touch /.bootstrapped && rm -f /.n56-cydia-pending
    ) &
fi
if [ ! -s /private/var/dropbear_rsa_host_key ]; then
    /binpack/usr/bin/dropbearkey -t rsa -f /private/var/dropbear_rsa_host_key || exit 1
fi
exec /binpack/usr/sbin/dropbear -F -E -p 127.0.0.1:44 -S /binpack/bin/bash -r /private/var/dropbear_rsa_host_key
INITEOF
    chmod 755 "$root/binpack/n56-init.sh"

    # 越狱信息小工具：交叉编译 + 伪签名（无签名在 13.7 上无法执行）
    sdk="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"
    [ -n "$sdk" ] || die "找不到 iPhoneOS SDK（需要 Xcode 命令行工具）"
    clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=13.0 -Os \
        "$REPO/tools/n56-jb-info.c" -o "$root/binpack/usr/bin/n56-jb-info" ||
        die "编译 n56-jb-info 失败"
    codesign -s - -f --digest-algorithm=sha1,sha256 --pagesize 4096 \
        --entitlements "$REPO/tools/n56-jb-info.entitlements" \
        "$root/binpack/usr/bin/n56-jb-info" >/dev/null 2>&1 ||
        die "签名 n56-jb-info 失败"

    cat >"$root/System/Library/LaunchDaemons/$LABEL.plist" <<DAEMONEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/binpack/bin/bash</string>
		<string>--noprofile</string>
		<string>--norc</string>
		<string>/binpack/n56-init.sh</string>
	</array>
	<key>UserName</key><string>root</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>POSIXSpawnType</key><string>Interactive</string>
	<key>StandardOutPath</key><string>/var/log/n56-checkra1n.log</string>
	<key>StandardErrorPath</key><string>/var/log/n56-checkra1n.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/binpack/usr/bin:/binpack/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
</dict>
</plist>
DAEMONEOF

    cat >"$root/Library/LaunchDaemons/$LOADER_LABEL.plist" <<LOADEREOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LOADER_LABEL</string>
	<key>Program</key><string>/usr/local/share/checkra1n/ramdisk/payload</string>
	<key>ProgramArguments</key><array><string>checkra1nd</string></array>
	<key>UserName</key><string>root</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>MachServices</key>
	<dict><key>com.apple.checkra1n.loaderd</key><true/></dict>
	<key>StandardOutPath</key><string>/var/log/checkra1nd.log</string>
	<key>StandardErrorPath</key><string>/var/log/checkra1nd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/binpack/usr/bin:/binpack/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
</dict>
</plist>
LOADEREOF

    plutil -lint "$root/System/Library/LaunchDaemons/$LABEL.plist" >/dev/null 2>&1 ||
        die "com.n56.checkra1n.plist 校验失败"
    plutil -lint "$root/Library/LaunchDaemons/$LOADER_LABEL.plist" >/dev/null 2>&1 ||
        die "com.apple.checkra1nd.plist 校验失败"

    : >"$mark"
    CHECKRA1N_ROOT="$root"
}

# overlay: rootfs.checkra1n_bootstrap
checkra1n_bootstrap() {
    checkra1n_prepare
    mount_vol "$T_MNT_SYSTEM_B" "$OV_MNT"
    log "  部署 checkra1n 引导层（$(du -sh "$CHECKRA1N_ROOT" | awk '{print $1}')）"
    deploy_path "$CHECKRA1N_ROOT" "$OV_MNT" 0 0
    sync_dev
}

# ---------- Cydia ----------
CYDIA_BASE="https://assets.checkra.in/loader/ios"
CYDIA_CORE="$CYDIA_BASE/core/3bda4c4ddb50d7c89eec6260f42f7ba91535de64/strap.tar.lzma"
CYDIA_ARCHIVE="$CYDIA_BASE/cydia/0d1e4d2daec4c4b528e918df6c20281d24a90950/cydia.tar.lzma"
CYDIA_STATUS="$CYDIA_BASE/cydia/0d1e4d2daec4c4b528e918df6c20281d24a90950/cydia.status"
CYDIA_PENDING="/.n56-cydia-pending"

cydia_fetch() {   # url [sha256] → 本地路径
    local url="$1" want="${2:-}" name path
    name="$(basename "$url")"
    path="$REPO/ipsw/cache/cydia/$name"
    mkdir -p "$(dirname "$path")"
    if [ ! -f "$path" ]; then
        log "  下载 $name…"
        curl -fL --retry 3 --connect-timeout 20 -o "$path.part" "$url" ||
            die "下载失败: $url"
        mv "$path.part" "$path"
    fi
    if [ -n "$want" ]; then
        if [ "$(shasum -a 256 "$path" | awk '{print $1}')" != "$want" ]; then
            rm -f "$path"
            die "$name 校验失败，已删除（重跑会重新下载）"
        fi
    fi
    printf '%s\n' "$path"
}

# overlay: rootfs.cydia
cydia_install() {
    local archive status spec url want
    mount_vol "$T_MNT_SYSTEM_B" "$OV_MNT"
    for spec in \
        "$CYDIA_CORE d18b3fdd82e3b9f188ccff1a3fcb9a67eb1eda2c42164f109cff0c1973f01708" \
        "$CYDIA_ARCHIVE 400abcb7cf3586ae6ebbba17eeea2b2b06c35523383fa45c2d7bcad19f6b0712"; do
        url="${spec% *}"
        want="${spec##* }"
        archive="$(cydia_fetch "$url" "$want")"
        log "  解包 $(basename "$archive") → SystemB…"
        /usr/bin/bsdtar -cf - "@$archive" |
            ssh_run "/usr/bin/tar --numeric-owner -xpf - -C $OV_MNT" ||
            die "$(basename "$archive") 解包失败"
    done
    status="$(cydia_fetch "$CYDIA_STATUS")"
    ssh_run "cat >> $OV_MNT/Library/dpkg/status" <"$status" ||
        die "写入 dpkg status 失败"
    rsh "touch $OV_MNT$CYDIA_PENDING"
    sync_dev
}
