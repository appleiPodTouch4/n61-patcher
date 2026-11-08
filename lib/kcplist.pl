#!/usr/bin/perl
# 预链接 plist 段改写（bash 侧无法安全处理 2.4MB 二进制 + base64，交给系统 perl）。
#
# 用法：
#   perl kcplist.pl --file F --seg FO,FS --base VM --meta META
#
# 按 META 里的 plist_mode 分两种：
#   surgery  改 KASLR 表（base64）+ 在 _PrelinkInfoDictionary 的 <array> 后插入字典
#   blob     整段以 gzip 存下，直接替换
#
# surgery 时若 plist_intern=1，先做字符串内联（重复 >=3 次且长度 >=12 的
# <string> 抽成 ID/IDREF），与 Python 版 intern_strings 等价。

use strict;
use warnings;
use MIME::Base64 qw(encode_base64 decode_base64);
use Compress::Zlib ();
no warnings q(portable);

my %a;
while (@ARGV) {
    my $k = shift @ARGV;
    my $v = shift @ARGV;
    $k =~ s/^--//;
    $a{$k} = $v;
}
for my $need (qw(file seg base meta)) {
    die "缺少 --$need\n" unless defined $a{$need};
}
my ($fo, $fs) = split /,/, $a{seg};

my %meta;
open(my $mh, '<', $a{meta}) or die "读不到 $a{meta}: $!\n";
while (<$mh>) {
    chomp;
    next unless /=/;
    my ($k, $v) = split /=/, $_, 2;
    $meta{$k} = $v;
}
close $mh;

open(my $fh, '+<:raw', $a{file}) or die "打开 $a{file}: $!\n";
seek($fh, $fo, 0) or die "定位: $!\n";
read($fh, my $seg, $fs) == $fs or die "读段失败\n";
$seg =~ s/\0+\z//;
my $need = $fs;

my $mode = $meta{plist_mode} || 'surgery';
my $out;

if ($mode eq 'blob') {
    my $gz = $a{meta};
    $gz =~ s/[^\/]*\z//;
    my $path = $gz . ($meta{plist_gz} || die "meta 缺少 plist_gz\n");
    open(my $zh, '<:raw', $path) or die "读不到 $path: $!\n";
    local $/;
    my $blob = Compress::Zlib::memGunzip(<$zh>);
    close $zh;
    die "plist blob 解压失败（$path）\n" unless defined $blob;
    die "plist blob 超过段容量\n" if length($blob) > $need;
    $out = $blob;
} else {
    $seg = intern($seg) if ($meta{plist_intern} || '0') eq '1';

    # ---- KASLR 表：把新增槽接在末尾，长度前缀跟着变 ----
    my $added = $meta{plist_added} || '';
    my @added = map { hex($_) } grep { length } split /,/, $added;
    my $ki = index($seg, '_PrelinkLinkKASLROffsets');
    die "找不到 _PrelinkLinkKASLROffsets\n" if $ki < 0;
    my $ds = index($seg, '<data>', $ki) + 6;
    my $de = index($seg, '</data>', $ds);
    die "KASLR 数据块不完整\n" if $de < $ds;
    my $raw = decode_base64(substr($seg, $ds, $de - $ds));
    die "KASLR 表长度非 4 的倍数\n" if length($raw) % 4;
    my @words = unpack('V*', $raw);
    my $oldn = $words[0];
    die "KASLR 计数与长度不符（$oldn vs " . (scalar(@words) - 1) . "）\n"
        if $oldn != @words - 1;
    my $base = hex($a{base});
    my @all = (@words[1 .. $oldn], map { ($_ - $base) & 0xFFFFFFFF } @added);
    my $payload = pack('V*', scalar(@all), @all);
    substr($seg, $ds, $de - $ds, encode_base64($payload, ''));

    # ---- 新 kext 字典：插在 _PrelinkInfoDictionary 的 <array> 之后 ----
    my $meta_dir = $a{meta};
    $meta_dir =~ s/[^\/]*\z//;
    my $blobf = $meta_dir . ($meta{plist_blob} || die "meta 缺少 plist_blob\n");
    open(my $bh, '<:raw', $blobf) or die "读不到 $blobf: $!\n";
    local $/;
    my $dict = <$bh>;
    close $bh;
    my $ii = index($seg, '_PrelinkInfoDictionary');
    die "找不到 _PrelinkInfoDictionary\n" if $ii < 0;
    my $ar = index($seg, '<array>', $ii);
    die "找不到 _PrelinkInfoDictionary 的 <array>\n" if $ar < 0;
    my $at = $ar + 7;
    substr($seg, $at, 0, $dict);
    $out = $seg;
}

die "plist 段超出容量（" . length($out) . " > $need）\n" if length($out) > $need;
$out .= "\0" x ($need - length($out));
seek($fh, $fo, 0) or die "回写定位: $!\n";
print $fh $out;
close($fh) or die "回写失败: $!\n";
print "plist: $mode " . ($mode eq 'blob' ? length($out) : length($seg)) . " 字节\n";

# ------------------------------------------------------------------ 内联
sub intern {
    my ($xml) = @_;
    my %count;
    $count{$1}++ while $xml =~ /<string>([^<]*)<\/string>/g;
    my $next = 0;
    $next = $1 + 1 while $xml =~ / ID="(\d+)"/g;
    my %shared;
    $xml =~ s{<string>([^<]*)</string>}{
        my $v = $1;
        if (length($v) < 12 || ($count{$v} || 0) < 3) { "<string>$v</string>" }
        elsif (exists $shared{$v}) { '<string IDREF="' . $shared{$v} . '"/>' }
        else {
            my $id = $next++;
            $shared{$v} = $id;
            '<string ID="' . $id . '">' . $v . '</string>';
        }
    }ge;
    return $xml;
}
