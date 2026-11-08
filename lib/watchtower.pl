#!/usr/bin/perl
# watchtower.pl <orig_im4p_or_img4> <my_complzss> <out>
#
# iOS kernelcache 的 IM4P 载荷 = complzss(0x180 头 + 压缩流) + 尾部 watchtower
# （一段独立数据，本机实测 0xC000 字节的小 Mach-O）。img4 -P 重压缩会保留该尾部，
# 但 img4 -R 和我们自己的 mkcomplzss 不会 —— 缺了它 iBoot 会卡在
# "validate kernelcache" 进不了内核。
#
# 本脚本从原始 KC 载荷（DER 里最大的 OCTET STRING）提取该尾部，
# 追加到我们生成的 complzss 之后。等价于 patches/impl/kc/chestnut/append_watchtower.py。
use strict;
use warnings;

my ($orig, $mine, $out) = @ARGV;
die "usage: $0 <orig> <mine> <out>\n" unless defined $out;

# ---------- DER ----------
sub rdlen {   # (\$data, pos) → (len, next_pos)
    my ($dref, $p) = @_;
    my $l = ord(substr($$dref, $p, 1));
    $p++;
    if ($l & 0x80) {
        my $nb = $l & 0x7f;
        my $L = 0;
        for my $i (0 .. $nb - 1) {
            $L = $L * 256 + ord(substr($$dref, $p + $i, 1));
        }
        return ($L, $p + $nb);
    }
    return ($l, $p);
}

sub biggest_octet {
    my ($path) = @_;
    open my $f, '<:raw', $path or die "$path: $!";
    local $/;
    my $d = <$f>;
    close $f;
    die "不是 ASN.1 SEQUENCE: $path\n" unless ord(substr($d, 0, 1)) == 0x30;
    my ($L, $p) = rdlen(\$d, 1);
    my $end = $p + $L;
    my @octs;
    my $walk;
    $walk = sub {
        my ($a, $b) = @_;
        my $pp = $a;
        while ($pp < $b) {
            my $tag = ord(substr($d, $pp, 1));
            my ($ln, $q) = rdlen(\$d, $pp + 1);
            if ($tag == 0x04) {
                push @octs, substr($d, $q, $ln);
            } elsif ($tag == 0x30) {
                $walk->($q, $q + $ln);
            }
            $pp = $q + $ln;
        }
    };
    $walk->($p, $end);
    die "DER 里没有 OCTET STRING: $path\n" unless @octs;
    my $best = $octs[0];
    for my $o (@octs) { $best = $o if length($o) > length($best); }
    return $best;
}

sub watchtower {
    my ($payload) = @_;
    die "原载荷不是 complzss\n" unless substr($payload, 0, 8) eq 'complzss';
    my $csize = unpack('N', substr($payload, 16, 4));
    return substr($payload, 0x180 + $csize);
}

# ---------- main ----------
my $wt = watchtower(biggest_octet($orig));

open my $in, '<:raw', $mine or die "$mine: $!";
local $/;
my $mydata = <$in>;
close $in;

open my $o, '>:raw', $out or die "$out: $!";
print $o $mydata, $wt;
close $o or die "$out: $!";

printf STDERR "append_watchtower: +%d bytes -> %s (total %d)\n",
    length($wt), $out, length($mydata) + length($wt);
