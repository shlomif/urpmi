#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';


need_root_and_prepare();

my $name = 'various';

foreach my $medium_name ('various', 'various_nohdlist', 'various_no_subdir') {
    urpmi_addmedia("$medium_name $::pwd/media/$medium_name");
    urpmi($name);
    is(`rpm -qa --root $::pwd/root`, "$name-1-1\n");
    urpme($name);
    urpmi_removemedia($medium_name);
}
