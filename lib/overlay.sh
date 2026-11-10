# shellcheck shell=bash
# rootfs overlay 引擎（对应 Python 版 core/overlay.py）。
#
# 清单来自 patches/overlays/<id>.conf（由 tools/export_registry.py 导出），
# 每行 10 列：source  dest  op  mode  uid  gid  offset  before  after  checks
# checks 形如 exists=1,nonzero=1,plist=1（缺省 exists/nonzero 为真）。
#
# 条目来源（source 前缀）：
#   device_s1:<path>     本机 SystemA（/mnt1，只读），设备端 cp -a 直拷
#   ipsw:<profile>:<path> IPSW rootfs donor（n61/n66/n71/j96，ui 为别名）
#   derive:<name>        本地生成（im4m / mrm-plist / mrm-sig）
#   patch:<name>         本地二进制补丁产物（installd / backupd / bluetoothd）
#   target:<path>        目标 rootfs 自身（只用于 delete / bytes-patch）

OV_MNT="/mnt6"

# ---------- source 解析 ----------
ov_split_source() {   # source → OV_KIND OV_PROFILE OV_PATH
    local value="$1"
    OV_PROFILE=""
    case "$value" in
        device_s1:*) OV_KIND=device_s1; OV_PATH="${value#device_s1:}" ;;
        ipsw:*)
            OV_KIND=ipsw
            OV_PROFILE="${value#ipsw:}"
            OV_PATH="${OV_PROFILE#*:}"
            OV_PROFILE="${OV_PROFILE%%:*}"
            ;;
        derive:*) OV_KIND=derive; OV_PATH="${value#derive:}" ;;
        patch:*)  OV_KIND=patch;  OV_PATH="${value#patch:}" ;;
        target:*) OV_KIND=target; OV_PATH="${value#target:}" ;;
        *) die "不支持的 overlay source: $value" ;;
    esac
    # ui 是别名：解析到目标清单的 ui_donor
    [ "$OV_PROFILE" = "ui" ] && OV_PROFILE="$T_UI_DONOR"
}

# ---------- 校验 ----------
ov_check() {   # remote checks label
    local remote="$1" checks="$2" label="$3"
    local exists=1 nonzero=1 plist=0 sha="" kv key val oldifs
    oldifs="$IFS"
    IFS=","
    for kv in $checks; do
        key="${kv%%=*}"
        val="${kv#*=}"
        case "$key" in
            exists)  exists="$val" ;;
            nonzero) nonzero="$val" ;;
            plist)   plist="$val" ;;
            sha256)  sha="$val" ;;
        esac
    done
    IFS="$oldifs"

    if [ "$exists" -eq 1 ] && ! ssh_run "test -e \"$remote\"" >/dev/null 2>&1; then
        die "overlay 校验失败（不存在）: $label"
    fi
    if [ "$exists" -eq 0 ] && ! ssh_run "test ! -e \"$remote\"" >/dev/null 2>&1; then
        die "overlay 校验失败（应已删除）: $label"
    fi
    if [ "$nonzero" -eq 1 ] &&
        ! ssh_run "test -d \"$remote\" || test -s \"$remote\"" >/dev/null 2>&1; then
        die "overlay 校验失败（为空）: $label"
    fi
    if [ "$plist" -eq 1 ] && ! ov_plist_ok "$remote"; then
        die "overlay 校验失败（plist 解析）: $label"
    fi
    if [ -n "$sha" ]; then
        local actual
        actual="$(ssh_run "/binpack/usr/bin/shasum -a 256 \"$remote\" 2>/dev/null ||
            /usr/bin/shasum -a 256 \"$remote\" 2>/dev/null" | awk '{print $1}')"
        [ "$actual" = "$sha" ] || die "overlay 校验失败（sha256 $actual ≠ ${sha}）: $label"
    fi
}

ov_plist_ok() {   # remote
    local remote="$1"
    if ssh_run "test -x /binpack/usr/bin/plutil" >/dev/null 2>&1; then
        ssh_run "/binpack/usr/bin/plutil -lint \"$remote\"" >/dev/null 2>&1 && return 0
        return 1
    fi
    if ssh_run "test -x /usr/bin/plutil" >/dev/null 2>&1; then
        ssh_run "/usr/bin/plutil -lint \"$remote\"" >/dev/null 2>&1 && return 0
        return 1
    fi
    # ramdisk 里没有 plutil：退回头部判断（bplist00 / XML）
    ssh_run "head -c 8 \"$remote\" | /usr/bin/grep -q bplist00" >/dev/null 2>&1 && return 0
    ssh_run "head -c 64 \"$remote\" | /usr/bin/grep -q '<?xml'" >/dev/null 2>&1 && return 0
    return 1
}

