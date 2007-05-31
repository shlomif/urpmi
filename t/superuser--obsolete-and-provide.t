#!/usr/bin/perl

use strict;
use lib '.', 't';
use helper;
use Test::More 'no_plan';

my $medium_name = 'obsolete-and-provide';

need_root_and_prepare();

urpmi_addmedia("$medium_name $::pwd/media/$medium_name");

test(sub { urpmi('a'); check_installed_fullnames("a-2-1"); urpme('a') });
test(sub { urpmi('b'); check_installed_fullnames("a-1-1", "b-3-1"); urpme('a b') });

#- the following test fail. "urpmi --auto-select" should do the same as "urpmi a"
#test(sub { urpmi('--auto-select'); check_installed_fullnames("a-2-1"); urpme('a') });

sub test {
    my ($f) = @_;
    system_("rpm --root $::pwd/root -i media/$medium_name/a-1-*.rpm");
    is(`rpm -qa --root $::pwd/root`, "a-1-1\n");

    $f->();
    check_nothing_installed();
}
