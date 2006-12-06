#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';
BEGIN { use_ok 'urpm::cfg' }

need_root_and_prepare();

my $name = 'various';

my @fields = qw(hdlist synthesis with_hdlist media_info_dir);
try('', { media_info_dir => 'media_info' });

try('--probe-hdlist', 
    { hdlist => "hdlist.$name.cz", media_info_dir => 'media_info' });
try('with media_info/hdlist.cz', 
    { hdlist => "hdlist.$name.cz", media_info_dir => 'media_info' });
try("with ../media_info/hdlist_$name.cz", 
    { hdlist => "hdlist.$name.cz", with_hdlist => "../media_info/hdlist_$name.cz" });

try('--probe-synthesis', 
    { synthesis => 1, media_info_dir => 'media_info' });
try('with media_info/synthesis.hdlist.cz', 
    { synthesis => 1, media_info_dir => 'media_info' });
try("with ../media_info/synthesis.hdlist_$name.cz", 
    { synthesis => 1, with_hdlist => "../media_info/synthesis.hdlist_$name.cz" });

sub try {
    my ($options, $want) = @_;
    urpmi_addmedia("$name $::pwd/media/$name $options");
    my $config = urpm::cfg::load_config("root/etc/urpmi/urpmi.cfg");
    my ($medium) = @{$config->{media}};
    ok($medium);
    foreach my $field (@fields) {
	is($medium->{$field}, $want->{$field}, $field);
    }
    urpmi($name);
    is(`rpm -qa --root $::pwd/root`, "$name-1-1\n");
    urpme($name);
    urpmi_removemedia($name);
}
