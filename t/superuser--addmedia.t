#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';
BEGIN { use_ok 'urpm::cfg' }

need_root_and_prepare();

my $name = 'various';
my $name2 = 'various2';

my @fields = qw(hdlist synthesis with_hdlist media_info_dir virtual);

try_medium({ media_info_dir => 'media_info' }, '');


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

sub try_medium {
    my ($want, $options, $o_options2) = @_;
    my $want2 = { %$want, with_hdlist => $want->{with_hdlist2} || $want->{with_hdlist} };

    try_medium_($want, $want2, $options, ($o_options2 || $options));

    $want2->{virtual} = $want->{virtual} = 1;
    try_medium_($want, $want2, '--virtual ' . $options, '--virtual ' . ($o_options2 || $options));
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
