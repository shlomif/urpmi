package urpm::cfg;

use strict;
use warnings;
use urpm::util;

=head1 NAME

urpm::cfg - routines to handle the urpmi configuration files

=head1 SYNOPSIS

=head1 DESCRIPTION

=over

=item load_config($file)

Reads an urpmi configuration file and return its contents in a hash ref :

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

=cut

our $err;

sub _syntax_error () { $err = N("syntax error in config file at line %s" }

sub load_config ($) {
    my ($file) = @_;
    my %config;
    my $medium = undef;
    $err = '';
    open my $f, $file or do { $err = "Can't read $file: $!\n"; return }
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
	if (/^(.*?[^\\])\s+(?:(.*?[^\\])\s+)?{$/ { #-} medium definition
	    $config{ $medium = unquotespace $1 }{url} = unquotespace $2;
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
	  |key[\-_]ids
	  |split-(?:level|length)
	  |priority-upgrade
	  |downloader
	 )\s*:\s*(.*)$/x
	    and $config{$medium}{$1} = $2, next;
	#- positive flags
	/^(update|ignore|synthesis|virtual)$/
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
	    my $yes = !$no;
	    $config{$medium}{$k} = $v =~ /^(yes|on|1|)$/i ? $yes : !$yes;
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
}

__END__

=back

=cut
