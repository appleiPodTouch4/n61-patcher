# shellcheck shell=bash
# Mach-O / kernelcache 结构解析（bash 里用十六进制字符串做 64 位运算）。
#
# 约定：虚拟地址一律用 16 位小写十六进制字符串表示（不要转成 $(( )) 里的整数，
# 0xfffffff0xxxx 这类值超过 2^63 会变成负数）。宽度相同，字典序即数值序。
# 文件偏移用十进制。

# ---------- Mach-O 头 / 段表 ----------
KC_SEG_NAME=()
KC_SEG_VM=()
KC_SEG_VS=()
KC_SEG_FO=()
KC_SEG_FS=()

kc_magic() {   # file → 头 4 字节（小端 hex 串，64 位 Mach-O 为 cffaedfe）
    bin_hex "$1" 0 4
}

kc_segments() {   # file → 填充 KC_SEG_* 数组
    local file="$1" hdr area ncmds scmds p=0 i=0 cmd len off name vm vs fo fs
    hdr="$(bin_hex "$file" 0 32)"
    [ "${hdr:0:8}" = "cffaedfe" ] || die "不是 64 位 Mach-O: $file"
    ncmds="$(hx_u32 "$hdr" 16)"
    scmds="$(hx_u32 "$hdr" 20)"
    area="$(bin_hex "$file" 32 "$scmds")"
    KC_SEG_NAME=(); KC_SEG_VM=(); KC_SEG_VS=(); KC_SEG_FO=(); KC_SEG_FS=()
    while [ "$i" -lt "$ncmds" ]; do
        cmd="$(hx_u32 "$area" "$p")"
        len="$(hx_u32 "$area" "$(( p + 4 ))")"
        [ "$len" -ge 8 ] || die "load command 长度非法（${file}）"
        if [ "$cmd" -eq 25 ]; then                       # LC_SEGMENT_64
            off="$(( p * 2 + 16 ))"                      # 段名 16 字节
            name="$(hex2ascii "${area:$off:32}")"
            vm="$(hx_u64 "$area" "$(( p + 24 ))")"
            vs="$(hx_u64 "$area" "$(( p + 32 ))")"
            fo="$(hx_u32 "$area" "$(( p + 40 ))")"
            fs="$(hx_u64 "$area" "$(( p + 48 ))")"
            KC_SEG_NAME+=("$name"); KC_SEG_VM+=("$vm"); KC_SEG_VS+=("$vs")
            KC_SEG_FO+=("$fo");     KC_SEG_FS+=("$fs")
        fi
        p=$(( p + len ))
        i=$(( i + 1 ))
    done
}

kc_seg_index() {   # file name → 下标（无则空）
    local file="$1" want="$2" i=0
    kc_segments "$file"
    while [ "$i" -lt "${#KC_SEG_NAME[@]}" ]; do
        if [ "${KC_SEG_NAME[$i]}" = "$want" ]; then printf '%s\n' "$i"; return 0; fi
        i=$(( i + 1 ))
    done
    return 1
}

# 虚拟地址 → 文件偏移。只认文件承载的部分（vm .. vm+filesize）。
kc_va2off() {   # file va_hex [size] → 十进制偏移
    local file="$1" va="$2" size="${3:-1}" i=0 end delta
    kc_segments "$file"
    while [ "$i" -lt "${#KC_SEG_NAME[@]}" ]; do
        end="$(hex16_add "${KC_SEG_VM[$i]}" "$(hex2dec "${KC_SEG_FS[$i]}")")"
        if hex16_le "${KC_SEG_VM[$i]}" "$va" && hex16_le "$(hex16_add "$va" "$size")" "$end"; then
            delta="$(hex16_sub "$va" "${KC_SEG_VM[$i]}")"
            # 段内偏移 < 4GB，取低 32 位即可（避免 2^63 溢出）
            printf '%d\n' $(( ${KC_SEG_FO[$i]} + 0x${delta:8:8} ))
            return 0
        fi
        i=$(( i + 1 ))
    done
    die "地址不在文件承载区: 0x$va (+$size)"
}

kc_read() {   # file va_hex size → 十六进制
    bin_hex "$1" "$(kc_va2off "$1" "$2" "$3")" "$3"
}

# ---------- 符号 ----------
# nm -n 的输出：地址 类型 符号名。地址要按虚拟地址用。
kc_symbols() {   # file → 每行 "16位hex 名字"
    nm -n "$1" 2>/dev/null | awk 'NF>=3 && $1 ~ /^[0-9a-fA-F]+$/ {
        a=tolower($1); while (length(a)<16) a="0" a; print a" "$3 }'
}

# 文件偏移 → 虚拟地址（16 位 hex）。跨 2^63 的值只能用 perl 算，bash 算术会溢出。
kc_va_at() {   # file foff → hex16
    local file="$1" foff="$2" i=0
    kc_segments "$file"
    while [ "$i" -lt "${#KC_SEG_NAME[@]}" ]; do
        if [ "$foff" -ge "${KC_SEG_FO[$i]}" ] &&
           [ "$foff" -lt "$(( ${KC_SEG_FO[$i]} + $(hex2dec "${KC_SEG_FS[$i]}") ))" ]; then
            "$PERL" -e 'printf "%016x", (hex($ARGV[0]) + $ARGV[1]) & 0xFFFFFFFFFFFFFFFF' \
                "${KC_SEG_VM[$i]}" "$(( foff - ${KC_SEG_FO[$i]} ))"
            return 0
        fi
        i=$(( i + 1 ))
    done
    die "文件偏移 0x$(printf '%x' "$foff") 不在任何段内"
}

# 段表导出成 "vm十六进制 fo fs" 三列，给 lib/*.pl 里的地址映射用。
kc_segmap() {   # file out
    local i=0
    kc_segments "$1"
    : >"$2"
    while [ "$i" -lt "${#KC_SEG_NAME[@]}" ]; do
        printf '%s %s %s\n' "${KC_SEG_VM[$i]}" "${KC_SEG_FO[$i]}" \
            "$(hex2dec "${KC_SEG_FS[$i]}")" >>"$2"
        i=$(( i + 1 ))
    done
}

# 虚拟地址 → 文件偏移（十进制）。只在「同一虚拟地址高 32 位」的段内做低位减法，
# 避免 bash 有符号 64 位溢出。
kc_off_at() {   # file va_hex → 文件偏移
    local file="$1" va="$2" i=0 vm fs end
    kc_segments "$file"
    while [ "$i" -lt "${#KC_SEG_NAME[@]}" ]; do
        vm="${KC_SEG_VM[$i]}"; fs="$(hex2dec "${KC_SEG_FS[$i]}")"
        end="$(hex16_add "$vm" "$fs")"
        if hex16_le "$vm" "$va" && hex16_le "$va" "$end"; then
            printf '%d\n' $(( ${KC_SEG_FO[$i]} + 0x${va:8:8} - 0x${vm:8:8} ))
            return 0
        fi
        i=$(( i + 1 ))
    done
    die "地址 0x${va} 不在文件承载区（${file}）"
}
