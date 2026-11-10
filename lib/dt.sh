# shellcheck shell=bash
# DeviceTree（dt.base，对应 patches/dt/base.py 与 patches/impl/dt/dt_patch.py）。
#
# dt.base 是「本机 12.5.8 设备树 → 目标板 iOS13 设备树」的一整套 JSON 手术：移植
# filesystems/osenvironments 节点、重编号 phandle、补 /chosen 的 14 个 iOS13 属性、
# 生成 /filesystems/fstab 等。这部分留在 Python 版，产物（JSONC）作为版本锁定资产
# 放在 patches/dtdata/，运行期由仓库自带的 devicetree-repack 打回二进制：
#
#   patches/dtdata/DeviceTree.<board>_native.jsonc   ← 资产（与 Python 版逐字节一致）
#   devicetree-repack → .bin → img4 -A -T rdtr → boot_DT.img4
#
# 两道闸门：输入 JSONC 的 sha256 必须与导出时一致（输入变了资产就过期）；
# 打完包的 .bin 的 sha256 / 大小必须与导出时一致。

DTD="${REPO}/patches/dtdata"

dt_board() { printf '%s\n' "${T_MODEL:-n61ap}"; }

dt_meta() {   # key → value
    awk -F'=' -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$DTD/$(dt_board).meta"
}

# 打回二进制并校验 → 设 DT_BIN
# （用全局而不是 echo：函数里的 die 在 $( ) 里只会杀掉子 shell，错误会被吞掉）
dt_build_bin() {
    local board meta jsonc in12 in66
    board="$(dt_board)"
    meta="$DTD/$board.meta"
    [ -f "$meta" ] || die "缺少 ${meta}（先跑 python3 tools/export_dtdata.py）"
    jsonc="$DTD/$(dt_meta jsonc)"
    DT_BIN="$WK/DeviceTree.${board}_native.bin"
    [ -f "$jsonc" ] || die "缺少设备树资产: $jsonc"

    in12="$REPO/ipsw/cache/derived/extracted/${board}_ios12/DeviceTree.${board}.jsonc"
    in66="$REPO/ipsw/cache/derived/extracted/n66ap_ios13/DeviceTree.n66ap.jsonc"
    [ -f "$in12" ] || die "缺少本机 12.5.8 设备树: ${in12}（先跑 Python 版派生步骤）"
    [ -f "$in66" ] || die "缺少 N66 13.7 设备树: $in66"
    [ "$(kc_sha "$in12")" = "$(dt_meta in_dt12_sha)" ] ||
        die "设备树资产过期：本机 12.5.8 设备树与导出时不同（重跑 tools/export_dtdata.py）"
    [ "$(kc_sha "$in66")" = "$(dt_meta in_n66_sha)" ] ||
        die "设备树资产过期：N66 13.7 设备树与导出时不同（重跑 tools/export_dtdata.py）"

    "$REPO/tools/devicetree-parse/devicetree-repack" "$jsonc" "$DT_BIN" >/dev/null ||
        die "devicetree-repack 失败"
    [ "$(bin_len "$DT_BIN")" = "$(dt_meta out_bin_size)" ] &&
        [ "$(kc_sha "$DT_BIN")" = "$(dt_meta out_bin_sha)" ] ||
        die "设备树打包结果与导出资产不一致（devicetree-repack 版本不符？）"
}

build_dt() {   # out [list]
    local out="$1" list="${2:-}" transform im4m
    if [ -n "$list" ] && [ -f "$list" ]; then
        transform="$(awk -F'\t' '$1 == "dt" && $2 == "transform" { print $3; exit }' "$list")"
        [ -z "$transform" ] ||
            die "bash 版未实现 dt transform: ${transform}（DT 只支持版本锁定资产；请调整 --features/--patches，或用 Python 版构建）"
        awk -F'\t' '$1 == "dt" && $2 == "base"' "$list" | grep -q . ||
            die "未选中 dt base（清单 bases['dt']）"
    fi
    dt_build_bin
    im4m="$(im4m_path)" || die "缺少 IM4M（先跑 ./n61.sh extract-im4m）"
    "$(tool img4)" -i "$DT_BIN" -A -T rdtr -M "$im4m" -o "$out" >/dev/null ||
        die "DeviceTree 签名失败"
    log "  DeviceTree: $(bin_len "$out") 字节"
}
