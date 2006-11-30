#!/usr/bin/perl

use strict;
use warnings;
use Test::More 'no_plan';

chdir 't' if -d 't';
system('rm -rf BUILD RPMS media');
for (qw(media BUILD RPMS RPMS/noarch)) {
    mkdir $_;
}
# locally build a test rpms
foreach my $spec (glob("SPECS/*.spec")) {
    system_("rpmbuild --quiet --define '_topdir .' -bb --clean $spec");
    my ($name) = $spec =~ m!([^/]*)\.spec$!;
    mkdir "media/$name";
    system_("mv RPMS/*/*.rpm media/$name");
}

sub system_ {
    my ($cmd) = @_;
    system($cmd);
    ok($? == 0, $cmd);
}
