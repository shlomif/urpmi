package urpm::util;

# $Id$

use strict;
use Exporter;
our @ISA = 'Exporter';
our @EXPORT = qw(quotespace unquotespace
    remove_internal_name
    reduce_pathname offset_pathname
    md5sum untaint
    difference2 member file_size cat_ dirname basename
);

(our $VERSION) = q($Revision$) =~ /(\d+)/;

#- quoting/unquoting a string that may be containing space chars.
sub quotespace		 { my $x = $_[0] || ''; $x =~ s/(\s)/\\$1/g; $x }
sub unquotespace	 { my $x = $_[0] || ''; $x =~ s/\\(\s)/$1/g; $x }
sub remove_internal_name { my $x = $_[0] || ''; $x =~ s/\(\S+\)$/$1/g; $x }

sub dirname { local $_ = shift; s|[^/]*/*\s*$||; s|(.)/*$|$1|; $_ || '.' }
sub basename { local $_ = shift; s|/*\s*$||; s|.*/||; $_ }

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

sub untaint {
    my @r = map { /(.*)/ } @_;
    @r == 1 ? $r[0] : @r;
}

sub md5sum {
    my ($file) = @_;
    eval { require Digest::MD5 };
    if ($@) {
	#- Use an external command to avoid depending on perl
	return (split ' ', `/usr/bin/md5sum '$file'`)[0];
    } else {
	my $ctx = Digest::MD5->new;
	open my $fh, $file or return '';
	$ctx->addfile($fh);
	close $fh;
	return $ctx->hexdigest;
    }
}

sub copy {
    my ($file, $dest) = @_;
    !system("/bin/cp", "-p", "-L", "-R", $file, $dest);
}

sub move {
    my ($file, $dest) = @_;
    rename($file, $dest) || !system("/bin/mv", "-f", $file, $dest);
}

#- file_size is useful to write file_size(...) > 32 without having warnings if file doesn't exist
sub file_size {
    my ($file) = @_;
    -s $file || 0;
}

sub difference2 { my %l; @l{@{$_[1]}} = (); grep { !exists $l{$_} } @{$_[0]} }
sub member { my $e = shift; foreach (@_) { $e eq $_ and return 1 } 0 }
sub cat_ { my @l = map { my $F; open($F, '<', $_) ? <$F> : () } @_; wantarray() ? @l : join '', @l }

1;

__END__

=head1 NAME

urpm::util - Misc. utilities subs for urpmi

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 COPYRIGHT

Copyright (C) 2005 MandrakeSoft SA

Copyright (C) 2005, 2006 Mandriva SA

=cut
