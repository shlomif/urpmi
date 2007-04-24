#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';
BEGIN { use_ok 'urpm::cfg' }

need_root_and_prepare();

my $name = 'various';
my $name2 = 'various2';
my $name3 = 'various3';

my @fields = qw(hdlist synthesis with_hdlist media_info_dir list virtual ignore);

try_medium({ media_info_dir => 'media_info' }, '');


try_medium_({ list => 'list.various' }, { list => 'list.various2' }, 
	    '--probe-rpms', '--probe-rpms');


try_medium({ hdlist => 1, media_info_dir => 'media_info' },
	   '--probe-hdlist');
try_medium({ hdlist => 1, media_info_dir => 'media_info' },
	   'with media_info/hdlist.cz');
try_medium({ hdlist => 1, 
	     with_hdlist => "../media_info/hdlist_$name.cz",
	     with_hdlist2 => "../media_info/hdlist_$name2.cz" },
	   "with ../media_info/hdlist_$name.cz",
	   "with ../media_info/hdlist_$name2.cz",
       );

try_medium({ synthesis => 1, media_info_dir => 'media_info' },
	   '--probe-synthesis');
try_medium({ synthesis => 1, media_info_dir => 'media_info' },
	   'with media_info/synthesis.hdlist.cz');
try_medium({ synthesis => 1, 
	     with_hdlist => "../media_info/synthesis.hdlist_$name.cz",
	     with_hdlist2 => "../media_info/synthesis.hdlist_$name2.cz" },
	   "with ../media_info/synthesis.hdlist_$name.cz",
	   "with ../media_info/synthesis.hdlist_$name2.cz");

try_distrib({ hdlist => 1,
	      with_hdlist => "../..//media/media_info/hdlist_$name.cz",
	      with_hdlist2 => "../..//media/media_info/hdlist_$name2.cz",
	      with_hdlist3 => "../..//media/media_info/hdlist_$name3.cz" }, 
	    '');
try_distrib({ hdlist => 1,
	      with_hdlist => "../..//media/media_info/hdlist_$name.cz",
	      with_hdlist2 => "../..//media/media_info/hdlist_$name2.cz",
	      with_hdlist3 => "../..//media/media_info/hdlist_$name3.cz" }, 
	    '--probe-hdlist');
try_distrib({ synthesis => 1,
	      with_hdlist => "../..//media/media_info/synthesis.hdlist_$name.cz",
	      with_hdlist2 => "../..//media/media_info/synthesis.hdlist_$name2.cz",
	      with_hdlist3 => "../..//media/media_info/synthesis.hdlist_$name3.cz" }, 
	    '--probe-synthesis');


sub try_medium {
    my ($want, $options, $o_options2) = @_;
    my $want2 = { %$want, with_hdlist => $want->{with_hdlist2} || $want->{with_hdlist} };

    try_medium_($want, $want2, $options, ($o_options2 || $options));

    $want2->{virtual} = $want->{virtual} = 1;
    try_medium_($want, $want2, '--virtual ' . $options, '--virtual ' . ($o_options2 || $options));
}

sub try_distrib {
    my ($want, $options) = @_;
    my $want2 = { %$want, with_hdlist => $want->{with_hdlist2} || $want->{with_hdlist} };
    my $want3 = { %$want, with_hdlist => $want->{with_hdlist3} || $want->{with_hdlist}, ignore => 1 };

    try_distrib_($want, $want2, $want3, $options);

    $want3->{virtual} = $want2->{virtual} = $want->{virtual} = 1;
    try_distrib_($want, $want2, $want3, '--virtual ' . $options);
}

sub try_medium_ {
    my ($want, $want2, $options, $options2) = @_;

    urpmi_addmedia("$name $::pwd/media/$name $options");
    check_conf($want);
    check_urpmi($name);
    {
	urpmi_addmedia("$name2 $::pwd/media/$name2 $options2");
	check_conf($want, $want2);
	check_urpmi($name, $name2);
	urpmi_removemedia($name2);
    }
    urpmi_removemedia($name);
}

sub try_distrib_ {
    my ($want, $want2, $want3, $options) = @_;

    urpmi_addmedia("--distrib $name $::pwd $options");
    check_conf($want, $want2, $want3);
    check_urpmi($name, $name2);
    urpmi_removemedia('-a');
}

sub check_conf {
    my (@want) = @_;
    my $config = urpm::cfg::load_config("root/etc/urpmi/urpmi.cfg");
    is(int(@{$config->{media}}), int(@want));
    foreach my $i (0 .. $#want) {
	my ($medium, $want) = ($config->{media}[$i], $want[$i]);
	foreach my $field (@fields) {
	    is($medium->{$field}, $want->{$field}, $field);
	}
    }
}
sub check_urpmi {
    my (@names) = @_;
    urpmi(join(' ', @names));
    is(`rpm -qa --root $::pwd/root | sort`, join('', map { "$_-1-1\n" } @names));
    urpme(join(' ', @names));
}