# ---------- 字节补丁（设备端）----------
ov_bytes_patch() {   # remote offset before after label
    local remote="$1" off="$2" before="$3" after="$4" label="$5" len cur
    len=$(( ${#before} / 2 ))
    cur="$(read_hex "$remote" "$off" "$len")"
    if [ "$cur" = "$after" ]; then
        log "  已应用，跳过: ${label}+$off"
        return 0
    fi
    [ "$cur" = "$before" ] ||
        die "bytes-patch before 不匹配: ${label}+${off}（实际 ${cur:-读取失败}）"
    write_hex "$remote" "$off" "$after"
    cur="$(read_hex "$remote" "$off" "$(( ${#after} / 2 ))")"
    [ "$cur" = "$after" ] || die "bytes-patch 回读失败: ${label}+$off"
}

# ---------- 单个条目 ----------
ov_item() {   # source dest op mode uid gid offset before after checks
    local source="$1" dest="$2" op="$3" mode="$4" uid="$5" gid="$6"
    local offset="$7" before="$8" after="$9" checks="${10}"
    local remote kind path src st m u g
    remote="$OV_MNT/$dest"
    ov_split_source "$source"
    kind="$OV_KIND"
    path="$OV_PATH"

    case "$op" in
        delete)
            log "  delete: /$dest"
            rsh "rm -rf \"$remote\""
            ov_check "$remote" "$checks" "$dest"
            return 0
            ;;
        bytes-patch)
            log "  bytes-patch: /$dest+$offset"
            ov_bytes_patch "$remote" "$offset" "$before" "$after" "$dest"
            ov_check "$remote" "$checks" "$dest"
            return 0
            ;;
        # patch = 部署已重签的二进制补丁产物，部署方式同 copy
        copy|copy-if-missing|patch) ;;
        *) die "overlay op 无效: ${op}（${dest}）" ;;
    esac

    if [ "$op" = "copy-if-missing" ] && ssh_run "test -e \"$remote\"" >/dev/null 2>&1; then
        log "  已存在，跳过: /$dest"
        return 0
    fi

    if [ "$kind" = "device_s1" ]; then
        verify_device_system
        mount_vol "$T_MNT_SYSTEM12" /mnt1 ro
        log "  $op: $source → /$dest"
        case "$op" in
            copy)
                rsh "src=\"/mnt1/$path\"; dst=\"$remote\"; test -e \"\$src\";
                    if [ -d \"\$src\" ]; then mkdir -p \"\$dst\"; /bin/cp -a \"\$src/.\" \"\$dst/\";
                    else mkdir -p \"\${dst%/*}\"; /bin/cp -p \"\$src\" \"\$dst\"; fi"
                ;;
            copy-if-missing)
                rsh "src=\"/mnt1/$path\"; dst=\"$remote\"; test -e \"\$src\";
                    if [ -d \"\$src\" ]; then mkdir -p \"\$dst\"; /bin/cp -an \"\$src/.\" \"\$dst/\";
                    elif [ ! -e \"\$dst\" ]; then mkdir -p \"\${dst%/*}\"; /bin/cp -p \"\$src\" \"\$dst\"; fi"
                ;;
        esac
        [ -n "$mode" ] && rsh "chmod $mode \"$remote\""
        if [ -n "$uid" ] || [ -n "$gid" ]; then
            rsh "/usr/sbin/chown ${uid:-0}:${gid:-0} \"$remote\""
        fi
        ov_check "$remote" "$checks" "$dest"
        return 0
    fi

    case "$kind" in
        ipsw)   src="$(donor_mount "$OV_PROFILE")/$path" ;;
        derive) src="$(derive_artifact "$path")" ;;
        patch)  src="$(blob_build "$path")" ;;
        *)      die "$source 不能执行 $op" ;;
    esac
    [ -e "$src" ] || die "overlay 来源不存在: $src"
    log "  $op: $source → /$dest"
    deploy_path "$src" "$remote"

    # 权限与属主：显式声明优先，否则沿用源文件（与 Python 版一致）
    st="$(/usr/bin/stat -f '%Lp %u %g' "$src")"
    m="$(printf '%s' "$st" | awk '{print $1}')"
    u="$(printf '%s' "$st" | awk '{print $2}')"
    g="$(printf '%s' "$st" | awk '{print $3}')"
    rsh "chmod ${mode:-$m} \"$remote\""
    rsh "/usr/sbin/chown ${uid:-$u}:${gid:-$g} \"$remote\""
    ov_check "$remote" "$checks" "$dest"
}

