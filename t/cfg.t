#!/usr/bin/perl

use Test::More tests => 4;
use MDK::Common;

BEGIN { use_ok 'urpm::cfg' }

my $file = 'testurpmi.cfg';
open my $f, '>', $file or die $!;
print $f (my $cfgtext = <<URPMICFG);
{
  downloader: wget
  fuzzy: no
  verify-rpm: 0
}

update\\ 1 http://foo/bar/ {
  compress: 1
  fuzzy: 1
  keep: yes
  key-ids: "123"
  update
  verify-rpm: yes
}

update_2 ftp://foo/bar/ {
  hdlist: hdlist.update2.cz
  ignore
  key_ids: 456 789
  priority-upgrade: 'kernel'
  synthesis
  with_hdlist: hdlist.update2.cz
}

URPMICFG
close $f;

my $config = urpm::cfg::load_config($file);
ok( ref $config, 'config loaded' );

ok( urpm::cfg::dump_config($file.2, $config), 'config written' );

# things that have been tidied up by dump_config
$cfgtext =~ s/\byes\b/1/g;
$cfgtext =~ s/\bno\b/0/g;
$cfgtext =~ s/\bkey_ids\b/key-ids/g;
$cfgtext =~ s/"123"/123/g;
$cfgtext =~ s/'kernel'/kernel/g;

my $cfgtext2 = cat_($file.2);
$cfgtext2 =~ s/# generated.*\n//;
is( $cfgtext, $cfgtext2, 'config is the same' )
    or system qw( diff -u ), $file, $file.2;

END { unlink $file, $file.2 }
