#!/usr/bin/perl
# trustcache.pl <base_raw> <out_raw> <digest_list>
#
# 把一批 cdhash（每行 40 位十六进制）并进静态 TrustCache（v1，24 字节头 + 22 字节/条），
# 按 cdhash 排序后写出。等价于 core/trustcache.py 里 dict 合并 + sorted(entries) 的写法。
#
# 布局：header[0,20) | count(u32 LE) | count × (cdhash[20] | hash_type u8 | flags u8)
# 新加条目的 hash_type = 2（sha256 截断），flags = 0。
use strict;
use warnings;

my ($base, $out, $list) = @ARGV;
die "usage: $0 <base_raw> <out_raw> <digest_list>\n" unless defined $list;

open my $f, '<:raw', $base or die "$base: $!";
my $d;
{ local $/; $d = <$f>; }   # 只在这个块里吃掉输入记录分隔符
close $f;

die "$base: 太短\n" if length($d) < 24;
my $header = substr($d, 0, 20);
my $ver = unpack('V', substr($d, 0, 4));
my $count = unpack('V', substr($d, 20, 4));
die sprintf("%s: 不是 v1 TC（version %d）\n", $base, $ver) if $ver != 1;
die sprintf("%s: 长度 %d 与 %d 条不符\n", $base, length($d), $count)
    if length($d) != 24 + $count * 22;

my %entries;
for my $i (0 .. $count - 1) {
    my $ent = substr($d, 24 + $i * 22, 22);
    $entries{substr($ent, 0, 20)} = $ent;
}
my $before = scalar keys %entries;

open my $l, '<', $list or die "$list: $!";
my $added = 0;
while (<$l>) {
    chomp;
    s/\s+//g;
    next unless length($_) == 40;
    die "非法 cdhash: $_\n" unless $_ =~ /\A[0-9a-f]{40}\z/;
    my $digest = pack('H*', $_);
    $added++ unless exists $entries{$digest};
    $entries{$digest} = $digest . pack('C2', 2, 0);
}
close $l;

my $payload = join('', map { $entries{$_} } sort keys %entries);
open my $o, '>:raw', $out or die "$out: $!";
print $o $header, pack('V', scalar keys %entries), $payload;
close $o or die "$out: $!";

printf STDERR "trustcache: %d → %d 条（新增 %d）\n",
    $before, scalar keys %entries, $added;