# 逐行应用清单文件（10 列 TSV）
ov_apply_items_file() {   # file
    local file="$1" source dest op mode uid gid offset before after checks
    [ -f "$file" ] || die "缺少 overlay 清单: $file"
    # 两个坑：
    #  1) fd 3 读清单：循环体里的 ssh 会继承 stdin；
    #  2) IFS 不能用 tab：tab 属于 IFS 空白，read 会把连续的 tab 合并、丢掉空字段
    #     （fairplayd 的 checks=plist=1 曾因此落到 mode 里）。这里把 tab 换成 0x02 再读。
    while IFS=$'\002' read -r -u 3 source dest op mode uid gid offset before after checks; do
        [ -n "$source" ] || continue
        ov_item "$source" "$dest" "$op" "$mode" "$uid" "$gid" "$offset" "$before" "$after" "$checks"
    done 3< <(tr '\t' '\002' <"$file")
}

# ---------- 按 donor 实况展开 UI 资源（@3x 缺省，4.7" 落 @2x）----------
ov_ui_items() {   # donor listfile → 条目（stdout）
    local donor="$1" list="$2" path cand seen="" base
    [ -f "$list" ] || die "缺少路径表: $list"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        cand=""
        case "$path" in
            *@3x*)
                base="${path//@3x/@2x}"
                if [ -e "$donor/$path" ]; then
                    cand="$path"
                elif [ -e "$donor/$base" ]; then
                    cand="$base"
                fi
                ;;
            *)
                [ -e "$donor/$path" ] && cand="$path"
                ;;
        esac
        if [ -z "$cand" ]; then
            warn "  跳过（donor 无此分辨率）: ${path##*/}"
            continue
        fi
        case " $seen " in *" $cand "*) continue ;; esac   # @2x/@3x 可能落到同一文件
        seen="$seen $cand"
        printf 'ipsw:ui:%s\t%s\tcopy\t\t\t\t\t\t\t\n' "$cand" "$cand"
    done <"$list"
}

# ---------- 机型文件（N56 / N61）----------
ov_model_items() {   # tag → 条目（stdout）
    local tag="$1" path
    for path in \
        "System/Library/LaunchDaemons/com.apple.jetsamproperties.$tag.plist" \
        "usr/share/firmware/multitouch/$tag.mtprops" \
        "Library/Audio/Tunings/$tag" \
        "System/Library/Frameworks/MediaToolbox.framework/$tag" \
        "System/Library/PrivateFrameworks/ACTFramework.framework/$tag" \
        "System/Library/ProductDocuments/RegulatoryImages"; do
        printf 'device_s1:%s\t%s\tcopy-if-missing\t\t\t\t\t\t\t\n' "$path" "$path"
    done
    printf 'device_s1:System/Library/Watchdog/ThermalMonitor.bundle/%sAP.bundle/Info.plist\tSystem/Library/ThermalMonitor/%sAP-Info.plist\tcopy-if-missing\t644\t0\t0\t\t\t\texists=1,nonzero=1,plist=1\n' \
        "$tag" "$tag"
}

# ---------- 判断 Mach-O ----------
ov_is_macho() {   # file
    local magic
    magic="$(od -An -v -tx1 -N 4 "$1" 2>/dev/null | tr -d ' \n')"
    case "$magic" in
        cffaedfe|feedfacf|cafebabe|bebafeca) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- 设置资源 / 二进制 / 启动 UI / App 图标（对应 impl/rootfs/phone_ui.py）----------
# 差异判定交给系统 rsync -rcn（校验和比较，一次进程扫完整棵树）：
# 逐个文件 cmp 在 PreferenceBundles 这种上万文件的树上要跑几十分钟，不可用。
# rsync 输出的就是要传输的文件（= 与 j96 不同的文件），再只对这批文件判 Mach-O。
ov_rsync_diffs() {   # donor_sub j96_sub  → 相对路径（stdout）
    local donor="$1" j96="$2" line
    /usr/bin/rsync -rcn --out-format='%n' --exclude='_CodeSignature' \
        "$donor/" "$j96/" 2>/dev/null |
        while IFS= read -r line; do
            case "$line" in
                ""|*/|"created directory "*|skipping*) continue ;;
                *) printf '%s\n' "$line" ;;
            esac
        done
}

