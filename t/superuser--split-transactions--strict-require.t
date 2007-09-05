#!/usr/bin/perl

# a-1 requires b-1
# a-2 requires b-2
#
use strict;
use lib '.', 't';
use helper;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'split-transactions--strict-require';
urpmi_addmedia("$name-1 $::pwd/media/$name-1");    
urpmi_addmedia("$name-2 $::pwd/media/$name-2");

test('--split-length 0 b');
test('--split-level 1 b');

test('--split-length 0 --auto-select');
test('--split-level 1 --auto-select');

sub test {
    my ($para) = @_;

    urpmi("--media $name-1 --auto a b");
    check_installed_names('a', 'b');

    urpmi("--media $name-2 --auto $para");
    check_installed_fullnames_and_remove('a-2-1', 'b-2-1');
}
