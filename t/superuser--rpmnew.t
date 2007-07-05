#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';

my $medium_name = 'rpmnew';

my @names = ('config-noreplace', 'config', 'normal');

need_root_and_prepare();

urpmi_addmedia("$medium_name $::pwd/media/$medium_name");

test(['orig', 'orig', 'orig'],
     ['orig', 'orig', 'orig'],
     ['changed', 'changed', 'changed']);

system("echo foo > $::pwd/root/etc/$_") foreach @names;

test(['foo', 'foo', 'orig'],
     ['foo', 'foo', 'orig'],
     ['foo', 'foo', 'changed']);

sub check_content {
    my ($rpm, $config_noreplace, $config, $normal) = @_;

    check_one_content($rpm, 'config-noreplace', $config_noreplace);
    check_one_content($rpm, 'config', $config);
    check_one_content($rpm, 'normal', $normal);
}

sub check_one_content {
    my ($rpm, $name, $val) = @_;
    my $s = `cat $::pwd/root/etc/$name`;
    chomp $s;
    is($s, $val, "$name for $rpm");
}

sub test {
    my ($v1, $v2, $v3) = @_;

    system_("rpm --root $::pwd/root -i media/$medium_name/a-1-*.rpm");
    is(`rpm -qa --root $::pwd/root`, "a-1-1\n");
    check_content('a-1', @$v1);

    system_("rpm --root $::pwd/root -U media/$medium_name/a-2-*.rpm");
    is(`rpm -qa --root $::pwd/root`, "a-2-1\n");
    check_content('a-2', @$v2);

    system_("rpm --root $::pwd/root -U media/$medium_name/a-3-*.rpm");
    is(`rpm -qa --root $::pwd/root`, "a-3-1\n");
    check_content('a-3', @$v3);

    system_("rpm --root $::pwd/root -e a");
}
