# shellcheck shell=bash
# 内核缓存（kernelcache）补丁链，对应 patches/impl/kc/ 下的 Python 实现。
#
# 每个变换都读 in、改一份副本、写 out；验收标准是与 Python 版产物逐字节相同
# （拿 build/<golden>/ 的中间产物对拍）。
# 地址表 / 字节表等静态数据在 patches/kcdata/，由 tools/export_registry.py 导出。

KCD="${REPO}/patches/kcdata"

# ---------- 静态改写表（kext 搬迁类阶段）----------
# patches/kcdata/<stage>.{meta,writes.tsv,dict,plist.gz} 由 tools/export_kcdata.py
# 从 Python 版的黄金产物导出：writes.tsv 是 plist 段之外的逐字节改写，
# plist 段则按 meta 的 plist_mode 由 kcplist.pl 复现（surgery / blob）。
# 每个阶段都带输入/输出 sha256，跑完自校验，对不上立即停。

kc_meta() {   # metafile key → value
    awk -F'=' -v k="$2" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

kc_seg_get() {   # file name → 设 KC_ONE_VM / KC_ONE_FO / KC_ONE_FS
    local file="$1" want="$2" i=0
    kc_segments "$file"
    while [ "$i" -lt "${#KC_SEG_NAME[@]}" ]; do
        if [ "${KC_SEG_NAME[$i]}" = "$want" ]; then
            KC_ONE_VM="0x${KC_SEG_VM[$i]}"; KC_ONE_FO="${KC_SEG_FO[$i]}"
            KC_ONE_FS="$(hex2dec "${KC_SEG_FS[$i]}")"
            return 0
        fi
        i=$(( i + 1 ))
    done
    die "找不到段 $want: $file"
}

kc_apply_writes() {   # file tsv
    [ -f "$2" ] || die "缺少改写表: $2"
    "$PERL" -e '
        open my $f, "+<:raw", $ARGV[0] or die "$ARGV[0]: $!";
        open my $t, "<", $ARGV[1] or die "$ARGV[1]: $!";
        my $n = 0;
        while (<$t>) {
            chomp;
            next unless /\t/;
            my ($o, $h) = split /\t/;
            seek $f, hex($o), 0 or die "seek: $!";
            print $f pack("H*", $h) or die "write: $!";
            $n++;
        }
        close $f or die "close: $!";
        print "$n\n";' "$1" "$2" || die "改写失败: $2"
}

kc_sha() { shasum -a 256 "$1" | awk '{print $1}'; }

kc_apply_table() {   # stage in out
    local stage="$1" in="$2" out="$3" meta="$KCD/$1.meta" want
    [ -f "$meta" ] || die "缺少阶段数据: $meta"
    [ -f "$in" ] || die "输入不存在: $in"
    want="$(kc_meta "$meta" in_sha)"
    [ "$(kc_sha "$in")" = "$want" ] ||
        die "输入与导出数据不符（${stage}）：内核不是 13.7(17H35) 的 j96 基底，
或前面的阶段没有按顺序执行。用 python3 n56patcher.py build 重新导出可解。"
    cp "$in" "$out"
    kc_apply_writes "$out" "$KCD/$(kc_meta "$meta" writes)" >/dev/null
    kc_seg_get "$out" __PRELINK_INFO
    local fo="$KC_ONE_FO" fs="$KC_ONE_FS"
    kc_seg_get "$out" __PRELINK_TEXT
    "$PERL" "$REPO/lib/kcplist.pl" --file "$out" --seg "$fo,$fs" \
        --base "${KC_ONE_VM#0x}" --meta "$meta" >/dev/null ||
        die "plist 段改写失败: $stage"
    want="$(kc_meta "$meta" out_sha)"
    [ "$(kc_sha "$out")" = "$want" ] ||
        die "阶段产物校验失败（${stage}）：与导出的 baseline 不一致。"
    log "  $stage: 改写表已应用并校验"
}

# ---------- AArch64 指令编码 ----------
# 地址都是 16 位 hex 字符串，只取低 32 位参与运算（内核内偏移远小于 4GB）。
a64_adrp() {   # rd target_hex pc_hex
    local rd="$1" t=$(( 0x${2:8:8} & 0xfffff000 )) p=$(( 0x${3:8:8} & 0xfffff000 ))
    local pages=$(( (t - p) >> 12 ))
    [ "$pages" -lt 1048576 ] && [ "$pages" -ge -1048576 ] || die "ADRP 越界"
    printf '%08x' $(( (0x90000000 | ((pages & 3) << 29) | (((pages >> 2) & 0x7ffff) << 5) | rd) & 0xffffffff ))
}

a64_add() {   # rd rn imm
    printf '%08x' $(( (0x91000000 | (($3 & 0xfff) << 10) | ($2 << 5) | $1) & 0xffffffff ))
}

a64_ldr() {   # rt rn offset
    printf '%08x' $(( (0xf9400000 | (($3 / 8) << 10) | ($2 << 5) | $1) & 0xffffffff ))
}

a64_str() {   # rt rn offset
    printf '%08x' $(( (0xf9000000 | (($3 / 8) << 10) | ($2 << 5) | $1) & 0xffffffff ))
}

# adrp + add 合成一条「把地址放进 rd」的两指令序列
a64_addr2() {   # rd target_hex pc_hex → "adrp add"（空格分隔）
    printf '%s %s' "$(a64_adrp "$1" "$2" "$3")" "$(a64_add "$1" "$1" $(( 0x${2:12:4} )))"
}

# ---------- kerninfo ----------
KC_KI_NAME=(); KC_KI_VALUE=(); KC_KI_KIND=(); KC_KI_OFF=()

kc_kerninfo_load() {
    local tsv="$KCD/kerninfo.tsv" name val kind size=24
    [ -f "$tsv" ] || die "缺少 $tsv"
    KC_KI_NAME=(); KC_KI_VALUE=(); KC_KI_KIND=(); KC_KI_OFF=()
    while IFS="$(printf '\t')" read -r name val kind; do
        case "$name" in ""|\#*) continue ;; esac
        KC_KI_NAME+=("$name"); KC_KI_VALUE+=("$val"); KC_KI_KIND+=("$kind")
        KC_KI_OFF+=("$size")
        size=$(( size + 24 + ${#name} + 1 ))
    done <"$tsv"
    KC_KI_SIZE="$size"
    [ "${#KC_KI_NAME[@]}" -gt 0 ] || die "kerninfo 表为空"
}

kc_ki_const() {   # 常量名 → 值（hex，不带 0x）
    awk -F'\t' -v k="$1" 'index($0, "# const\t" k "=") == 1 {
        sub(/^# const\t[^=]*=/, ""); print; exit }' "$KCD/kerninfo.tsv"
}

kc_ki_u64() {   # 十六进制串（kerninfo.tsv 里都是 hex）→ 16 位 hex
    "$PERL" -e 'printf "%016x", hex($ARGV[0])' "$1"
}

kc_kerninfo_blob() {   # → blob 的 hex
    local n=${#KC_KI_NAME[@]} i off next prev val blob flag base
    flag="$(kc_ki_const UNSLID_FLAGS_KADDR)"
    base="$(hex16_add "$flag" 0x40)"          # UNSLID_BLOB_ADDR
    blob="$(hexrev "$(printf '%016x' "$KC_KI_SIZE")")"   # 表总长按十进制累加
    blob="${blob}$(hexrev "$(hex16_add "$base" "${KC_KI_OFF[0]}")")"
    blob="${blob}$(hexrev "$(hex16_add "$base" "${KC_KI_OFF[$(( n - 1 ))]}")")"
    i=0
    while [ "$i" -lt "$n" ]; do
        off="${KC_KI_OFF[$i]}"
        if [ "$i" -lt "$(( n - 1 ))" ]; then
            next="$(hexrev "$(hex16_add "$base" "${KC_KI_OFF[$(( i + 1 ))]}")")"
        else
            next="$(hex_zero 16)"
        fi
        if [ "$i" -gt 0 ]; then
            prev="$(hexrev "$(hex16_add "$base" "${KC_KI_OFF[$(( i - 1 ))]}")")"
        else
            prev="$(hexrev "$(hex16_add "$base" 8)")"
        fi
        case "${KC_KI_KIND[$i]}" in
            slide)    val="$(hex_zero 16)" ;;
            address)  val="$(hexrev "$(kc_ki_u64 "${KC_KI_VALUE[$i]}")")" ;;
            constant) val="$(hexrev "$(kc_ki_u64 "${KC_KI_VALUE[$i]}")")" ;;
            *) die "kerninfo 未知 kind: ${KC_KI_KIND[$i]}" ;;
        esac
        blob="${blob}${next}${prev}${val}$(ascii2hex "${KC_KI_NAME[$i]}")00"
        i=$(( i + 1 ))
    done
    printf '%s' "$blob"
}

kc_kerninfo_shellcode() {   # → 指令流 hex
    local words=() shell pc i n off val x out=""
    shell="$(kc_ki_const SHELLCODE_VMADDR)"
    words=(a9bd7be0 a90157f6 a9024ff4)          # 保存 x0/x30/x19-x22

    # 把 「adrp+add」 追加进 words，pc 取当前指令位置
    kc_emit_addr() {
        local rd="$1" tgt="$2" cur
        cur="$(hex16_add "$shell" $(( ${#words[@]} * 4 )))"
        words+=($(a64_addr2 "$rd" "$tgt" "$cur"))
    }

    kc_emit_addr 0 "$(kc_ki_const UNSLID_VM_KERNEL_SLIDE)"
    words+=("$(a64_ldr 19 0 0)")
    kc_emit_addr 20 "$(hex16_add "$(kc_ki_const UNSLID_FLAGS_KADDR)" 0x40)"

    n=${#KC_KI_NAME[@]}
    words+=("$(a64_add 0 20 "${KC_KI_OFF[0]}")" "$(a64_str 0 20 8)")
    words+=("$(a64_add 0 20 "${KC_KI_OFF[$(( n - 1 ))]}")" "$(a64_str 0 20 16)")

    i=0
    while [ "$i" -lt "$n" ]; do
        off="${KC_KI_OFF[$i]}"
        words+=("$(a64_add 21 20 "$off")")
        if [ "$i" -lt "$(( n - 1 ))" ]; then
            words+=("$(a64_add 0 20 "${KC_KI_OFF[$(( i + 1 ))]}")" "$(a64_str 0 21 0)")
        else
            words+=("$(a64_str 31 21 0)")
        fi
        if [ "$i" -gt 0 ]; then
            words+=("$(a64_add 0 20 "${KC_KI_OFF[$(( i - 1 ))]}")")
        else
            words+=("$(a64_add 0 20 8)")
        fi
        words+=("$(a64_str 0 21 8)")
        case "${KC_KI_KIND[$i]}" in
            slide)   words+=("$(a64_str 19 21 16)") ;;
            address) kc_emit_addr 0 "${KC_KI_VALUE[$i]}"
                     words+=("$(a64_str 0 21 16)") ;;
        esac
        i=$(( i + 1 ))
    done

    kc_emit_addr 0 "$(kc_ki_const UNSLID_KERNEL_TASK)"
    words+=("$(a64_ldr 0 0 0)")
    words+=("$(a64_str 19 0 "$(printf '%d' 0x3d0)")")
    words+=(d5033abf)                            # dmb ishst
    words+=("$(a64_str 20 0 "$(printf '%d' 0x3c8)")")
    words+=(a9424ff4 a94157f6 a8c37be0 d2800001 d65f03c0)

    unset -f kc_emit_addr
    # words 里存的是指令「数值」，落盘要按小端转字节序
    for x in "${words[@]}"; do out="$out$(hexrev "$x")"; done
    printf '%s' "$out"
}

kc_kerninfo() {   # in out
    local in="$1" out="$2" data shell branch dataf shellf hookf vmadiff
    dataf=$(( 0x$(kc_ki_const DATA_FOFF) ))
    shellf=$(( 0x$(kc_ki_const SHELLCODE_FOFF) ))
    hookf=$(( 0x$(kc_ki_const HOOK_FOFF) ))
    [ "$(bin_hex "$in" "$hookf" 4)" = "010080d2" ] ||
        die "kerninfo: BSD 初始化指令不符"
    kc_kerninfo_load
    data="$(hex_zero 64)03000000$(hex_zero 56)$(kc_kerninfo_blob)"
    shell="$(kc_kerninfo_shellcode)"
    [ $(( ${#data} / 2 )) -le $(( 0x$(kc_ki_const DATA_CAPACITY) )) ] ||
        die "kerninfo: 载荷超出预留空间"
    [ $(( ${#shell} / 2 )) -le $(( 0x6a7000 - shellf )) ] ||
        die "kerninfo: shellcode 超出预留空间"
    bin_is_zero "$in" "$dataf" $(( ${#data} / 2 )) || die "kerninfo: 数据区被占用"
    bin_is_zero "$in" "$shellf" $(( ${#shell} / 2 )) || die "kerninfo: 代码区被占用"
    cp "$in" "$out"
    bin_write "$out" "$dataf" "$data"
    bin_write "$out" "$shellf" "$shell"
    vmadiff=$(( (0x$(kc_ki_const SHELLCODE_VMADDR) & 0xffffffff) - (0x$(kc_ki_const HOOK_VMADDR) & 0xffffffff) ))
    branch="$(printf '%08x' $(( (0x94000000 | ((vmadiff / 4) & 0x3ffffff)) & 0xffffffff )))"
    bin_w32h "$out" "$hookf" "$branch"
    log "  kerninfo: 已发布 offsetcache（${#KC_KI_NAME[@]} 项）"
}

# ---------- legacy_sep ----------
kc_legacy_sep() {   # in out
    local in="$1" out="$2" va before after off n=0 tsv="$KCD/legacy-sep.tsv"
    [ -f "$tsv" ] || die "缺少 $tsv"
    cp "$in" "$out"
    while IFS="$(printf '\t')" read -r va before after; do
        [ -n "$va" ] || continue
        case "$va" in \#*) continue ;; esac
        off="$(kc_va2off "$out" "$va" "$(( ${#before} / 2 ))")"
        [ "$(bin_hex "$out" "$off" "$(( ${#before} / 2 ))")" = "$before" ] ||
            die "legacy_sep: 0x$va 处字节不符"
        bin_write "$out" "$off" "$after"
        n=$(( n + 1 ))
    done <"$tsv"
    log "  legacy_sep: $n 处"
}

# ---------- mt_n56（触摸 personality 改板）----------
kc_mt() {   # in out board
    local in="$1" out="$2" board="$3" tsv="$KCD/mt_n56.tsv"
    local b kind before after anchor endpat start end at cnt_new cnt_old
    [ -f "$tsv" ] || die "缺少 $tsv"
    while IFS="$(printf '\t')" read -r b kind before after; do
        [ "$b" = "$board" ] || continue
        case "$kind" in
            anchor) anchor="$before" ;;
            end)    endpat="$before" ;;
        esac
    done <"$tsv"
    [ -n "${anchor:-}" ] && [ -n "${endpat:-}" ] || die "mt: 缺少 anchor/end（${board}）"

    cp "$in" "$out"
    start="$(bin_find "$out" "$anchor")"
    [ -n "$start" ] || die "mt: 找不到 J96 触摸 personality"
    [ -z "$(bin_find "$out" "$anchor" "$(( start + 1 ))")" ] || die "mt: anchor 不唯一"
    end="$(bin_find "$out" "$endpat" "$start")"
    [ -n "$end" ] || die "mt: 找不到 personality 结束标记"

    while IFS="$(printf '\t')" read -r b kind before after; do
        [ "$b" = "$board" ] && [ "$kind" = "edit" ] || continue
        cnt_new="$(bin_count "$out" "$after")"
        cnt_old="$(bin_count "$out" "$before")"
        if [ "$cnt_new" = "1" ] && [ "$cnt_old" = "0" ]; then
            log "  已应用: $(hex2ascii "$after")"
            continue
        fi
        [ "$cnt_old" = "1" ] || die "mt: 模式不唯一: $(hex2ascii "$before")"
        at="$(bin_find "$out" "$before" "$start")"
        [ -n "$at" ] && [ "$at" -lt "$end" ] || die "mt: 模式不在 personality 内"
        bin_write "$out" "$at" "$after"
        log "  已修改: $(hex2ascii "$after")"
    done <"$tsv"

    while IFS="$(printf '\t')" read -r b kind before after; do
        [ "$b" = "$board" ] && [ "$kind" = "edit" ] || continue
        [ "$(bin_count "$out" "$after")" = "1" ] || die "mt: 后置校验失败"
    done <"$tsv"
}

# ---------- checkra1n KPF 与 N56 通用启动补丁合并 ----------
kc_checkra1n_merge() {   # stock generic out
    local stock="$1" generic="$2" out="$3" src="$REPO/tools/checkra1n-kpf/checkra1n/kpf-test"
    local off before after cur n=0
    local -a offs=()
    [ -d "$src" ] || die "缺少 checkra1n KPF 源码: $src"
    make -C "$src" kpf-test.macos CFLAGS=-Wno-error=unused-but-set-variable \
        >/dev/null 2>&1 || die "checkra1n KPF 编译失败"
    if [ "$(uname -m)" = "arm64" ]; then
        N56_KPF_OUTPUT="$out" N56_KPF_GENERIC="$generic" \
            "$src/kpf-test.macos" -n "$stock" >/dev/null 2>&1 || die "checkra1n KPF 执行失败"
    else
        N56_KPF_OUTPUT="$out" N56_KPF_GENERIC="$generic" N56_KPF_NOJIT=1 \
            "$src/kpf-test.macos" -n "$stock" >/dev/null 2>&1 || die "checkra1n KPF 执行失败"
    fi
    [ "$(bin_len "$stock")" = "$(bin_len "$generic")" ] &&
        [ "$(bin_len "$out")" = "$(bin_len "$stock")" ] || die "KPF 与通用 KC 布局不同"

    while read -r off before after; do
        [ -n "$off" ] || continue
        cur="$(bin_hex "$out" "$off" 4)"
        # bin_diff_words 给的是指令数值，落盘字节是小端，比较前统一转一次
        case "$cur" in
            "$(hexrev "$before")"|"$(hexrev "$after")") ;;
            *) die "KPF / N56 启动补丁冲突 @0x$(printf '%x' "$off")" ;;
        esac
        bin_w32h "$out" "$off" "$after"
        offs+=("0x$(printf '%x' "$off")")
        n=$(( n + 1 ))
    done < <(bin_diff_words "$stock" "$generic")
    # 与 Python 的 json.dumps(…, indent=2) 保持逐字节相同
    local jsonf i last
    jsonf="$(dirname "$out")/checkra1n-boot-merge.json"
    if [ "${#offs[@]}" -eq 0 ]; then
        printf '[]\n' >"$jsonf"
    else
        {
            printf '[\n'
            i=0; last=$(( ${#offs[@]} - 1 ))
            while [ "$i" -le "$last" ]; do
                if [ "$i" -lt "$last" ]; then
                    printf '  "%s",\n' "${offs[$i]}"
                else
                    printf '  "%s"\n' "${offs[$i]}"
                fi
                i=$(( i + 1 ))
            done
            printf ']\n'
        } >"$jsonf"
    fi
    log "  checkra1n 合并: $n 处"
}

# ---------- pmu_d2186：D2207 PMU 适配 N56 的 D2186 硬件 ----------
# 与 patches/impl/kc/pmu_d2186.py 等价：改 LDO 电压表、_setLDO 的档位范围/能力掩码/
# 特殊寄存器/5V 升压块、GPIO 映射与电平位、事件窗口长度，最后关掉看门狗 personality。
# 每一处都先确认「唯一命中」再改，命中数不对就停——宁可报错也不猜。

NOP="d503201f"
RAIL_OLD="71005abf"; RAIL_NEW="71004ebf"
MASK_O0="529effe8"; MASK_O1="72a00028"; MASK_N0="5282ffe8"; MASK_FOLLOW="9ad52508"
REG_OLD="52807221"; REG_NEW="52807001"
BOOST_SUB="d1003aa9"; BOOST_CMP="f100093f"
GL_OLD="528003a9 0a090108 39003fe8 71000aff"; GL_NEW0="528000a9"
GL_REST="0a090108 39003fe8 71000aff"
MODE2_OLD="321a0108"; MODE2_NEW="321c0108"; MODE2_OFF=52
M1_70="52800e01"; W3_14="528001c3"; W2_14="528001c2"
W3_13="528001a3"; W2_13="528001a2"; BLRX8="d63f0100"
GPIO_D2207="529fffe8 7100443f 32160029 0b01042a 110f814a 1a8a3129 7100503f 1a898100 d65f03c0"
GPIO_D2186="321603e8 331f1c28 7100503f 5a9f9108 12003d00 d65f03c0"

kc_pmu_ldo() { awk -F'\t' -v k="$2" '$1==k { print $2; exit }' "$KCD/pmu_ldo.tsv"; }

kc_whex() {   # 字（8 位十六进制）… → 小端字节串
    local o="" w
    for w in "$@"; do o="$o$(printf '%s' "$w" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')"; done
    printf '%s' "$o"
}

kc_hx_hits() {   # hexblob pattern [步长字节] → 空格分隔的偏移
    local blob="$1" pat="$2" step="${3:-4}" i=0 out="" n=${#1} pl=${#2}
    while [ "$i" -le $(( n - pl )) ]; do
        [ "${blob:$i:$pl}" = "$pat" ] && out="$out $(( i / 2 ))"
        i=$(( i + step * 2 ))
    done
    printf '%s' "$out"
}

# _setLDO 的锚点：唯一一条「adrp Xn,<LDO 表所在页> + add Xn,Xn,#<页内偏移>」。
# 只认 .py 里那两个代码段，命中数必须恰好 1。
kc_pmu_xref() {   # file table_va_hex → 文件偏移（失败 die）
    local file="$1" tva="$2" seg n
    : >"${TMPDIR:-/tmp}/n61-pmu-xref.$$"
    for seg in __PLK_TEXT_EXEC __TEXT_EXEC; do
        kc_seg_get "$file" "$seg" || continue
        "$PERL" -e '
            my ($f,$fo,$fs,$vm,$tva)=@ARGV;
            open my $h,"<:raw",$f or die "$f: $!";
            seek $h,$fo,0; read $h,my $d,$fs;
            # 地址一律取低 32 位比：内核里所有地址的高 32 位都是 0xfffffff0，
            # 而 perl 的 UV/IV 混算会退化成浮点（64 位超大值），低位运算才准。
            my $vm32=hex($vm) & 0xFFFFFFFF;
            my $hi_vm=hex($vm) >> 32;
            my $hi_t=hex($tva) >> 32;
            die "段虚拟地址高 32 位异常\n" unless $hi_vm == 0xfffffff0;
            die "LDO 表地址高 32 位与代码段不同\n" unless $hi_t == $hi_vm;
            my $t32=hex($tva) & 0xFFFFFFFF;
            my $page32=$t32 & 0xFFFFF000;
            for (my $i=0; $i+4<=length($d); $i+=4) {
                my $w=unpack("V",substr($d,$i,4));
                next unless ($w & 0x9F000000) == 0x90000000;
                my $imm=(($w>>5)&0x7FFFF)<<2 | (($w>>29)&3);
                $imm-=(1<<21) if $imm & (1<<20);
                my $pc32=($vm32 + $i) & 0xFFFFFFFF;
                next unless ((($pc32 & 0xFFFFF000) + ($imm*4096)) & 0xFFFFFFFF) == $page32;
                my $rd=$w & 0x1F;
                for (my $j=4; $j<20; $j+=4) {
                    my $w2=unpack("V",substr($d,$i+$j,4));
                    next unless ($w2 & 0x7F800000)==0x11000000 && (($w2>>5)&0x1F)==$rd;
                    my $imm12=($w2>>10)&0xFFF;
                    $imm12<<=12 if ($w2>>22)&1;
                    print $fo+$i,"\n" if (($page32+$imm12) & 0xFFFFFFFF)==$t32;
                    last;
                }
            }' "$file" "$KC_ONE_FO" "$KC_ONE_FS" "${KC_ONE_VM#0x}" "$tva" \
            >>"${TMPDIR:-/tmp}/n61-pmu-xref.$$"
    done
    n="$(wc -l <"${TMPDIR:-/tmp}/n61-pmu-xref.$$" | tr -d ' ')"
    if [ "$n" != "1" ]; then
        rm -f "${TMPDIR:-/tmp}/n61-pmu-xref.$$"
        die "pmu: LDO 表交叉引用不唯一（命中 ${n} 处），拒绝继续"
    fi
    cat "${TMPDIR:-/tmp}/n61-pmu-xref.$$"
    rm -f "${TMPDIR:-/tmp}/n61-pmu-xref.$$"
}

# 某个 personality 的 IOProviderClass 值：输出 "值<TAB>可改偏移"（不可直接改时偏移为 0）
kc_pmu_provider() {   # file marker
    "$PERL" -e '
        my ($f,$marker)=@ARGV;
        open my $h,"<:raw",$f or die "$f: $!";
        local $/; my $d=<$h>;
        my $co=index($d,"<key>IOClass</key><string>$marker</string>");
        if($co<0){ print "NONE\t0\n"; exit }
        my $k="<key>IOProviderClass</key>";
        my $po=index($d,$k,$co);
        if($po<0 || $po>=$co+512){ print "NONE\t0\n"; exit }
        my $vo=$po+length($k); my $rest=substr($d,$vo,200);
        if($rest =~ /^<string>([^<]+)<\/string>/){ print "$1\t$vo\n"; exit }
        if($rest =~ /^<string IDREF="([0-9]+)"\/>/){
            my $id=$1;
            if($d =~ /<string ID="$id">([^<]+)<\/string>/){ print "$1\t0\n"; exit }
        }
        print "NONE\t0\n";' "$1" "$2"
}

kc_pmu() {   # in out
    local in="$1" out="$2"
    local ldo2186 ldo2207 off tab rail_off cmp win ws we i hits pat cur bhi disp
    ldo2186="$(kc_pmu_ldo x d2186)"; ldo2207="$(kc_pmu_ldo x d2207)"
    [ -n "$ldo2186" ] && [ -n "$ldo2207" ] || die "缺少 pmu_ldo.tsv"
    cp "$in" "$out"

    # [1] IONameMatch pmu,d2207 → pmu,d2186
    local m_old="<key>IONameMatch</key><string>pmu,d2207</string>"
    local m_new="<key>IONameMatch</key><string>pmu,d2186</string>"
    local n_old n_new
    n_old="$(bin_count "$out" "$(ascii2hex "$m_old")")"
    n_new="$(bin_count "$out" "$(ascii2hex "$m_new")")"
    if [ "$n_old" = "0" ] && [ "$n_new" -ge 1 ]; then
        log "  [1] IONameMatch 已是 pmu,d2186"
    else
        [ "$n_old" = "1" ] || die "pmu: IONameMatch pmu,d2207 命中 $n_old 处（应为 1），拒绝继续"
        off="$(bin_find "$out" "$(ascii2hex "$m_old")")"
        bin_write "$out" "$off" "$(ascii2hex "$m_new")"
        log "  [1] IONameMatch pmu,d2207 → pmu,d2186 @0x$(printf '%x' "$off")"
    fi

    # [2] LDO 电压表 D2207 → D2186（20 行 × 12 字节）
    local locs_old locs_new
    locs_old="$(bin_count "$out" "$ldo2207")"; locs_new="$(bin_count "$out" "$ldo2186")"
    if [ "$locs_old" = "0" ] && [ "$locs_new" -ge 1 ]; then
        log "  [2] LDO 表已是 D2186"
    else
        [ "$locs_old" = "1" ] || die "pmu: D2207 LDO 表命中 $locs_old 处（应为 1），拒绝继续"
        tab="$(bin_find "$out" "$ldo2207")"
        bin_write "$out" "$tab" "$ldo2186"
        log "  [2] LDO 表 D2207 → D2186 @0x$(printf '%x' "$tab")"
    fi

    # [3..6] _setLDO：锚在 LDO 表的 adrp/add 交叉引用上
    tab="$(bin_find "$out" "$ldo2207")"
    [ -n "$tab" ] || tab="$(bin_find "$out" "$ldo2186")"
    [ -n "$tab" ] || die "pmu: 找不到 LDO 表，无法定位 _setLDO"
    local adrp tva
    tva="$(kc_va_at "$out" "$tab")"
    adrp="$(kc_pmu_xref "$out" "$tva")"
    rail_off=$(( adrp - 8 ))
    cmp="$(bin_u32 "$out" "$rail_off")"
    cmp="$(printf '%08x' "$cmp")"
    case "$cmp" in
        "$RAIL_OLD") ;;
        "$RAIL_NEW") ;;
        *) die "pmu: _setLDO 档位范围不在预期位置（读到 0x${cmp}），拒绝继续" ;;
    esac
    cur="$(bin_u32 "$out" "$(( rail_off + 4 ))")"
    [ "$(( (cur & 0xFF00001F) ))" = "$(( 0x54000008 ))" ] ||
        die "pmu: _setLDO 档位范围之后不是 b.hi，拒绝继续"
    ws=$(( adrp - 128 )); we=$(( adrp + 608 ))
    win="$(bin_hex "$out" "$ws" "$(( we - ws ))")"

    # [3] 档位范围 cmp #0x16 → #0x13
    if [ "$cmp" = "$RAIL_OLD" ]; then
        bin_w32h "$out" "$rail_off" "$RAIL_NEW"
        log "  [3] 档位范围 cmp #0x16 → #0x13 @0x$(printf '%x' "$rail_off")"
    else
        log "  [3] 档位范围已是 #0x13"
    fi

    # [4] 能力掩码 movz/movk 0x1f7ff → movz 0x17ff + nop
    hits="$(kc_hx_hits "$win" "$(kc_whex "$MASK_O0")")"
    pat=""
    for i in $hits; do
        if [ "${win:$(( (i + 4) * 2 )):8}" = "$(kc_whex "$MASK_O1")" ] &&
           [ "${win:$(( (i + 8) * 2 )):8}" = "$(kc_whex "$MASK_FOLLOW")" ]; then
            pat="$i"; break
        fi
    done
    if [ -n "$pat" ]; then
        bin_w32h "$out" "$(( ws + pat ))" "$MASK_N0"
        bin_w32h "$out" "$(( ws + pat + 4 ))" "$NOP"
        log "  [4] 能力掩码 0x1f7ff → 0x17ff @0x$(printf '%x' "$(( ws + pat ))")"
    else
        hits="$(kc_hx_hits "$win" "$(kc_whex "$MASK_N0")")"
        cur=""
        for i in $hits; do
            if [ "${win:$(( (i + 4) * 2 )):8}" = "$(kc_whex "$NOP")" ] &&
               [ "${win:$(( (i + 8) * 2 )):8}" = "$(kc_whex "$MASK_FOLLOW")" ]; then
                cur="$i"; break
            fi
        done
        [ -n "$cur" ] || die "pmu: 找不到 _setLDO 能力掩码位置，拒绝继续"
        log "  [4] 能力掩码已是 0x17ff"
    fi

    # [5] 特殊寄存器 movz w1,#0x391 → #0x380（两处）
    local h_old h_new
    h_old="$(kc_hx_hits "$win" "$(kc_whex "$REG_OLD")")"
    h_new="$(kc_hx_hits "$win" "$(kc_whex "$REG_NEW")")"
    local c_old c_new
    c_old="$(printf '%s' "$h_old" | wc -w | tr -d ' ')"
    c_new="$(printf '%s' "$h_new" | wc -w | tr -d ' ')"
    if [ "$c_old" = "0" ] && [ "$c_new" = "2" ]; then
        log "  [5] 特殊寄存器已是 #0x380（两处）"
    elif [ "$c_old" = "2" ]; then
        for i in $h_old; do bin_w32h "$out" "$(( ws + i ))" "$REG_NEW"; done
        log "  [5] 特殊寄存器 #0x391 → #0x380（两处）"
    else
        die "pmu: _setLDO 里 movz w1,#0x391 命中 $c_old 处（应为 2），拒绝继续"
    fi

    # [6] 5V 升压块：用一条 b 跳过 rail 14..16 的升压代码
    local boost="" bpat
    bpat="$(kc_whex "$BOOST_SUB" "$BOOST_CMP")"
    hits="$(kc_hx_hits "$win" "$bpat")"
    for i in $hits; do boost="$i"; break; done
    if [ -n "$boost" ]; then
        bhi="$(bin_u32 "$out" "$(( ws + boost + 8 ))")"
        [ "$(( (bhi & 0xFF00001F) ))" = "$(( 0x54000008 ))" ] ||
            die "pmu: 升压块结构不符（boost+8 不是 b.hi），拒绝继续"
        local imm19
        imm19=$(( (bhi >> 5) & 0x7FFFF ))
        [ "$(( imm19 & 0x40000 ))" -ne 0 ] && imm19=$(( imm19 - 0x80000 ))
        local target
        target=$(( ws + boost + 8 + imm19 * 4 ))
        disp=$(( target - (ws + boost) ))
        { [ "$disp" -gt 0 ] && [ "$(( disp % 4 ))" -eq 0 ] && [ "$disp" -lt 134217728 ]; } ||
            die "pmu: 升压跳转目标越界，拒绝继续"
        bin_w32 "$out" "$(( ws + boost ))" "$(( (0x14000000 | ((disp / 4) & 0x03FFFFFF)) & 0xffffffff ))"
        log "  [6] 5V 升压块已跳过：b +0x$(printf '%x' "$disp") @0x$(printf '%x' "$(( ws + boost ))")"
    else
        local done_flag=""
        pat="$(kc_whex "$BOOST_CMP")"
        hits="$(kc_hx_hits "$win" "$pat")"
        for i in $hits; do
            [ "$i" -lt 4 ] && continue
            cur="$(printf '%08x' "$(bin_u32 "$out" "$(( ws + i - 4 ))")")"
            case "$cur" in 14*|15*|16*|17*) done_flag="$i"; break ;; esac
        done
        [ -n "$done_flag" ] || die "pmu: 找不到 _setLDO 升压块，拒绝继续"
        log "  [6] 5V 升压块已是跳过状态"
    fi

    # [7] GPIO → 寄存器映射：D2207(9 字) → D2186(6 字) + 3 个 nop
    local g_old g_new
    g_old="$(bin_count "$out" "$(kc_whex $GPIO_D2207)")"
    if [ "$g_old" = "0" ]; then
        g_new="$(bin_count "$out" "$(kc_whex $GPIO_D2186)")"
        [ "$g_new" -ge 1 ] || die "pmu: 找不到 D2207 GPIO 映射，拒绝继续"
        log "  [7] GPIO 映射已是 D2186"
    else
        [ "$g_old" = "1" ] || die "pmu: D2207 GPIO 映射命中 $g_old 处（应为 1），拒绝继续"
        off="$(bin_find "$out" "$(kc_whex $GPIO_D2207)")"
        bin_write "$out" "$off" "$(kc_whex $GPIO_D2186 $NOP $NOP $NOP)"
        log "  [7] GPIO 映射 D2207(9) → D2186(6)+3nop @0x$(printf '%x' "$off")"
    fi

    # [7b] GPIO 电平位掩码与 mode-2 输出位
    local a b np
    a="$(bin_find_all "$out" "$(kc_whex $GL_OLD)")"
    b="$(bin_find_all "$out" "$(kc_whex "$GL_NEW0" $GL_REST)")"
    np=0
    for i in $a $b; do np=$(( np + 1 )); done
    [ "$np" = "1" ] || die "pmu: GPIO 电平掩码锚点命中 $np 处（应为 1），拒绝继续"
    local mask drain
    mask=""
    for i in $a; do mask="$i"; done
    for i in $b; do mask="$i"; done
    [ -n "$mask" ] || die "pmu: 找不到 GPIO 电平掩码，拒绝继续"
    drain=$(( mask + MODE2_OFF ))
    cur="$(printf '%08x' "$(bin_u32 "$out" "$drain")")"
    local c4 c8 c12
    c4="$(printf '%08x' "$(bin_u32 "$out" "$(( drain + 4 ))")")"
    c8="$(printf '%08x' "$(bin_u32 "$out" "$(( drain + 8 ))")")"
    c12="$(printf '%08x' "$(bin_u32 "$out" "$(( drain + 12 ))")")"
    if { [ "$cur" != "$MODE2_OLD" ] && [ "$cur" != "$MODE2_NEW" ]; } ||
       [ "$c4" != "14000002" ] || [ "$c8" != "321f0108" ] || [ "$c12" != "39003fe8" ]; then
        die "pmu: GPIO mode-2 输出上下文不符，拒绝继续"
    fi
    if [ "$(printf '%08x' "$(bin_u32 "$out" "$mask")")" = "$GL_NEW0" ] && [ "$cur" = "$MODE2_NEW" ]; then
        log "  [7b] GPIO 电平位已是 D2186"
    else
        bin_w32h "$out" "$mask" "$GL_NEW0"
        bin_w32h "$out" "$drain" "$MODE2_NEW"
        log "  [7b] GPIO 电平位 0x1d → 0x05、mode-2 0x40 → 0x10 @0x$(printf '%x' "$mask")"
    fi

    # [8] 事件/IRQ 寄存器窗口保持 14 字节
    local anchors=() seen patched_off
    for pat in "$(kc_whex "$M1_70" "$W3_14" "$BLRX8")" "$(kc_whex "$M1_70" "$W3_13" "$BLRX8")"; do
        for i in $(bin_find_all "$out" "$pat"); do
            case "$pat" in
                "$(kc_whex "$M1_70" "$W3_14" "$BLRX8")") anchors+=("$i:0") ;;
                *) anchors+=("$i:1") ;;
            esac
        done
    done
    local na=${#anchors[@]}
    [ "$na" = "5" ] || die "pmu: 寄存器 0x70 传输锚点 $na 处（应为 5），拒绝继续"
    local sorted
    sorted="$(printf '%s\n' "${anchors[@]}" | sort -t: -k1,1n)"
    anchors=()
    while IFS= read -r i; do anchors+=("$i"); done <<EOF
$sorted
EOF
    local cl_start cl_end ncl=0
    i=0
    while [ "$i" -lt 3 ]; do
        local o0 o2
        o0="${anchors[$i]%%:*}"; o2="${anchors[$(( i + 2 ))]%%:*}"
        if [ "$(( o2 - o0 ))" -lt 4096 ]; then
            ncl=$(( ncl + 1 )); cl_start="$o0"; cl_end="$o2"
        fi
        i=$(( i + 1 ))
    done
    [ "$ncl" = "1" ] || die "pmu: 事件/IRQ 函数锚点簇不唯一（$ncl 个），拒绝继续"
    local dlo dhi
    dlo=$(( cl_start - 256 )); dhi=$(( cl_end + 256 ))
    local ev_old=() ev_new=()
    for i in "${anchors[@]}"; do
        case "${i##*:}" in 0) ev_old+=($(( ${i%%:*} + 4 ))) ;; *) ev_new+=($(( ${i%%:*} + 4 ))) ;; esac
    done
    local dwin
    dwin="$(bin_hex "$out" "$dlo" "$(( dhi - dlo ))")"
    for i in $(kc_hx_hits "$dwin" "$(kc_whex "$W2_14")"); do ev_old+=($(( dlo + i ))); done
    for i in $(kc_hx_hits "$dwin" "$(kc_whex "$W2_13")"); do ev_new+=($(( dlo + i ))); done
    [ "$(( ${#ev_old[@]} + ${#ev_new[@]} ))" = "8" ] ||
        die "pmu: 事件窗口指令 ${#ev_old[@]}+${#ev_new[@]} 处（应为 8），拒绝继续"
    if [ "${#ev_new[@]}" = "0" ]; then
        log "  [8] 事件/IRQ 窗口保持 14 字节"
    else
        for i in "${ev_new[@]}"; do
            cur="$(printf '%08x' "$(bin_u32 "$out" "$i")")"
            if [ "$cur" = "$W2_13" ]; then bin_w32h "$out" "$i" "$W2_14"
            else bin_w32h "$out" "$i" "$W3_14"; fi
        done
        log "  [8] 事件/IRQ 窗口恢复为 14 字节（${#ev_new[@]} 处）"
    fi

    # [W] 看门狗 personality：把 IOProviderClass 改成同样长度的 PMX，等于关掉它
    local prov
    prov="$(kc_pmu_provider "$out" AppleD2207PMUWatchDogTimer)"
    local val="${prov%%	*}"; local at="${prov##*	}"
    case "$val" in
        AppleD2207PMX) log "  [W] 看门狗 personality 已关闭" ;;
        AppleD2207PMU)
            [ "$at" != "0" ] || die "pmu: 看门狗 personality 用共享 IDREF，拒绝改写"
            bin_write "$out" "$at" "$(ascii2hex "<string>AppleD2207PMX</string>")"
            log "  [W] 看门狗 personality 已关闭 @0x$(printf '%x' "$at")" ;;
        *) die "pmu: 看门狗 personality 的 IOProviderClass 异常（${val}），拒绝继续" ;;
    esac

    # 收尾自检
    [ -z "$(bin_find "$out" "$ldo2207")" ] || die "pmu: 自检失败，D2207 LDO 表仍在"
    [ -n "$(bin_find "$out" "$ldo2186")" ] || die "pmu: 自检失败，D2186 LDO 表缺失"
    [ "$(bin_count "$out" "$(ascii2hex "$m_new")")" = "1" ] ||
        die "pmu: 自检失败，IONameMatch 不是 pmu,d2186"
    log "  pmu: D2186 适配完成（RTC 保留）"
}

# ---------- wifi：B1 固件审批表适配 ----------
# 内核 hashstore 里按「文件名 sha256」索引三份 B1 固件（trx / clmb / txcb）的摘要与长度。
# 12.5.8 的机器自带 barbera/tempranillo，13.7 的 j96 内核里批准的是另一份；
# 这里把三条记录的摘要换成板上固件本身的摘要，并把指针重定向到新增的 0x98 字节存储，
# 新增存储要进 KASLR 表，否则重启后地址不会被 slide。

WIFI_HS_HEADER="fffffff006dc3fa8"
WIFI_STORAGE="fffffff007002400"
WIFI_EXPECT=645

kc_wifi_b1() {   # board ext → "module<TAB>digest"
    awk -F'\t' -v b="$1" -v e="$2" '$1==b && $3==e { print $2"\t"$4; exit }' \
        "$KCD/wifi_b1.tsv"
}

kc_hs_dump() {   # file out
    kc_segmap "$1" "${TMPDIR:-/tmp}/n61-segmap.$$"
    "$PERL" "$REPO/lib/kchash.pl" --file "$1" --segmap "${TMPDIR:-/tmp}/n61-segmap.$$" \
        --va "$WIFI_HS_HEADER" --expect "$WIFI_EXPECT" >"$2" ||
        { rm -f "${TMPDIR:-/tmp}/n61-segmap.$$"; die "hashstore 索引读取失败"; }
    rm -f "${TMPDIR:-/tmp}/n61-segmap.$$"
}

kc_hs_line() {   # tsv keyhex → 该行
    awk -F'\t' -v k="$2" '$1==k { print; exit }' "$1"
}

kc_wifi() {   # in out
    local in="$1" out="$2" board="${T_MODEL:-n61ap}"
    local wd="${TMPDIR:-/tmp}/n61-wifi.$$" ext module digest fwdir
    local -a exts=() mods=() digs=() keys=() lens=() names=()
    mkdir -p "$wd"
    local line m
    for ext in trx clmb txcb; do
        m="$(kc_wifi_b1 "$board" "$ext")"
        [ -n "$m" ] || { rm -rf "$wd"; die "wifi: wifi_b1.tsv 里没有 $board/$ext"; }
        mods+=("$(printf '%s' "$m" | cut -f1)")
        digs+=("$(printf '%s' "$m" | cut -f2)")
        names+=("C-4345__s-B1/$(printf '%s' "$m" | cut -f1).$ext")
    done
    module="${mods[0]}"
    fwdir="$REPO/ipsw/cache/derived/wifi"
    for ext in trx clmb txcb; do
        [ -f "$fwdir/C-4345__s-B1/${module}.$ext" ] ||
            { rm -rf "$wd"; die "wifi: 缺少板上固件 $fwdir/C-4345__s-B1/${module}.$ext（由 12.5.8 提取）"; }
    done

    cp "$in" "$out"
    kc_hs_dump "$out" "$wd/before.tsv"
    [ "$(wc -l <"$wd/before.tsv" | tr -d ' ')" = "$WIFI_EXPECT" ] ||
        { rm -rf "$wd"; die "wifi: hashstore 记录数异常"; }

    local i=0 same=1 k
    for ext in trx clmb txcb; do
        k="$(printf '%s' "${names[$i]}" | shasum -a 256 | awk '{print $1}')"
        keys+=("$k")
        line="$(kc_hs_line "$wd/before.tsv" "$k")"
        [ -n "$line" ] || { rm -rf "$wd"; die "wifi: hashstore 里没有 ${names[$i]}"; }
        digs[$i]="$(printf '%s' "$line" | cut -f8)"
        lens[$i]="$(printf '%s' "$line" | cut -f6)"
        i=$(( i + 1 ))
    done
    # 固件文件的真实摘要与长度
    i=0
    for ext in trx clmb txcb; do
        local f="$fwdir/C-4345__s-B1/${module}.$ext" sz sh
        sz="$(bin_len "$f")"; sh="$(kc_sha "$f")"
        if [ "${digs[$i]}" != "$sh" ] || [ "${lens[$i]}" != "$sz" ]; then same=0; fi
        digs[$i]="$sh"; lens[$i]="$sz"
        i=$(( i + 1 ))
    done
    if [ "$same" = "1" ]; then
        log "  wifi: B1 固件审批表已是最新"
        rm -rf "$wd"
        return 0
    fi

    # 新存储必须落在 __PLK_DATA_CONST 的零填充里
    local sva soff
    sva="$WIFI_STORAGE"
    kc_seg_get "$out" __PLK_DATA_CONST
    local pend
    pend="$(hex16_add "${KC_ONE_VM#0x}" "$KC_ONE_FS")"
    hex16_le "${KC_ONE_VM#0x}" "$sva" && hex16_le "$(hex16_add "$sva" 152)" "$pend" ||
        { rm -rf "$wd"; die "wifi: 新增存储不在 __PLK_DATA_CONST 内"; }
    soff="$(kc_off_at "$out" "$sva")"
    bin_is_zero "$out" "$soff" 152 ||
        { rm -rf "$wd"; die "wifi: 新增存储区已被占用（不是零填充）"; }

    # 三条记录：写摘要块（长度 32 + 32 字节摘要），再把指针指过去
    i=0
    for ext in trx clmb txcb; do
        local blob link new prior
        blob="$(hex16_add "$sva" $(( i * 36 )))"
        bin_w32 "$out" "$(kc_off_at "$out" "$blob")" 32
        bin_write "$out" "$(kc_off_at "$out" "$(hex16_add "$blob" 4)")" "${digs[$i]}"
        local entry value olddig
        line="$(kc_hs_line "$wd/before.tsv" "${keys[$i]}")"
        entry="$(printf '%s' "$line" | cut -f2)"
        value="$(printf '%s' "$line" | cut -f3)"
        olddig="$(printf '%s' "$line" | cut -f8)"
        local want
        want="$(kc_wifi_b1 "$board" "$ext" | cut -f2)"
        [ "$olddig" = "$want" ] ||
            { rm -rf "$wd"; die "wifi: ${names[$i]} 的原有摘要不是预期基线，拒绝改写"; }
        if [ "$i" = "0" ]; then
            # trx 的 value 被三个键共用：克隆一份 24 字节再单独改这个键的链接
            local clone
            clone="$(hex16_add "$sva" 128)"
            bin_slice "$out" "$wd/clone.bin" "$(kc_off_at "$out" "$value")" 24 ||
                { rm -rf "$wd"; die "wifi: 克隆 trx 记录失败"; }
            bin_write "$out" "$(kc_off_at "$out" "$clone")" "$(bin_hex "$wd/clone.bin" 0 24)"
            bin_w64h "$out" "$(kc_off_at "$out" "$clone")" "$blob"
            link="$(hex16_add "$entry" 8)"
            new="$clone"
        else
            [ "$(awk -F'\t' -v v="$value" '$3==v' "$wd/before.tsv" | wc -l | tr -d ' ')" = "1" ] ||
                { rm -rf "$wd"; die "wifi: ${ext} 的记录指针被共用，拒绝改写"; }
            link="$value"; new="$blob"
        fi
        prior="$(bin_hex "$out" "$(kc_off_at "$out" "$link")" 8)"
        bin_w64h "$out" "$(kc_off_at "$out" "$link")" "$new"
        log "  wifi: ${names[$i]} → 摘要已换（链接 0x${link}：$prior → 0x${new}）"
        i=$(( i + 1 ))
    done

    # 新增的两个 KASLR 槽（0x80 处的克隆、0x90 处的保留位）
    local meta="$wd/meta"
    : >"$wd/empty.dict"
    {
        printf 'plist_mode=surgery\n'
        printf 'plist_intern=0\n'
        printf 'plist_blob=empty.dict\n'
        printf 'plist_added=%s,%s\n' \
            "$(hex16_add "$sva" 128)" "$(hex16_add "$sva" 144)"
    } >"$meta"
    kc_seg_get "$out" __PRELINK_TEXT
    local base_vm="${KC_ONE_VM#0x}"
    kc_seg_get "$out" __PRELINK_INFO
    "$PERL" "$REPO/lib/kcplist.pl" --file "$out" --seg "$KC_ONE_FO,$KC_ONE_FS" \
        --base "$base_vm" --meta "$meta" >/dev/null ||
        { rm -rf "$wd"; die "wifi: KASLR 表追加失败"; }
    rm -rf "$wd"
    log "  wifi: B1 审批表已适配（ ${module}）"
}

# ---------- 基底：j96 干净内核 + 打包 ----------
# 对应 patches/kc/j96_clean.py（base）与 n56patcher.py 的 Flow._pack_kc。
# 注意：log/ok 都写 stdout，所以这里用全局 KC_ART 传产物路径，不靠 echo。

kc_has_feature() {   # name → 0/1
    case " ${OPT_FEATURES:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

kc_base() {   # → 设 KC_ART
    local raw="$WK/kc.j96.raw" kp="$WK/kc.j96.kploosh" out="$WK/kc.j96.clean.raw" b
    "$(tool img4)" -i "$(derived_path j96_kernel)" -o "$raw" >/dev/null ||
        die "j96 内核解包失败"
    "$(tool KPlooshFinder)" "$raw" "$kp" >/dev/null 2>&1 || die "KPlooshFinder 失败"
    "$(tool Kernel64Patcher)" "$kp" "$out" -b13 -n >/dev/null 2>&1 ||
        die "Kernel64Patcher -b13 -n 失败"
    # K64P 顺手改了 APFS 诊断字符串里的一个字节；按原启动链 kerneldiff 的过滤规则还原
    b="$(bin_hex "$raw" $(( 0xaa6577 )) 1)"
    bin_write "$out" $(( 0xaa6577 )) "$b"
    log "  kc.j96_clean: $(bin_len "$out") 字节（APFS 字符串 @0xaa6577 已还原）"

    if kc_has_feature checkra1n; then
        local merged="$WK/kc.checkra1n.raw" ki="$WK/kc.kerninfo.raw"
        kc_checkra1n_merge "$raw" "$out" "$merged"
        kc_kerninfo "$merged" "$ki"
        out="$ki"
    fi
    KC_ART="$out"
}

# 补丁 id → 实现。名字与 Python 产物名保持一致，便于两边对拍。
kc_transform() {   # id in out
    case "$1" in
        kc.pmu_d2186)     kc_pmu "$2" "$3" ;;
        kc.sn2400)        kc_apply_table sn2400 "$2" "$3" ;;
        kc.chestnut_kext) kc_apply_table chestnut "$2" "$3" ;;
        kc.mt_n56)        kc_mt "$2" "$3" "${T_MODEL:-n61ap}" ;;
        kc.wifi)          kc_wifi "$2" "$3" ;;
        kc.vibration)     kc_apply_table vibration "$2" "$3" ;;
        kc.legacy_sep)    kc_legacy_sep "$2" "$3" ;;
        kc.audio)         kc_apply_table audio "$2" "$3" ;;
        *) die "未实现的 kc 变换: $1（bash 版只覆盖 j96→n61 这条链）" ;;
    esac
}

# id → 产物文件名（沿用 Python 版的名字）
kc_out_name() {
    case "$1" in
        kc.pmu_d2186)     printf '%s\n' kc.pmu.raw ;;
        kc.sn2400)        printf '%s\n' kc.sn2400.raw ;;
        kc.chestnut_kext) printf '%s\n' kc.chestnut.raw ;;
        kc.mt_n56)        printf '%s\n' kc.mt.raw ;;
        kc.wifi)          printf '%s\n' kc.wifi.raw ;;
        kc.vibration)     printf '%s\n' kc.vibration.raw ;;
        kc.legacy_sep)    printf '%s\n' kc.legacy-sep.raw ;;
        kc.audio)         printf '%s\n' kc.audio.raw ;;
        *)                printf '%s\n' "kc.${1#kc.}.raw" ;;
    esac
}

