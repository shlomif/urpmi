#!/usr/bin/perl

# package "a" is split into "b" and "c",
# where "b" obsoletes "a" and requires "c"
#       "c" conflicts with "a" (but can't obsolete it)

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
