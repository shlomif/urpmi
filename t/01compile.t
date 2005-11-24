#!/usr/bin/perl

use strict;
use warnings;
no warnings 'redefine';
use Test::More tests => 10;

for my $module (glob("urpm/*.pm")) {
    $module =~ s,/,::,g;
    $module =~ s,\.pm$,,;
    use_ok $module;
}
