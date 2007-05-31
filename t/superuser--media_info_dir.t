#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';


need_root_and_prepare();
various();
rpm_v3();

sub various {
    my $name = 'various';
    foreach my $medium_name ('various', 'various_nohdlist', 'various nohdlist', 'various_no_subdir') {
	urpmi_addmedia("'$medium_name' '$::pwd/media/$medium_name'");
	urpmi($name);
	is(`rpm -qa --root $::pwd/root`, "$name-1-1\n");
	urpme($name);
	urpmi_removemedia("'$medium_name'");
    }
}

sub rpm_v3 {
    my @names = qw(libtermcap nls p2c);

    system_("rpm --root $::pwd/root -i --noscripts media/rpm-v3/*.rpm");
    check_installed_names(@names);
    system_("rpm --root $::pwd/root -e --noscripts " . join(' ', @names));
    is(`rpm -qa --root $::pwd/root`, '');    

    foreach my $medium_name ('rpm-v3', 'rpm-v3_nohdlist', 'rpm-v3_no_subdir') {
	urpmi_addmedia("$medium_name $::pwd/media/$medium_name");
	urpmi('--no-verify-rpm --noscripts ' . join(' ', @names));
	check_installed_names(@names);
	urpme('-a --auto --noscripts');
	is(`rpm -qa --root $::pwd/root`, '');    
	urpmi_removemedia($medium_name);
    }
}