package urpm::cfg;

use strict;
use warnings;
use urpm::util;
use urpm::msg 'N';

=head1 NAME

urpm::cfg - routines to handle the urpmi configuration files

=head1 SYNOPSIS

=head1 DESCRIPTION

=over

=item load_config($file)

Reads an urpmi configuration file and returns its contents in a hash ref :

    {
	'medium name 1' => {
	    url => 'http://...',
	    option => 'value',
	    ...
	}
	'' => {
	    # global options go here
	},
    }

Returns undef() in case of parsing error (and sets C<$urpm::cfg::err> to the
appropriate error message.)

=item dump_config($file, $config)

Does the opposite: write the configuration file, from the same data structure.
Returns 1 on success, 0 on failure.

=cut

#- implementations of the substitutions. arch and release are mdk-specific

my ($arch, $release);
sub _init_arch_release () {
    if (!$arch && !$release) {
	open my $f, '/etc/release' or return undef;
	my $l = <$f>;
	close $f;
	($release, $arch) = $l =~ /release (\d+\.\d+).*for (\w+)/;
	$release = 'cooker' if $l =~ /cooker/i;
    }
    1;
}

sub get_arch () { _init_arch_release(); $arch }

sub get_release () { _init_arch_release(); $release }

sub get_host () {
    my $h;
    if (open my $f, '/proc/sys/kernel/hostname') {
	$h = <$f>;
	close $f;
    } else {
	$h = $ENV{HOSTNAME} || `/bin/hostname`;
    }
    chomp $h;
    $h;
}

our $err;

sub _syntax_error () { $err = N("syntax error in config file at line %s", $.) }

sub substitute_back {
    my ($new, $old) = @_;
    return $new if !defined($old);
    return $old if expand_line($old) eq $new;
    return $new;
}

my %substitutions;
sub expand_line {
    my ($line) = @_;
    unless (scalar keys %substitutions) {
	%substitutions = (
	    HOST => get_host(),
	    ARCH => get_arch(),
	    RELEASE => get_release(),
	);
    }
    foreach my $sub (keys %substitutions) {
	$line =~ s/\$$sub\b/$substitutions{$sub}/g;
    }
    return $line;
}

sub load_config ($;$) {
    my ($file, $norewrite) = @_;
    my %config;
    my $priority = 0;
    my $medium;
    $err = '';
    open my $f, $file or do { $err = N("unable to read config file [%s]", $file); return };
    local $_;
    while (<$f>) {
	chomp;
	next if /^\s*#/; #- comments
	s/^\s+//; s/\s+$//;
	$_ = expand_line($_) unless $norewrite;
	if ($_ eq '}') { #-{
	    if (!defined $medium) {
		_syntax_error();
		return;
	    }
	    $config{$medium}{priority} = $priority++; #- to preserve order
	    undef $medium;
	    next;
	}
	if (defined $medium && /{$/) { #-}
	    _syntax_error();
	    return;
	}
	if ($_ eq '{') { #-} Entering a global block
	    $medium = '';
	    next;
	}
	if (/^(.*?[^\\])\s+(?:(.*?[^\\])\s+)?{$/) { #- medium definition
	    $medium = unquotespace $1;
	    if ($config{$medium}) {
		#- hmm, somebody fudged urpmi.cfg by hand.
		$err = N("medium `%s' is defined twice, aborting", $medium);
		return;
	    }
	    $config{$medium}{url} = unquotespace $2;
	    next;
	}
	#- config values
	/^(hdlist
	  |list
	  |with_hdlist
	  |removable
	  |md5sum
	  |limit-rate
	  |excludepath
	  |split-(?:level|length)
	  |priority-upgrade
	  |prohibit-remove
	  |downloader
	  |retry
	  |(?:curl|rsync|wget)-options
	 )\s*:\s*['"]?(.*?)['"]?$/x
	    and $config{$medium}{$1} = $2, next;
	/^key[-_]ids\s*:\s*['"]?(.*?)['"]?$/
	    and $config{$medium}{'key-ids'} = $1, next;
	#- positive flags
	/^(update|ignore|synthesis|noreconfigure|static|virtual)$/
	    and $config{$medium}{$1} = 1, next;
	my ($no, $k, $v);
	#- boolean options
	if (($no, $k, $v) = /^(no-)?(
	    verify-rpm
	    |norebuild
	    |fuzzy
	    |allow-(?:force|nodeps)
	    |(?:pre|post)-clean
	    |excludedocs
	    |compress
	    |keep
	    |auto
	    |strict-arch
	    |nopubkey
	    |resume)(?:\s*:\s*(.*))?$/x
	) {
	    my $yes = $no ? 0 : 1;
	    $no = $yes ? 0 : 1;
	    $v = '' unless defined $v;
	    $config{$medium}{$k} = $v =~ /^(yes|on|1|)$/i ? $yes : $no;
	    next;
	}
	#- obsolete
	$_ eq 'modified' and next;
    }
    close $f;
    return \%config;
}

sub dump_config ($$) {
    my ($file, $config) = @_;
    my $config_old = load_config($file, 1);
    my @media = sort {
	return  0 if $a eq $b;
	return -1 if $a eq ''; #- global options come first
	return  1 if $b eq '';
	return $config->{$a}{priority} <=> $config->{$b}{priority} || $a cmp $b;
    } keys %$config;
    open my $f, '>', $file or do {
	$err = N("unable to write config file [%s]", $file);
	return 0;
    };
    foreach my $m (@media) {
	if ($m) {
	    print $f quotespace($m), ' ', quotespace(substitute_back($config->{$m}{url}, $config_old->{$m}{url})), " {\n";
	} else {
	    next if !keys %{$config->{''}};
	    print $f "{\n";
	}
	foreach (sort grep { $_ && $_ ne 'url' } keys %{$config->{$m}}) {
	    if (/^(update|ignore|synthesis|noreconfigure|static|virtual)$/) {
		print $f "  $_\n";
	    } elsif ($_ ne 'priority') {
		print $f "  $_: " . substitute_back($config->{$m}{$_}, $config_old->{$m}{$_}) . "\n";
	    }
	}
	print $f "}\n\n";
    }
    close $f;
    return 1;
}

#- routines to handle mirror list location

#- Default mirror list
our $mirrors = 'http://www.mandrivalinux.com/mirrorsfull.list';

sub mirrors_cfg () {
    if (-e "/etc/urpmi/mirror.config") {
	local $_;
	open my $fh, "/etc/urpmi/mirror.config" or return undef;
	while (<$fh>) {
	    chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	    /^url\s*=\s*(.*)/ and $mirrors = $1;
	}
	close $fh;
    }
    return 1;
}

1;

__END__

=back

=head1 COPYRIGHT

Copyright (C) 2000, 2001, 2002, 2003, 2004, 2005 MandrakeSoft SA

Copyright (C) 2005 Mandriva SA

=cut
