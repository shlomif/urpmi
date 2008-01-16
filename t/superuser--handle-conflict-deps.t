#!/usr/bin/perl

# b requires b-sub
# a-sup requires a
# a conflicts with b, b conflicts with a
use strict;
use lib '.', 't';
use helper;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'handle-conflict-deps';
urpmi_addmedia("$name $::pwd/media/$name");    

test_conflict_on_install();
test_conflict_on_upgrade(); #test from bugs #12696, #11885

sub test_conflict_on_upgrade {
    urpmi('--auto a-sup');
    check_installed_names('a', 'a-sup');

    urpmi('--auto b');
    check_installed_and_remove('b', 'b-sub');
}

sub test_conflict_on_install {
    urpmi('--auto a b');
    check_installed_and_remove('b', 'b-sub'); # WARNING: why does it choose one or the other?
}
