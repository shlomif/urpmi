#!/usr/bin/perl

# test from bugs #12696, #11885

use strict;
use lib '.', 't';
use helper;
use Expect;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'handle-conflict-deps';
urpmi_addmedia("$name $::pwd/media/$name");    

urpmi('--auto a-sup');
check_installed_names('a', 'a-sup');

urpmi('--auto b');
check_installed_names('b', 'b-sub');
