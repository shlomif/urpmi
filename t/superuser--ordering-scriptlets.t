#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';

my $medium_name = 'ordering-scriptlets';

need_root_and_prepare();

my $ash_1 = "media/$medium_name/ordering_ash-1-*.rpm";
my $ash_2 = "media/$medium_name/ordering_ash-2-*.rpm";

test_install_remove_rpm("requires_$_") foreach qw(pre post preun postun);
test_install_upgrade_rpm("requires_$_") foreach qw(preun postun);

test_install_remove_urpmi("requires_$_", '') foreach qw(pre post preun postun);
test_install_upgrade_urpmi("requires_$_", '') foreach qw(preun postun);

test_install_remove_urpmi("requires_$_", '--split-level 1') foreach qw(pre post preun postun);
test_install_upgrade_urpmi("requires_$_", '--split-level 1') foreach qw(preun postun);

sub test_install_remove_rpm {
    my ($name) = @_;

    system_("rpm --root $::pwd/root -i $ash_1 media/$medium_name/$name-1-*.rpm");
    check_installed_and_remove('ordering_ash', $name);

    system_("rpm --root $::pwd/root -i media/$medium_name/$name-1-*.rpm $ash_1");
    check_installed_and_remove($name, 'ordering_ash');
}

sub test_install_upgrade_rpm {
    my ($name) = @_;

    system_("rpm --root $::pwd/root -i $ash_1 media/$medium_name/$name-1-*.rpm");
    system_("rpm --root $::pwd/root -U media/$medium_name/$name-2-*.rpm $ash_2");
    check_installed_and_remove('ordering_ash', $name);


    system_("rpm --root $::pwd/root -i media/$medium_name/$name-1-*.rpm $ash_1");
    system_("rpm --root $::pwd/root -U $ash_2 media/$medium_name/$name-2-*.rpm");
    check_installed_and_remove($name, 'ordering_ash');
}

sub test_install_remove_urpmi {
    my ($name, $urpmi_option) = @_;
    my @names = ('ordering_ash', $name);
    my @names_rev = reverse @names;

    urpmi_addmedia("$medium_name $::pwd/media/$medium_name");

    urpmi(join(' ', $urpmi_option, @names));
    check_installed_and_urpme(@names);

    urpmi(join(' ', $urpmi_option, @names_rev));
    check_installed_and_urpme(@names_rev);

    urpmi_removemedia('-a');
}

sub test_install_upgrade_urpmi {
    my ($name, $urpmi_option) = @_;
    my @names = ('ordering_ash', $name);
    my @names_rev = reverse @names;

    urpmi_addmedia("$medium_name $::pwd/media/$medium_name");

    system_("rpm --root $::pwd/root -i $ash_1 media/$medium_name/$name-1-*.rpm");
    urpmi(join(' ', $urpmi_option, @names));
    check_installed_and_urpme(@names);

    system_("rpm --root $::pwd/root -i $ash_1 media/$medium_name/$name-1-*.rpm");
    urpmi(join(' ', $urpmi_option, @names_rev));
    check_installed_and_urpme(@names_rev);

    urpmi_removemedia('-a');
}
