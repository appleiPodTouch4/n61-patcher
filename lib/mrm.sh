# shellcheck shell=bash
# 生产 mrm 缓存重建（对应 Python 版 patches/impl/rootfs/mrm.py）。
#
# /System/Library/Caches/com.apple.xpc.launchd/mrm.plist 是 launchd 的任务缓存：
# 我们从 j96 的 stock 缓存出发，换掉 fairplayd.A2 → H2，补入为本次移植新增的守护进程
# （healthappd / NanoRegistry / checkra1n），再生成同名分离签名 mrm.plist.sig。
#
# 用 PlistBuddy（路径分隔符是 ':'，键里的 '/' 与 '.' 都不冲突；plutil 的 keypath 用 '.'，
# 遇到 com.apple.xxx.plist 这类键无法表达）。

PB="/usr/libexec/PlistBuddy"

pb_has() {   # plist entry
    "$PB" -c "Print $2" "$1" >/dev/null 2>&1
}

pb_do() {   # plist cmd  （失败即中止）
    "$PB" -c "$2" "$1" >/dev/null 2>&1 ||
        die "PlistBuddy 失败: $2（$(basename "$1")）"
}

pb_keys() {   # plist entry → 子键列表（只取第一层：PlistBuddy 的层级缩进是 4 空格）
    "$PB" -c "Print $2" "$1" 2>/dev/null |
        sed -n 's/^    \([^ ].*[^ ]\) = .*/\1/p'
}

# 生成 mrm.plist 与 mrm.plist.sig（缓存产物，重复调用直接复用）
build_mrm() {
    local dir plist sig j96 n66 n66mrm stock features name src key
    dir="$WK/mrm"
    plist="$dir/mrm.plist"
    sig="$dir/mrm.plist.sig"
    if [ -s "$plist" ] && [ -s "$sig" ]; then
        return 0
    fi
    mkdir -p "$dir"
    j96="$(donor_mount j96)"
    n66="$(donor_mount n66)"
    stock="$j96/System/Library/Caches/com.apple.xpc.launchd/mrm.plist"
    n66mrm="$n66/System/Library/Caches/com.apple.xpc.launchd/mrm.plist"
    [ -f "$stock" ] || die "j96 rootfs 缺少 mrm.plist"
    [ -f "$n66mrm" ] || die "N66 rootfs 缺少 mrm.plist"
    features=" $T_FEATURES "

    log "  重建 mrm 缓存…"
    cp "$stock" "$plist"

    # 1) 去掉旧的 fairplayd.A2
    pb_has "$plist" ":LaunchDaemons:/System/Library/LaunchDaemons/com.apple.fairplayd.A2.plist" &&
        "$PB" -c "Delete :LaunchDaemons:/System/Library/LaunchDaemons/com.apple.fairplayd.A2.plist" \
            "$plist" >/dev/null 2>&1

    # 2) 补入本次新增的守护进程定义（来自 N66 17H35 的同名 plist）
    local names="com.apple.fairplayd.H2.plist" esc
    case "$features" in *" health "*) names="$names com.apple.healthappd.plist" ;; esac
    case "$features" in
        *" bluetooth "*)
            names="$names com.apple.nanoregistryd.plist com.apple.nanoregistrylaunchd.plist"
            ;;
    esac
    for name in $names; do
        src="$n66/System/Library/LaunchDaemons/$name"
        [ -f "$src" ] || die "N66 rootfs 缺少 launchd plist: $name"
        key="/System/Library/LaunchDaemons/$name"
        pb_has "$plist" ":LaunchDaemons:$key" &&
            "$PB" -c "Delete :LaunchDaemons:$key" "$plist" >/dev/null 2>&1
        pb_do "$plist" "Add :LaunchDaemons:$key dict"
        pb_do "$plist" "Merge \"$src\" :LaunchDaemons:$key"
    done

    # 3) 手机 App（Health/Phone/Wallet）的 AppExtension 定义
    case "$features" in
        *" health "*|*" ui "*)
            log "  补入手机 App 的 AppExtension 定义…"
            pb_has "$plist" ":AppExtensions" || pb_do "$plist" "Add :AppExtensions dict"
            pb_keys "$n66mrm" ":AppExtensions" |
            while IFS= read -r key; do
                [ -n "$key" ] || continue
                case "$key" in
                    /Applications/Health.app/*|/Applications/MobilePhone.app/*|\
                    /Applications/Passbook.app/*) ;;
                    *) continue ;;
                esac
                # PlistBuddy 的 Merge 只认"文件根字典"，而这里要合的是二级子字典，
                # 所以先用 plutil -extract 把该条目单独抽成 plist（键里的 '.' 需转义）。
                esc="$(printf '%s' "$key" | sed 's/\./\\./g')"
                if ! plutil -extract "AppExtensions.$esc" xml1 -o "$dir/.appex.plist" \
                        "$n66mrm" >/dev/null 2>&1; then
                    warn "  AppExtension 抽取失败: $key"
                    continue
                fi
                pb_has "$plist" ":AppExtensions:$key" &&
                    "$PB" -c "Delete :AppExtensions:$key" "$plist" >/dev/null 2>&1
                "$PB" -c "Add :AppExtensions:$key dict" "$plist" >/dev/null 2>&1
                "$PB" -c "Merge \"$dir/.appex.plist\" :AppExtensions:$key" "$plist" >/dev/null 2>&1 ||
                    warn "  AppExtension 合入失败: $key"
            done
            rm -f "$dir/.appex.plist"
            ;;
    esac

    # 4) 清掉历史遗留的 n56 调试/过渡守护进程
    pb_keys "$plist" ":LaunchDaemons" |
    while IFS= read -r key; do
        case "$key" in
            /System/Library/LaunchDaemons/com.n56.diag.*|*encryption-probe*|\
            *com.n56.phone-apps.*)
                "$PB" -c "Delete :LaunchDaemons:$key" "$plist" >/dev/null 2>&1
                ;;
        esac
    done

    # 5) checkra1n 的引导守护进程（生成逻辑与 overlay 共用）
    case "$features" in
        *" checkra1n "*)
            checkra1n_prepare
            key="/System/Library/LaunchDaemons/com.n56.checkra1n.plist"
            src="$CHECKRA1N_ROOT/System/Library/LaunchDaemons/com.n56.checkra1n.plist"
            [ -f "$src" ] || die "checkra1n 守护进程 plist 未生成"
            pb_has "$plist" ":LaunchDaemons:$key" &&
                "$PB" -c "Delete :LaunchDaemons:$key" "$plist" >/dev/null 2>&1
            pb_do "$plist" "Add :LaunchDaemons:$key dict"
            pb_do "$plist" "Merge \"$src\" :LaunchDaemons:$key"
            ;;
    esac

    plutil -convert binary1 "$plist" >/dev/null 2>&1 || die "mrm.plist 转二进制失败"
    codesign -s - -f --digest-algorithm=sha1,sha256 --pagesize 4096 \
        --detached "$sig" "$plist" >/dev/null 2>&1 || die "mrm 分离签名失败"
    codesign -d -vvvv --detached "$sig" "$plist" >/dev/null 2>&1 ||
        die "mrm 分离签名校验失败"
    ok "  mrm.plist + .sig 已生成（$(/usr/bin/stat -f %z "$plist") 字节）"
}
