# shellcheck shell=bash
# 二进制原语（kernelcache / Mach-O 手术的地基）。
#
# 为什么不是纯内建：shell 变量存不了 NUL，`dd`/`od` 做一次字节查找要遍历 34MB，
# 都不可用。这里把「按字节查找 / 结构化读写」交给 macOS 自带的 perl（5.30+，
# 系统路径 /usr/bin/perl），每个原语一次进程、只返回文本结果，逻辑仍在 shell 里。
# 除此之外不引入任何第三方依赖（不装 CPAN 模块，不用 Python）。
#
# 约定：
#   - 偏移与长度一律十进制（shell 算术），十六进制只在字节串参数里出现。
#   - 64 位值用 bash 算术（有符号 64 位，按 2^64 取模），打印时由 perl 转无符号。

PERL="${PERL:-perl}"

bin_err() { die "二进制原语失败: $*"; }

# ---------- 十六进制字符串 ----------
hexrev() {   # 按字节反序（小端 ↔ 大端）
    local h="$1" out="" i=$(( ${#1} - 2 ))
    while [ "$i" -ge 0 ]; do
        out="$out${h:$i:2}"
        i=$(( i - 2 ))
    done
    printf '%s' "$out"
}

hex2ascii() {   # 十六进制 → 文本（末尾 NUL 去掉）
    local h="$1"
    while [ "${h%00}" != "$h" ]; do h="${h%00}"; done
    [ -n "$h" ] || return 0
    printf '%b' "$(printf '%s' "$h" | sed 's/\(..\)/\\x\1/g')"
}

ascii2hex() { printf '%s' "$1" | "$PERL" -ne 'print unpack("H*",$_)'; }

hex16_add() {   # h16 n → h16（n 为十进制）
    local hi lo
    hi=$(( 0x${1:0:8} ))
    lo=$(( 0x${1:8:8} + $2 ))
    hi=$(( hi + (lo >> 32) ))
    printf '%08x%08x' $(( hi & 0xffffffff )) $(( lo & 0xffffffff ))
}

hex16_sub() {   # h16 a b（a≥b）→ h16
    local hi lo borrow=0
    lo=$(( 0x${1:8:8} - 0x${2:8:8} ))
    [ "$lo" -lt 0 ] && { lo=$(( lo + 4294967296 )); borrow=1; }
    hi=$(( 0x${1:0:8} - 0x${2:0:8} - borrow ))
    printf '%08x%08x' $(( hi & 0xffffffff )) $(( lo & 0xffffffff ))
}

hex16_le() { [ "$1" \< "$2" ] || [ "$1" = "$2" ]; }   # a ≤ b（定宽十六进制）

hx_u32() {   # hexstring off → 十进制
    printf '%d' $(( 0x$(hexrev "${1:$(( $2 * 2 )):8}") ))
}

hx_u64() {   # hexstring off → h16
    hexrev "${1:$(( $2 * 2 )):16}"
}


# ---------- 定长读 ----------
bin_u32() {   # file offset → 十进制
    "$PERL" -e 'open my $f,"<:raw",$ARGV[0] or die "$ARGV[0]: $!";
        seek $f,$ARGV[1],0; read $f,my $b,4; die "short read" if length($b)<4;
        printf "%u", unpack("V",$b)' "$1" "$2" || bin_err "读 u32 @$2"
}

bin_u64() {   # file offset → 十进制
    "$PERL" -e 'open my $f,"<:raw",$ARGV[0] or die "$ARGV[0]: $!";
        seek $f,$ARGV[1],0; read $f,my $b,8; die "short read" if length($b)<8;
        printf "%u", unpack("Q<",$b)' "$1" "$2" || bin_err "读 u64 @$2"
}

bin_hex() {   # file offset len → 小写十六进制串
    "$PERL" -e 'open my $f,"<:raw",$ARGV[0] or die "$ARGV[0]: $!";
        seek $f,$ARGV[1],0; read $f,my $b,$ARGV[2];
        print unpack("H*",$b)' "$1" "$2" "$3" || bin_err "读 $3 字节 @$2"
}

bin_len() { /usr/bin/stat -f %z "$1"; }

# ---------- 查找 ----------
# 字节串参数是十六进制；返回十进制偏移（每行一个）。
bin_find() {   # file hexpat [from] → 首个偏移（无则空）
    "$PERL" -e 'open my $f,"<:raw",$ARGV[0] or die "$ARGV[0]: $!";
        local $/; my $d=<$f>; my $p=pack("H*",$ARGV[1]);
        my $at=index($d,$p,defined $ARGV[2]?$ARGV[2]:0);
        print $at if $at>=0' "$1" "$2" "${3:-0}"
}

bin_find_all() {   # file hexpat [max] → 每行一个偏移
    "$PERL" -e 'open my $f,"<:raw",$ARGV[0] or die "$ARGV[0]: $!";
        local $/; my $d=<$f>; my $p=pack("H*",$ARGV[1]);
        my $max=defined $ARGV[2]&&$ARGV[2]>0?$ARGV[2]:0; my $n=0;
        my $at=index($d,$p);
        while($at>=0){ print "$at\n"; $n++; last if $max && $n>=$max;
            $at=index($d,$p,$at+1); }' "$1" "$2" "${3:-0}"
}

bin_count() {   # file hexpat → 出现次数
    bin_find_all "$1" "$2" | wc -l | tr -d ' '
}

# 字符串（ASCII）查找，等价于在文件里找该字节序列。
bin_find_str() {   # file text [from]
    local hex
    hex="$(printf '%s' "$2" | "$PERL" -ne 'print unpack("H*",$_)')"
    bin_find "$1" "$hex" "${3:-0}"
}

# ---------- 写 ----------
bin_write() {   # file offset hexbytes  （就地覆盖，不改变文件长度）
    "$PERL" -e 'open my $f,"+<:raw",$ARGV[0] or die "$ARGV[0]: $!";
        seek $f,$ARGV[1],0; print $f pack("H*",$ARGV[2]);' "$1" "$2" "$3" ||
        bin_err "写 @$2"
}

bin_w32() {   # file offset value（按 2^32 截断）
    local hex
    hex="$(printf '%08x' "$(( $3 & 0xffffffff ))" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')"
    bin_write "$1" "$2" "$hex"
}

bin_w64() {   # file offset value（按 2^64 截断，小端）
    local hex
    hex="$("$PERL" -e 'printf "%016x", $ARGV[0] & 0xffffffffffffffff' "$3" 2>/dev/null)"
    if [ -z "$hex" ]; then
        # perl 拿到超长十进制会退化成浮点；用 bash 的 64 位算术兜底
        hex="$("$PERL" -e 'my $v=hex($ARGV[0]); printf "%016x",$v' \
            "$(printf '%x' "$3")")"
    fi
    hex="$(printf '%s' "$hex" | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\8\7\6\5\4\3\2\1/')"
    bin_write "$1" "$2" "$hex"
}

bin_w32h() {   # file offset value_hex8（已是主机字节序）
    bin_write "$1" "$2" "$(hexrev "$3")"
}

bin_w64h() {   # file offset value_hex16
    bin_write "$1" "$2" "$(hexrev "$3")"
}

bin_zero_range() {   # file offset len
    local hex i=0
    while [ "$i" -lt "$3" ]; do hex="${hex}00"; i=$(( i + 1 )); done
    bin_write "$1" "$2" "$hex"
}

# 等长替换：pattern/repl 都是十六进制。返回替换次数。
bin_replace() {   # file hexpat hexrepl [expect]  （expect 给定时校验次数）
    local n
    n="$("$PERL" -e '
        open my $f,"+<:raw",$ARGV[0] or die "$ARGV[0]: $!";
        local $/; my $d=<$f>;
        my $p=pack("H*",$ARGV[1]); my $r=pack("H*",$ARGV[2]);
        die "长度不等长" if length($p)!=length($r);
        my $n=0; my $at=index($d,$p);
        while($at>=0){ substr($d,$at,length($r),$r); $n++; $at=index($d,$p,$at+1); }
        if($n){ seek $f,0,0; print $f $d; truncate $f,length($d); }
        print $n;' "$1" "$2" "$3")" || bin_err "替换失败: $2"
    printf '%s\n' "$n"
}

# 4 字节字（指令）层面的差异表：a b → 每行 "偏移 旧值 新值"
bin_diff_words() {   # a b
    "$PERL" -e '
        open my $fa,"<:raw",$ARGV[0] or die; open my $fb,"<:raw",$ARGV[1] or die;
        local $/; my $a=<$fa>; my $b=<$fb>;
        die "长度不同" if length($a)!=length($b);
        for(my $o=0;$o<length($a);$o+=4){
            my $x=substr($a,$o,4); my $y=substr($b,$o,4);
            next if $x eq $y;
            printf "%d %08x %08x\n", $o, unpack("V",$x), unpack("V",$y);
        }' "$1" "$2"
}

# ---------- 片段 ----------
bin_slice() {   # in out offset len
    "$PERL" -e 'open my $f,"<:raw",$ARGV[0] or die; open my $o,">:raw",$ARGV[1] or die;
        seek $f,$ARGV[2],0; read $f,my $b,$ARGV[3]; print $o $b;' "$1" "$2" "$3" "$4" ||
        bin_err "取片段 @$3+$4"
}

bin_is_zero() {   # file offset len → 0 全零 / 1 含非零
    local hex
    hex="$(bin_hex "$1" "$2" "$3")"
    case "$hex" in *[!0]*) return 1 ;; *) return 0 ;; esac
}

bin_same() {   # a b offset len → 0 相同
    [ "$(bin_hex "$1" "$3" "$4")" = "$(bin_hex "$2" "$3" "$4")" ]
}

# 从 tsv（offset before after，十六进制偏移）批量应用字节补丁。
bin_apply_tsv() {   # file tsv
    local file="$1" tsv="$2" off before after n=0
    [ -f "$tsv" ] || die "缺少字节补丁表: $tsv"
    while IFS="$(printf '\t')" read -r off before after; do
        [ -n "$off" ] || continue
        case "$off" in \#*) continue ;; esac
        # 十进制或 0x 前缀都可以（bash 算术两种都认）；裸十六进制不支持
        off=$(( off ))
        [ "$(bin_hex "$file" "$off" "$(( ${#before} / 2 ))")" = "$before" ] ||
            die "字节补丁不匹配: $tsv @0x$(printf '%x' "$off")"
        bin_write "$file" "$off" "$after"
        n=$(( n + 1 ))
    done <"$tsv"
    printf '%s\n' "$n"
}

hex_zero() {   # n（十六进制字符数）→ n 个 0
    local i=0 o=""
    while [ "$i" -lt "$1" ]; do o="${o}00"; i=$(( i + 2 )); done
    printf '%s' "$o"
}

hex2dec() {   # 十六进制串 → 十进制（超过 2^63 也能正确）
    "$PERL" -e 'printf "%u", hex($ARGV[0])' "$1"
}

# 找出目录树里的 Mach-O（一次 perl 走完，别对每个文件起一个进程）
bin_macho_list() {   # dir… → 每行一个路径（有序）
    "$PERL" -MFile::Find -e '
        my %m = map { $_ => 1 } qw(cffaedfe cefaedfe feedfacf cafebabe bebafeca);
        for my $root (@ARGV) {
            next unless -d $root;
            find({ no_chdir => 1, wanted => sub {
                return unless -f $_ && ! -l $_;
                open my $f, "<:raw", $_ or return;
                read $f, my $b, 4;
                close $f;
                return unless defined $b && length($b) == 4;
                print "$_\n" if $m{unpack("H*", $b)};
            } }, $root);
        }' "$@" | sort
}
