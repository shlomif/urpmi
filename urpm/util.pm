package urpm::util;

use strict;
use Exporter;
our @ISA = 'Exporter';
our @EXPORT = qw(quotespace unquotespace
    remove_internal_name
    reduce_pathname offset_pathname);

#- quoting/unquoting a string that may be containing space chars.
sub quotespace		 { my $x = $_[0] || ''; $x =~ s/(\s)/\\$1/g; $x }
sub unquotespace	 { my $x = $_[0] || ''; $x =~ s/\\(\s)/$1/g; $x }
sub remove_internal_name { my $x = $_[0] || ''; $x =~ s/\(\S+\)$/$1/g; $x }

#- reduce pathname by removing <something>/.. each time it appears (or . too).
sub reduce_pathname {
    my ($url) = @_;

    #- clean url to remove any macro (which cannot be solved now).
    #- take care if this is a true url and not a simple pathname.
    my ($host, $dir) = $url =~ m|([^:/]*://[^/]*/)?(.*)|;
    $host = '' if !defined $host;

    #- remove any multiple /s or trailing /.
    #- then split all components of pathname.
    $dir =~ s|/+|/|g; $dir =~ s|/$||;
    my @paths = split '/', $dir;

    #- reset $dir, recompose it, and clean trailing / added by algorithm.
    $dir = '';
    foreach (@paths) {
	if ($_ eq '..') {
	    if ($dir =~ s|([^/]+)/$||) {
		if ($1 eq '..') {
		    $dir .= "../../";
		}
	    } else {
		$dir .= "../";
	    }
	} elsif ($_ ne '.') {
	    $dir .= "$_/";
	}
    }
    $dir =~ s|/$||;
    $dir ||= '/';

    $host . $dir;
}

#- offset pathname by returning the right things to add to a relative directory
#- to make no change. url is needed to resolve going before to top base.
sub offset_pathname {
    my ($url, $offset) = map { reduce_pathname($_) } @_;

    #- clean url to remove any macro (which cannot be solved now).
    #- take care if this is a true url and not a simple pathname.
    my (undef, $dir) = $url =~ m|([^:/]*://[^/]*/)?(.*)|;
    my @paths = split '/', $dir;
    my @offpaths = reverse split '/', $offset;
    my @corrections;
    my $result = '';

    foreach (@offpaths) {
	if ($_ eq '..') {
	    push @corrections, pop @paths;
	} else {
	    $result .= '../';
	}
    }
    $result . join('/', reverse @corrections);
}

1;

__END__