# 编译 mkcomplzss（仓库自带 C 源码 + img4lib 的 lzss.c，只用系统 cc）
kc_mkcomplzss() {   # → 打印可执行文件路径
    local bin="$WK/mkcomplzss"
    local c1="$REPO/patches/impl/kc/chestnut/mkcomplzss.c"
    local c2="$REPO/tools/img4lib/lzss.c"
    if [ ! -x "$bin" ] || [ "$c1" -nt "$bin" ] || [ "$c2" -nt "$bin" ]; then
        cc -O2 -I "$REPO/tools/img4lib" "$c1" "$c2" -o "$bin" ||
            die "mkcomplzss 编译失败（需要 Xcode 命令行工具：xcode-select --install）"
    fi
    printf '%s\n' "$bin"
}

kc_pack() {   # raw out
    local raw="$1" out="$2" ref mklzss lzss full rt
    [ -f "$raw" ] || die "kc_pack: 输入不存在 $raw"
    ref="$(derived_path j96_kernel)"
    mklzss="$(kc_mkcomplzss)"
    lzss="$WK/kc.lzss"; full="$WK/kc.full.lzss"; rt="$WK/kc.roundtrip.raw"

    "$mklzss" "$raw" "$lzss" || die "mkcomplzss 失败"
    "$PERL" "$REPO/lib/watchtower.pl" "$ref" "$lzss" "$full" ||
        die "watchtower 追加失败"
    "$(tool img4)" -i "$ref" -R "$full" -T rkrn -M "$(im4m_path)" -o "$out" >/dev/null ||
        die "rkrn 打包签名失败"
    "$(tool img4)" -i "$out" -o "$rt" >/dev/null || die "roundtrip 解包失败"
    if ! /usr/bin/cmp -s "$raw" "$rt"; then
        die "KC roundtrip 校验失败：打包后解出与输入不一致"
    fi
    log "  KC roundtrip 校验通过（$(bin_len "$out") 字节）"
}
