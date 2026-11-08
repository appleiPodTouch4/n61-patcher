#!/usr/bin/perl
# 导出内核 hashstore 索引（Wi-Fi B1 固件审批表）。
#
# 用法：perl kchash.pl --file F --segmap M --va <HEADER_VA> --expect <N>
#
#   --segmap 由 lib/macho.sh 的 kc_segmap 生成，每行 "vm十六进制 文件偏移 文件长度"
#   --va      hashstore 头虚拟地址（V 开头的大值，按十六进制字符串传）
#
# 每条记录输出一行（制表符分隔）：
#   key_hex  entry_va  value_va  blob_va  flags  length  aux  digest_hex

use strict;
use warnings;
no warnings 'portable';    # 0xfffffff0xxxxxxxx 这类 64 位地址会触发 portable 警告

my %a;
while (@ARGV) {
    my $k = shift @ARGV;
    my $v = shift @ARGV;
    $k =~ s/^--//;
    $a{$k} = $v;
}
for my $need (qw(file segmap va expect)) {
    die "缺少 --$need\n" unless defined $a{$need};
}

open(my $mh, '<', $a{segmap}) or die "读不到 $a{segmap}: $!\n";
my @segs;
while (<$mh>) {
    chomp;
    my ($vm, $fo, $fs) = split /\s+/;
    push @segs, [ hex($vm), 0 + $fo, 0 + $fs ];
}
close $mh;

open(my $fh, '<:raw', $a{file}) or die "打开 $a{file}: $!\n";

sub rd {                      # ($va, $len) → 字节串
    my ($va, $n) = @_;
    for my $s (@segs) {
        my ($vm, $fo, $fs) = @$s;
        next unless $va >= $vm && $va + $n <= $vm + $fs;
        my $off = $fo + ($va - $vm);
        seek($fh, $off, 0) or die "seek: $!\n";
        my $buf;
        read($fh, $buf, $n) == $n or die "读 $n 字节失败（va=0x" . sprintf('%x', $va) . "）\n";
        return $buf;
    }
    die "地址不在文件承载区: 0x" . sprintf('%x', $va) . " ($n)\n";
}

sub u64 { unpack('Q<', rd($_[0], 8)) }
sub u32 { unpack('V',  rd($_[0], 4)) }

my $header = hex($a{va});
my $magic = u64($header + 0x10);
die "hashstore 魔数不符（0x" . sprintf('%x', $magic) . "）\n" unless $magic == 0x68617368;
my $count = u64($header + 0x20);
my $array = u64($header + 0x28);
die "hashstore 记录数 $count 与预期 $a{expect} 不符\n" unless $count == $a{expect};

my %seen;
for (my $i = 0; $i < $count; $i++) {
    my $entry = u64($array + $i * 8);
    my $key_blob = u64($entry);
    my $value    = u64($entry + 8);
    my $blob     = u64($value);
    my $flags    = u32($value + 8);
    my $length   = u32($value + 12);
    my $aux      = u64($value + 16);
    die "摘要块长度不是 32\n" if u32($key_blob) != 32 || u32($blob) != 32;
    my $key = rd($key_blob + 4, 32);
    die "文件名键重复\n" if $seen{$key}++;
    printf "%s\t%016x\t%016x\t%016x\t%d\t%d\t%016x\t%s\n", unpack('H*', $key), $entry,
        $value, $blob, $flags, $length, $aux, unpack('H*', rd($blob + 4, 32));
}
