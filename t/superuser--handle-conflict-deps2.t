#!/usr/bin/perl

# a1-1 upgrades to a1-2
# b-1 upgrades to b-2 which requires a2
# a2 conflicts with a1
#
# d1-1 upgrades to d1-2
# c-1 upgrades to c-2 which requires d2
# d2 conflicts with d1
#
# nb: d & c is similar to a & b
# (needed to ensure both ordering works)
#
use strict;
use lib '.', 't';
use helper;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'handle-conflict-deps2';
urpmi_addmedia("$name $::pwd/media/$name");    

# TODO: it should be an error since the wanted pkgs can't be fulfilled
test(['d1-1', 'c-1'], ['c-2', 'd1-2'], ['c-2', 'd2-2']);

#test(['a1-1', 'b-1'], ['b-2', 'a1-2'], ['b-2', 'a2-2']);


sub test {
    my ($first, $wanted, $result) = @_;

    urpmi("--auto @$first");
    check_installed_fullnames(map { "$_-1" } @$first);

    urpmi("--auto @$wanted");
    check_installed_fullnames(map { "$_-1" } @$result);
}
