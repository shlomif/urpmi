#!/usr/bin/perl

# package "a" is split into "b" and "c",
# where "b" obsoletes/provides "a" and requires "c"
#       "c" conflicts with "a" (but can't obsolete it)
#
# package "d" requires "a"

use strict;
use lib '.', 't';
use helper;
use Expect;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'obsolete-and-conflict';
urpmi_addmedia("$name $::pwd/media/$name");    

urpmi('a');
check_installed_names('a');

urpmi('b c');
check_installed_names('b', 'c');

urpme('b c');

urpmi('a d');
check_installed_names('a', 'd');
urpmi('b c');
check_installed_names('b', 'c', 'd');

urpme('b c d');

urpmi('a d');
check_installed_names('a', 'd');
urpmi('--split-level 1 b c');
# argh, d is removed :-(
#check_installed_names('b', 'c', 'd');
