#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';

need_root_and_prepare();

my $name = 'srpm-bootstrapping';

urpmi_addmedia("$name $::pwd/media/$name");
test("media/SRPMS-$name/$name-*.src.rpm");

urpmi_addmedia("$name-src $::pwd/media/SRPMS-$name");
test("--src $name");

sub test {
    my ($para) = @_;

    urpmi("--auto $para");
    check_installed_names($name); # check the buildrequires is installed

    install_src_rpm($para);
    check_installed_and_remove($name);
}

sub install_src_rpm {
    my ($para) = @_;
    
    system_('mkdir -p root/usr/src/rpm/SOURCES');

    $ENV{HOME} = '/';
    urpmi("--install-src $para");

    system_("cmp root/usr/src/rpm/SPECS/$name.spec data/SPECS/$name.spec");
    system_('rm -rf root/usr/src/rpm');
}
