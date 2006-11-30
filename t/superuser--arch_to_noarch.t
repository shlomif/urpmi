#!/usr/bin/perl

use strict;
use Test::More 'no_plan';

chdir 't' if -d 't';
require './helper.pm';

helper::need_root_and_prepare();

my $name = 'arch_to_noarch';

foreach my $nb (1 .. 4) {
    my $medium_name = "${name}_$nb";
    helper::urpmi_addmedia("$medium_name $::pwd/media/$medium_name");
    helper::urpmi("$name");
    is(`rpm -qa --root $::pwd/root`, "$name-$nb-1\n");
}
