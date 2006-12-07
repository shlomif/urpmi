#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';
BEGIN { use_ok 'urpm::cfg' }

need_root_and_prepare();

my $name = 'various';

my @fields = qw(hdlist synthesis with_hdlist media_info_dir virtual);

try_medium('', { media_info_dir => 'media_info' });

try_medium('--probe-hdlist', 
    { hdlist => 1, media_info_dir => 'media_info' });
try_medium('with media_info/hdlist.cz', 
    { hdlist => 1, media_info_dir => 'media_info' });
try_medium("with ../media_info/hdlist_$name.cz", 
    { hdlist => 1, with_hdlist => "../media_info/hdlist_$name.cz" });

try_medium('--probe-synthesis', 
    { synthesis => 1, media_info_dir => 'media_info' });
try_medium('with media_info/synthesis.hdlist.cz', 
    { synthesis => 1, media_info_dir => 'media_info' });
try_medium("with ../media_info/synthesis.hdlist_$name.cz", 
    { synthesis => 1, with_hdlist => "../media_info/synthesis.hdlist_$name.cz" });

sub try_medium {
    my ($options, $want) = @_;
    urpmi_addmedia("$name $::pwd/media/$name $options");
    try_($want);
    urpmi_removemedia($name);
    urpmi_addmedia("$name $::pwd/media/$name --virtual $options");
    try_({ virtual => 1, %$want });
    urpmi_removemedia($name);
}

sub try_ {
    my ($want) = @_;
    my $config = urpm::cfg::load_config("root/etc/urpmi/urpmi.cfg");
    my ($medium) = @{$config->{media}};
    ok($medium);
    foreach my $field (@fields) {
	is($medium->{$field}, $want->{$field}, $field);
    }
    urpmi($name);
    is(`rpm -qa --root $::pwd/root`, "$name-1-1\n");
    urpme($name);
}
