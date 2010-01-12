#!/usr/bin/perl

# "a" provides "should-restart = system"
# "c" provides "should-restart = system"
#
use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';

need_root_and_prepare();

my $medium_name = 'should-restart';

urpmi_addmedia("$medium_name $::pwd/media/$medium_name");

test_urpmi('a', 'You should restart your computer for a');
test_urpmi('b', '');
test_urpmi('c', 'You should restart your computer for a, c');

sub test_urpmi {
    my ($para, $wanted) = @_;
    my $s = run_urpm_cmd("urpmi $para");
    print $s;

    my $msg = $s =~ /^(You should restart .*)/m ? $1 : '';

    ok($msg eq $wanted, "wanted:$wanted, got:$msg");
}
