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

our $err;

sub _syntax_error () { $err = N("syntax error in config file at line %s", $.) }

sub load_config ($) {
    my ($file) = @_;
    my %config;
    my $priority = 0;
    my $medium = undef;
    $err = '';
    open my $f, $file or do { $err = N("unable to read config file [%s]", $file); return };
    local $_;
    while (<$f>) {
	chomp;
	next if /^\s*#/; #- comments
	s/^\s+//; s/\s+$//;
	if ($_ eq '}') { #-{
	    if (!defined $medium) {
		_syntax_error;
		return;
	    }
	    $config{$medium}{priority} = $priority++; #- to preserve order
	    undef $medium;
	    next;
	}
	if (defined $medium && /{$/) { #-}
	    _syntax_error;
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
	  |downloader
	 )\s*:\s*['"]?(.*?)['"]?$/x
	    and $config{$medium}{$1} = $2, next;
	/^key[-_]ids\s*:\s*['"]?(.*?)['"]?$/
	    and $config{$medium}{'key-ids'} = $1, next;
	#- positive flags
	/^(update|ignore|synthesis|virtual|noreconfigure)$/
	    and $config{$medium}{$1} = 1, next;
	my ($no, $k, $v);
	#- boolean options
	if (($no, $k, $v) = /^(no-)?(
	    verify-rpm
	    |fuzzy
	    |allow-(?:force|nodeps)
	    |(?:pre|post)-clean
	    |excludedocs
	    |compress
	    |keep
	    |auto
	    |resume)(?:\s*:\s*(.*))?$/x
	) {
	    my $yes = $no ? 0 : 1;
	    $no = $yes ? 0 : 1;
	    $config{$medium}{$k} = $v =~ /^(yes|on|1|)$/i ? $yes : $no;
	    next;
	}
	#- obsolete
	/^modified$/ and next;
    }
    close $f;
    return \%config;
}

sub dump_config ($$) {
    my ($file, $config) = @_;
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
    print $f "# generated ".(scalar localtime)."\n";
    for my $m (@media) {
	if ($m) {
	    print $f quotespace($m), ' ', quotespace($config->{$m}{url}), " {\n";
	} else {
	    next if !keys %{$config->{''}};
	    print $f "{\n";
	}
	for (sort grep { $_ && $_ ne 'url' } keys %{$config->{$m}}) {
	    if (/^(update|ignore|synthesis|virtual)$/) {
		print $f "  $_\n";
	    } elsif ($_ ne 'priority') {
		print $f "  $_: $config->{$m}{$_}\n";
	    }
	}
	print $f "}\n\n";
    }
    close $f;
    return 1;
}

1;

__END__

=back

=head1 COPYRIGHT

Copyright (C) 2000-2004 Mandrakesoft

=cut
