#!/usr/bin/env perl

my $version = "";
while (<>) {
    if (/x\(\S+,\s+BCH_VERSION\((\d+), (\d+)\)\)/) {
        $version = "$1.$2";
    }
}
if ($version) {
    print "$version\n";
    exit 0;
} else {
    exit 1;
}