ov_phone_ui_scan() {   # donor j96 resout binout
    local donor="$1" j96="$2" res="$3" bin="$4"
    local dir scopes scope root rel
    dir="$WK/phone-ui"
    mkdir -p "$dir"
    : >"$res"; : >"$bin"

    {
        printf '%s\n' "Applications/Preferences.app"
        printf '%s\n' "System/Library/PreferenceBundles"
        printf '%s\n' "System/Library/PrivateFrameworks/Settings"
        printf '%s\n' "System/Library/ProductDocuments/Notices"
        for root in "$donor"/System/Library/PrivateFrameworks/*Settings*.framework \
                    "$donor"/System/Library/PrivateFrameworks/*Preferences*.framework; do
            [ -d "$root" ] || continue
            printf 'System/Library/PrivateFrameworks/%s\n' "$(basename "$root")"
        done
    } | LC_ALL=C sort -u >"$dir/scopes.txt"

    : >"$dir/diffs.txt"
    while IFS= read -r scope; do
        root="$donor/$scope"
        [ -d "$root" ] || continue
        ov_rsync_diffs "$root" "$j96/$scope" |
            while IFS= read -r rel; do
                printf '%s/%s\n' "$scope" "$rel"
            done >>"$dir/diffs.txt"
    done <"$dir/scopes.txt"

    while IFS= read -r rel; do
        [ -f "$donor/$rel" ] || continue
        if ov_is_macho "$donor/$rel"; then
            printf '%s\n' "$rel" >>"$bin"
        else
            printf '%s\n' "$rel" >>"$res"
        fi
    done <"$dir/diffs.txt"
}

ov_boot_ui_scan() {   # donor j96 out
    local donor="$1" j96="$2" out="$3" root rel
    root="System/Library/PrivateFrameworks/ProgressUI.framework"
    mkdir -p "$(dirname "$out")"
    : >"$out"
    [ -d "$donor/$root" ] || return 0
    ov_rsync_diffs "$donor/$root" "$j96/$root" |
        while IFS= read -r rel; do
            [ -f "$donor/$root/$rel" ] || continue
            ov_is_macho "$donor/$root/$rel" && continue
            printf '%s\n' "$rel"
        done | sed "s#^#$root/#" >>"$out"
}

# 通用：某棵树下的图标资源（Assets.car / AppIcon* / *Icon*@3x），只取两边都存在的 app
ov_icon_scan_root() {   # donor j96 root out
    local donor="$1" j96="$2" root="$3" out="$4" rel app bn ok
    mkdir -p "$(dirname "$out")"
    : >"$out"
    [ -d "$donor/$root" ] || return 0
    ov_rsync_diffs "$donor/$root" "$j96/$root" |
    while IFS= read -r rel; do
        app="${rel%%/*}"
        [ -d "$j96/$root/$app" ] || continue
        bn="${rel##*/}"
        ok=0
        case "$bn" in
            AppIcon*|"Assets.car") ok=1 ;;
            *Icon*) case "$bn" in *@3x*) ok=1 ;; esac ;;
        esac
        [ "$ok" -eq 1 ] || continue
        printf '%s/%s\n' "$root" "$rel"
    done >>"$out"
}

ov_app_icon_scan() {   # donor j96 out
    local donor="$1" j96="$2" out="$3" rel app bn ok
    mkdir -p "$(dirname "$out")"
    : >"$out"
    ov_rsync_diffs "$donor/Applications" "$j96/Applications" |
        while IFS= read -r rel; do
            app="${rel%%/*}"
            [ -n "$app" ] && [ "$app" != "$rel" ] || continue
            [ -d "$j96/Applications/$app" ] || continue
            bn="${rel##*/}"
            ok=0
            case "$bn" in
                AppIcon*|"Assets.car") ok=1 ;;
                *Icon*)
                    case "$bn" in *@3x*) ok=1 ;; esac ;;
            esac
            [ "$ok" -eq 1 ] || continue
            printf 'Applications/%s\n' "$rel"
        done >>"$out"
}

# ---------- derive 产物 ----------
derive_artifact() {   # name → 本地路径
    case "$1" in
        im4m)      im4m_path ;;
        mrm-plist) build_mrm; printf '%s\n' "$WK/mrm/mrm.plist" ;;
        mrm-sig)   build_mrm; printf '%s\n' "$WK/mrm/mrm.plist.sig" ;;
        *) die "未实现的 derive: $1" ;;
    esac
}

