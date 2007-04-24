#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'srpm-bootstrapping';

urpmi_addmedia("$name $::pwd/media/$name");
urpmi("--auto media/SRPMS-$name/$name-*.src.rpm");
is(`rpm -qa --root $::pwd/root`, "$name-1-1\n");
