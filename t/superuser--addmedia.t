#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';
BEGIN { use_ok 'urpm::cfg' }

need_root_and_prepare();

my $name = 'various';

try('', { hdlist => undef, synthesis => undef });
try('--probe-hdlist', { hdlist => "hdlist.$name.cz", synthesis => undef });
try('--probe-synthesis', { hdlist => undef, synthesis => 1 });

sub try {
    my ($options, $want) = @_;
    urpmi_addmedia("$name $::pwd/media/$name $options");
    my $config = urpm::cfg::load_config("root/etc/urpmi/urpmi.cfg");
    my ($medium) = @{$config->{media}};
    ok($medium);
    foreach my $field (keys %$want) {
	is($medium->{$field}, $want->{$field});
    }
    urpmi_removemedia($name);
}