# ---------- 二进制补丁产物（patches/blobs.tsv + patches/blobs/<id>.conf）----------
blob_build() {   # id → 本地输出路径
    local id="$1" dir out row src kind sign ssize ssha osize osha
    local off before after cur esc i
    row="$(awk -F'\t' -v id="$id" '$1==id{print; exit}' "$REPO/patches/blobs.tsv")"
    [ -n "$row" ] || die "未知二进制补丁: ${id}（patches/blobs.tsv）"
    src="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
    kind="$(printf '%s' "$row" | awk -F'\t' '{print $3}')"
    sign="$(printf '%s' "$row" | awk -F'\t' '{print $4}')"
    ssize="$(printf '%s' "$row" | awk -F'\t' '{print $5}')"
    ssha="$(printf '%s' "$row" | awk -F'\t' '{print $6}')"
    osize="$(printf '%s' "$row" | awk -F'\t' '{print $7}')"
    osha="$(printf '%s' "$row" | awk -F'\t' '{print $8}')"

    dir="$WK/blobs/$id"
    out="$dir/$(basename "$src")"
    mkdir -p "$dir"

    case "$kind" in
        j96)
            cp "$(donor_mount j96)/$src" "$out"
            ;;
        device_s1)
            verify_device_system
            mount_vol "$T_MNT_SYSTEM12" /mnt1 ro
            pull_file "/mnt1/$src" "$out"
            ;;
        *) die "未知二进制补丁来源类型: ${kind}（${id}）" ;;
    esac
    [ -f "$out" ] || die "二进制补丁源缺失: $src"

    if [ -n "$ssize" ] && [ "$(/usr/bin/stat -f %z "$out")" != "$ssize" ]; then
        die "$id: 源文件大小 $(/usr/bin/stat -f %z "$out") ≠ $ssize"
    fi
    if [ -n "$ssha" ]; then
        [ "$(shasum -a 256 "$out" | awk '{print $1}')" = "$ssha" ] ||
            die "$id: 源文件 sha256 不匹配（版本不对）"
    fi

    while IFS="$(printf '\t')" read -r off before after; do
        [ -n "$off" ] || continue
        off=$(( off ))
        cur="$(dd if="$out" bs=1 skip="$off" count=$(( ${#before} / 2 )) 2>/dev/null |
            od -An -v -tx1 | tr -d ' \n')"
        [ "$cur" = "$before" ] || die "$id: before 不匹配 0x$(printf '%x' "$off")（实际 ${cur}）"
        esc=""
        i=0
        while [ "$i" -lt "${#after}" ]; do
            esc="$esc\\x${after:$i:2}"
            i=$(( i + 2 ))
        done
        printf '%b' "$esc" | dd of="$out" bs=1 seek="$off" conv=notrunc 2>/dev/null
    done <"$REPO/patches/blobs/$id.conf"

    if [ -n "$osize" ] && [ "$(/usr/bin/stat -f %z "$out")" != "$osize" ]; then
        die "$id: 生成结果大小 $(/usr/bin/stat -f %z "$out") ≠ $osize"
    fi
    if [ -n "$osha" ]; then
        [ "$(shasum -a 256 "$out" | awk '{print $1}')" = "$osha" ] ||
            die "$id: 生成结果 sha256 不匹配"
    fi
    if [ "$sign" = "1" ]; then
        codesign -s - -f --preserve-metadata=identifier,entitlements,requirements,flags \
            "$out" >/dev/null 2>&1 || die "$id: 重签名失败"
        codesign --verify --strict "$out" >/dev/null 2>&1 || die "$id: 签名校验失败"
    fi
    chmod 755 "$out"
    printf '%s\n' "$out"
}

