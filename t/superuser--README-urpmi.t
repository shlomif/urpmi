#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Expect;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $medium_name = 'README-urpmi';

urpmi_addmedia("$medium_name $::pwd/media/$medium_name");

test_a();
test_b();
test_c();
test_d();

sub test_a {
    test_urpmi('a', 'installing/upgrading a');
    check_installed_and_remove('a');
}

sub test_b {
    system_("rpm --root $::pwd/root -i media/$medium_name/b-1-*.rpm");
    test_urpmi('b', 'upgrading b');
    check_installed_and_remove('b');
}

sub test_c {
    test_urpmi('c', 'installing c');
    check_installed_and_remove('c');
}

sub test_d {
    test_urpmi('d', 'installing/upgrading d');
    test_urpmi('d_', 'installing d_'); # what is the valid answer?
    check_installed_and_remove('d_');
}

sub test_urpmi {
    my ($para, $wanted) = @_;
    my $urpmi = urpmi_cmd();
    print "# $urpmi $para\n";
    my $s = `$urpmi $para`;
    print $s;
    my ($msg) = $s =~ /\nMore information on package[^\n]*\n(.*?)\n-{70}/ms;

    ok($msg eq $wanted, "wanted:$wanted, got:$msg");
}
