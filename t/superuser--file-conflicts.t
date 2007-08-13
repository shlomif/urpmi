#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Expect;
use urpm::util;
use Test::More 'no_plan';

need_root_and_prepare();

my $medium_name = 'file-conflicts';

urpmi_addmedia("$medium_name $::pwd/media/$medium_name");


test_rpm_same_transaction();
test_rpm_different_transactions();

test_urpmi_same_transaction();
test_urpmi_different_transactions();

sub test_rpm_same_transaction {
    # disabled, fail (#32528)
    #test_rpm_i_fail('a', 'b');
    #check_nothing_installed();

    test_rpm_i_succeeds('a', 'c');
    check_installed_and_remove('a', 'c');

    test_rpm_i_succeeds('a', 'd');
    check_installed_and_remove('a', 'd');
}

sub test_rpm_different_transactions {
    test_rpm_i_succeeds('a');
    test_rpm_i_fail('b');
    check_installed_names('a');

    test_rpm_i_succeeds('c');
    check_installed_and_remove('a', 'c');

    test_rpm_i_succeeds('a');
    test_rpm_i_succeeds('d');
    check_installed_and_remove('a', 'd');
}

sub test_urpmi_same_transaction {
    # disabled, fail (#32528)
    #test_urpmi_fail('a', 'b');
    #check_nothing_installed();

    urpmi('a c');
    check_installed_and_remove('a', 'c');

    urpmi('a d');
    check_installed_and_remove('a', 'd');
}

sub test_urpmi_different_transactions {
    urpmi('a');
    test_urpmi_fail('b');
    check_installed_names('a');

    # disabled, fail when dropping RPMTAG_FILEDIGESTS
    #urpmi('c');
    #check_installed_and_remove('a', 'c');

    #urpmi('a');
    urpmi('d');
    check_installed_and_remove('a', 'd');
}

sub test_rpm_i_succeeds {
    my (@rpms) = @_;
    my $rpms = join(' ', map { "media/$medium_name/$_-*.rpm" } @rpms);
    system_("rpm --root $::pwd/root -i $rpms");
}
sub test_rpm_i_fail {
    my (@rpms) = @_;
    my $rpms = join(' ', map { "media/$medium_name/$_-*.rpm" } @rpms);
    system_should_fail("rpm --root $::pwd/root -i $rpms");
}
sub test_urpmi_fail {
    my ($rpms) = @_;
    system_should_fail(urpmi_cmd() . " $rpms");
}