# ---------- 各 overlay 的入口 ----------
ov_apply() {   # id
    local id="$1" tmp donor
    case "$id" in
        rootfs.ui_resources|rootfs.settings_icons)
            donor="$(donor_mount "$T_UI_DONOR")"
            tmp="$WK/overlay/$id.items"
            mkdir -p "$WK/overlay"
            ov_ui_items "$donor" "$REPO/patches/lists/$id.paths" >"$tmp"
            ov_apply_items_file "$tmp"
            ;;
        rootfs.n56_model_files)
            tmp="$WK/overlay/$id.items"
            mkdir -p "$WK/overlay"
            ov_model_items "$(printf '%s' "$T_MODEL" | tr 'a-z' 'A-Z' | sed 's/AP$//')" >"$tmp"
            ov_apply_items_file "$tmp"
            ;;
        rootfs.b1_firmware)
            local f
            verify_device_system
            mount_vol "$T_MNT_SYSTEM12" /mnt1 ro
            for f in $T_WIFI_FILES; do
                rsh "test -s \"/mnt1/$T_WIFI_SRCDIR/$f\""
            done
            ov_item "device_s1:$T_WIFI_SRCDIR" "$T_WIFI_SRCDIR" copy "" "" "" "" "" "" ""
            ;;
        rootfs.phone_ui_apps)
            ov_apply_phone_ui
            ;;
        rootfs.checkra1n_bootstrap)
            checkra1n_bootstrap
            ;;
        rootfs.cydia)
            cydia_install
            ;;
        rootfs.health)
            health_apply
            ;;
        *)
            ov_apply_items_file "$REPO/patches/overlays/$id.conf"
            ;;
    esac
}

ov_apply_phone_ui() {
    local donor j96 app dirs res bin boot icons rel
    donor="$(donor_mount "$T_UI_DONOR")"
    j96="$(donor_mount j96)"
    mount_vol "$T_MNT_SYSTEM_B" "$OV_MNT"

    for app in Health.app MobilePhone.app Passbook.app; do
        [ -d "$donor/Applications/$app" ] ||
            die "$T_UI_DONOR 17H35 缺少 $app"
        log "  部署 $app"
        deploy_path "$donor/Applications/$app" "$OV_MNT/Applications/$app"
    done

    res="$WK/phone-ui/settings-res.txt"
    bin="$WK/phone-ui/settings-bin.txt"
    ov_phone_ui_scan "$donor" "$j96" "$res" "$bin"
    log "  部署 $(wc -l <"$res" | tr -d ' ') 份 iPhone 设置资源"
    deploy_relative_paths "$donor" "$OV_MNT" "$res"
    log "  部署 $(wc -l <"$bin" | tr -d ' ') 个 $T_UI_DONOR 设置 bundle 二进制"
    deploy_relative_paths "$donor" "$OV_MNT" "$bin"

    boot="$WK/phone-ui/boot-ui.txt"
    ov_boot_ui_scan "$donor" "$j96" "$boot"
    log "  部署 $(wc -l <"$boot" | tr -d ' ') 份 iPhone 启动 UI 资源"
    deploy_relative_paths "$donor" "$OV_MNT" "$boot"

    icons="$WK/phone-ui/icons.txt"
    ov_app_icon_scan "$donor" "$j96" "$icons"
    log "  覆盖 $(wc -l <"$icons" | tr -d ' ') 份 iPhone App 图标资源"
    deploy_relative_paths "$donor" "$OV_MNT" "$icons"

    for rel in "Library/Wallpaper/Live/iPhone" \
               "Library/Wallpaper/Stills/iPhone" \
               "Library/Wallpaper/Wallpapers~iphone.plist"; do
        [ -e "$donor/$rel" ] || die "$T_UI_DONOR 17H35 缺少 $rel"
        deploy_path "$donor/$rel" "$OV_MNT/$rel"
    done

    # iOS13 的 Mail/Maps/Notes 等系统 App 在 private/var/staged_system_apps，
    # j96(iPad) 的 Assets.car 只有 pad idiom，iPhone 会显示白色占位图标。
    # 这里补 n71 的图标资源（二进制与 j96 相同，只换资源）。
    local staged="$WK/phone-ui/staged-icons.txt"
    ov_icon_scan_root "$donor" "$j96" "private/var/staged_system_apps" "$staged"
    if [ -s "$staged" ]; then
        if [ -d "$OV_MNT/private/var/staged_system_apps" ]; then
            log "  覆盖 $(wc -l <"$staged" | tr -d ' ') 份 staged App 图标…"
            deploy_relative_paths "$donor" "$OV_MNT" "$staged"
        else
            warn "目标 rootfs 没有 private/var/staged_system_apps，跳过 staged 图标"
        fi
    fi

    rsh "rm -f $OV_MNT/usr/libexec/n56-register-apps \
        $OV_MNT/usr/libexec/n56-app-identifiers.plist \
        $OV_MNT/System/Library/LaunchDaemons/com.n56.phone-apps.register.plist \
        $OV_MNT/System/Library/LaunchDaemons/com.n56.phone-apps.frameworks.plist"
}
