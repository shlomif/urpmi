#!/usr/bin/perl

use Test::More 'no_plan';
use File::Slurp;

BEGIN { use_ok 'urpm::cfg' }
BEGIN { use_ok 'urpm::download' }

my $file = 'testurpmi.cfg';
my $proxyfile = $urpm::download::PROXY_CFG = 'testproxy.cfg';
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

my $cfgtext2 = read_file($file.2);
$cfgtext2 =~ s/# generated.*\n//;
is( $cfgtext, $cfgtext2, 'config is the same' )
    or system qw( diff -u ), $file, $file.2;

open $f, '>', $proxyfile or die $!;
print $f ($cfgtext = <<PROXYCFG);
http_proxy=http://foo:8080/
local:http_proxy=http://yoyodyne:8080/
local:proxy_user=rafael:richard
PROXYCFG
close $f;

my $p = get_proxy();
is( $p->{http_proxy}, 'http://foo:8080/', 'read proxy' );
ok( !defined $p->{user}, 'no user defined' );
$p = get_proxy('local');
is( $p->{http_proxy}, 'http://yoyodyne:8080/', 'read media proxy' );
is( $p->{user}, 'rafael', 'proxy user' );
is( $p->{pwd}, 'richard', 'proxy password' );
ok( dump_proxy_config(), 'dump_proxy_config' );
$cfgtext2 = read_file($proxyfile);
$cfgtext2 =~ s/# generated.*\n//;
is( $cfgtext, $cfgtext2, 'dumped correctly' );
set_proxy_config(http_proxy => '');
ok( dump_proxy_config(), 'dump_proxy_config erased' );
$cfgtext2 = read_file($proxyfile);
$cfgtext2 =~ s/# generated.*\n//;
$cfgtext =~ s/^http_proxy.*\n//;
is( $cfgtext, $cfgtext2, 'dumped correctly' );

END { unlink $file, $file.2, $proxyfile }
