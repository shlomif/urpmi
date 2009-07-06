#!/usr/bin/perl
#
# testcase for bug #50666
#
# b-1 requires c
# b-2 requires c
# c-1 requires a-1
# c-2 requires d
# d does not exist
#
# user has a-1, b-1, c-1 installed
# trying to upgrade a has to remove b, c
#
use strict;
use lib '.', 't';
use helper;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'failing-promotion';
urpmi_addmedia("$name $::pwd/media/$name");

urpmi("--auto a-1 c-1 b-1");
check_installed_fullnames("a-1-1", "c-1-1", "b-1-1");
urpmi("--auto a");
check_installed_fullnames("a-2-1");

