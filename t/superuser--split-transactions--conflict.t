#!/usr/bin/perl

# a requires b
# b-1 requires c
# b-2 requires d
# d conflicts with c
#
use strict;
use lib '.', 't';
use helper;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'split-transactions--conflict';
urpmi_addmedia("$name-1 $::pwd/media/$name-1");    
urpmi_addmedia("$name-2 $::pwd/media/$name-2");

test('--split-length 0');
test('--split-level 1');

sub test {
    my ($option) = @_;

    urpmi("--media $name-1 --auto a b c");
    check_installed_fullnames('a-1-1', 'b-1-1', 'c-1-1');

    urpmi("--media $name-2 $option --auto --auto-select");
    check_installed_fullnames_and_remove('a-1-1', 'b-2-1', 'd-1-1');
}
