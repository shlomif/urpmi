#!/usr/bin/perl

# a-1 requires b-1
# a-2 requires b-2
#
# c requires d
# d1-1 provides d, but not d1-2
# d2-2 provides d, but not d2-1
use strict;
use lib '.', 't';
use helper;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'split-transactions--strict-require';
urpmi_addmedia("$name-1 $::pwd/media/$name-1");    
urpmi_addmedia("$name-2 $::pwd/media/$name-2");

#- below need the promotion of "a-2" (upgraded from "a-1") to work
test_ab('--split-length 0 b');
test_ab('--split-level 1 b');

test_ab('--split-length 0 --auto-select');
test_ab('--split-level 1 --auto-select');

#- below need the promotion of "d2" (new installed package) to work
test_cd('--split-length 0 d1');
test_cd('--split-level 1 d1');

sub test_ab {
    my ($para) = @_;

    urpmi("--media $name-1 --auto a b");
    check_installed_names('a', 'b');

    urpmi("--media $name-2 --auto $para");
    check_installed_fullnames_and_remove('a-2-1', 'b-2-1');
}

sub test_cd {
    my ($para) = @_;

    urpmi("--media $name-1 --auto c");
    check_installed_names('c', 'd1');

    urpmi("--media $name-2 --auto $para");
    check_installed_fullnames_and_remove('c-1-1', 'd1-2-1', 'd2-2-1');
}
