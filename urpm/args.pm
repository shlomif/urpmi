package urpm::args;

use strict;
use warnings;
no warnings 'once';
use Getopt::Long;# 2.33;
use urpm::download;

# The program that invokes us
(my $tool = $0) =~ s!.*/!!;

# Configuration of Getopt. urpmf is a special case, because we need to
# parse non-alphanumerical options (-! -( -))
my @configuration = qw(bundling gnu_compat permute);
push @configuration, 'pass_through'
    if $tool eq 'urpmf' || $tool eq 'urpmi.addmedia';
Getopt::Long::Configure(@configuration);

# global urpm object to be passed by the main program
my $urpm;

# stores the values of the command-line options
our %options;

sub import {
    if (@_ > 1 && $_[1] eq 'options') {
	# export the global %options hash
	no strict 'refs';
	*{caller().'::options'} = \%options;
    }
}

# options specifications for Getopt::Long
my %options_spec = (

    urpmi => {
	"version" => sub { require urpm; print "$tool $urpm::VERSION\n"; exit(0) },
	"help|h" => sub {
	    if (defined &::usage) { ::usage() } else { die "No help defined\n" }
	},
	"no-locales" => sub {
	    require urpm::msg; # make sure it has been loaded
	    undef *::N;
	    undef *urpm::N;
	    undef *urpm::msg::N;
	    undef *urpm::args::N;
	    *::N = *urpm::N = *urpm::msg::N = *urpm::args::N
		= sub { my ($f, @p) = @_; sprintf($f, @p) };
	},
	update => \$::update,
	'media|mediums=s' => \$::media,
	'excludemedia|exclude-media=s' => \$::excludemedia,
	'sortmedia|sort-media=s' => \$::sortmedia,
	'synthesis=s' => \$::synthesis,
	auto => sub {
	    $urpm->{options}{auto} = $::auto = 1;
	},
	'allow-medium-change' => \$::allow_medium_change,
	'auto-select' => \$::auto_select,
	'no-remove|no-uninstall' => \$::no_remove,
	keep => sub { $urpm->{options}{keep} = 1 },
	'split-level=s' => sub { $urpm->{options}{'split-level'} = $_[1] },
	'split-length=s' => sub { $urpm->{options}{'split-length'} = $_[1] },
	'fuzzy!' => sub { $urpm->{options}{fuzzy} = $_[1] },
	'src|s' => \$::src,
	'install-src' => \$::install_src,
	clean => sub { $::clean = 1; $::noclean = 0 },
	noclean => sub {
	    $::clean = $urpm->{options}{'pre-clean'} = $urpm->{options}{'post-clean'} = 0;
	    $::noclean = 1;
	},
	'pre-clean!' => sub { $urpm->{options}{'pre-clean'} = $_[1] },
	'post-clean!' => sub { $urpm->{options}{'post-clean'} = $_[1] },
	'no-priority-upgrades' => sub {
	    $urpm->{options}{'priority-upgrade'} = '';
	},
	force => \$::force,
	'allow-nodeps' => sub { $urpm->{options}{'allow-nodeps'} = 1 },
	'allow-force' => sub { $urpm->{options}{'allow-force'} = 1 },
	'parallel=s' => \$::parallel,
	wget => sub { $urpm->{options}{downloader} = 'wget' },
	curl => sub { $urpm->{options}{downloader} = 'curl' },
	'limit-rate=s' => sub { $urpm->{options}{'limit-rate'} = $_[1] },
	'resume!' => sub { $urpm->{options}{resume} = $_[1] },
	'proxy=s' => sub {
	    my (undef, $value) = @_;
	    my ($proxy, $port) = $value =~ m,^(?:http://)?([^:/]+(:\d+)?)/*$,
		or die N("bad proxy declaration on command line\n");
	    $proxy .= ":1080" unless $port;
	    $urpm->{proxy}{http_proxy} = "http://$proxy/"; #- obsolete, for compat
	    urpm::download::set_cmdline_proxy(http_proxy => "http://$proxy/");
	},
	'proxy-user=s' => sub {
	    my (undef, $value) = @_;
	    $value =~ /(.+):(.+)/ or die N("bad proxy declaration on command line\n");
	    @{$urpm->{proxy}}{qw(user pwd)} = ($1, $2); #- obsolete, for compat
	    urpm::download::set_cmdline_proxy(user => $1, pwd => $2);
	},
	'bug=s' => \$options{bug},
	'env=s' => \$::env,
	X => \$options{X},
	WID => \$::WID,
	'best-output' => sub {
	    $options{X} ||= $ENV{DISPLAY} && system('/usr/X11R6/bin/xtest', '') == 0
	},
	'verify-rpm!' => sub { $urpm->{options}{'verify-rpm'} = $_[1] },
	'test!' => \$::test,
	'skip=s' => \$options{skip},
	'root=s' => \$::root,
	'use-distrib=s' => \$::usedistrib,
	'excludepath|exclude-path=s' => sub { $urpm->{options}{excludepath} = $_[1] },
	'excludedocs|exclude-docs' => sub { $urpm->{options}{excludedocs} = 1 },
	a => \$::all,
	q => sub { --$::verbose; $::rpm_opt = '' },
	v => sub { ++$::verbose; $::rpm_opt = 'vh' },
	p => sub { $::use_provides = 1 },
	P => sub { $::use_provides = 0 },
	y => sub { $urpm->{options}{fuzzy} = 1 },
	z => sub { $urpm->{options}{compress} = 1 },
    },

    urpme => {
	auto => \$::auto,
	v => \$::verbose,
	a => \$::matches,
    },

    urpmf => {
	'verbose|v' => \$::verbose,
	'quiet|q' => \$::quiet,
	'uniq|u' => \$::uniq,
	all => sub {
	    foreach my $k (qw(filename group size summary description sourcerpm
		packager buildhost url provides requires files conflicts obsoletes))
	    { $::params{$k} = 1 }
	},
	name => \$::params{filename},
	group => \$::params{group},
	size => \$::params{size},
	epoch => \$::params{epoch},
	summary => \$::params{summary},
	description => \$::params{description},
	sourcerpm => \$::params{sourcerpm},
	packager => \$::params{packager},
	buildhost => \$::params{buildhost},
	url => \$::params{url},
	provides => \$::params{provides},
	requires => \$::params{requires},
	files => \$::params{files},
	conflicts => \$::params{conflicts},
	obsoletes => \$::params{obsoletes},
	i => sub { $::pattern = 'i' },
	f => sub { $::full = 'full' },
	'e=s' => sub { $::expr .= "($_[1])" },
	a => sub { $::expr .= ' && ' },
	o => sub { $::expr .= ' || ' },
	'<>' => sub {
	    my $p = shift;
	    if ($p =~ /^-([!()])$/) {
		# This is for -! -( -)
		$::expr .= $1;
	    }
	    else {
		# This is for non-option arguments.
		# Assume a regex unless a ++ is inside the string.
		$p = quotemeta $p if $p =~ /\+\+/;
		$::expr .= "m{$p}".$::pattern;
	    }
	},
    },

    urpmq => {
	update => \$options{update},
	'media|mediums=s' => \$options{media},
	'excludemedia|exclude-media=s' => \$options{excludemedia},
	'sortmedia|sort-media=s' => \$options{sortmedia},
	'synthesis=s' => \$options{sortmedia},
	'auto-select' => sub {
	    $options{deps} = $options{upgrade} = $options{auto_select} = 1;
	},
	fuzzy => sub {
	    $options{fuzzy} = $options{all} = 1;
	},
	keep => \$options{keep},
	list => \$options{list},
	changelog => \$options{changelog},
	'list-media' => \$options{list_media},
	'list-url' => \$options{list_url},
	'list-nodes' => \$options{list_nodes},
	'list-aliases' => \$options{list_aliases},
	'dump-config' => \$options{dump_config},
	'src|s' => \$options{src},
	headers => \$options{headers},
	sources => \$options{sources},
	force => \$options{force},
	'skip=s' => \$options{skip},
	'root=s' => \$options{root},
	'use-distrib=s' => \$options{usedistrib},
	'parallel=s' => \$options{parallel},
	'env=s' => \$options{env},
	d => \$options{deps},
	u => \$options{upgrade},
	a => \$options{all},
	'm|M' => sub { $options{deps} = $options{upgrade} = 1 },
	c => \$options{complete},
	g => \$options{group},
	p => \$options{use_provides},
	P => sub { $options{use_provides} = 0 },
	R => \$options{what_requires},
	y => sub { $options{fuzzy} = $options{all} = 1 },
	Y => sub { $options{fuzzy} = $options{all} = $options{caseinsensitive} = 1 },
	v => \$options{verbose},
	i => \$options{info},
	l => \$options{list_files},
	r => sub {
	    $options{version} = $options{release} = 1;
	},
	f => sub {
	    $options{version} = $options{release} = $options{arch} = 1;
	},
	'<>' => sub {
	    my $x = $_[0];
	    if ($x =~ /\.rpm$/) {
		if (-r $x) { push @::files, $x }
		else { print STDERR N("urpmq: cannot read rpm file \"%s\"\n", $x) }
	    } else {
		if ($options{src}) {
		    push @::src_names, $x;
		} else {
		    push @::names, $x;
		}
		$options{src} = 0; #- reset switch for next package.
	    }
	},
    },

    'urpmi.update' => {
	a => \$options{all},
	c => sub { $options{noclean} = 0 },
	f => sub { ++$options{force} },
	z => sub { ++$options{compress} },
	update => \$options{update},
	'force-key' => \$options{forcekey},
	'limit-rate=s' => \$options{limit_rate},
	'no-md5sum' => \$options{nomd5sum},
	'noa|d' => \my $dummy, # default, keeped for compatibility
	'q|quiet'   => sub { --$options{verbose} },
	'v|verbose' => sub { ++$options{verbose} },
	'<>' => sub { push @::toupdates, $_[0] },
    },

    'urpmi.addmedia' => {
	'probe-synthesis' => sub { $options{probe_with} = 'synthesis' },
	'probe-hdlist' => sub { $options{probe_with} = 'hdlist' },
	'no-probe' => sub { $options{probe_with} = undef },
	distrib => sub { $options{distrib} = undef },
	'from=s' => \$options{mirrors_url},
	'version=s' => \$options{version},
	'arch=s' => \$options{arch},
	virtual => \$options{virtual},
	'q|quiet'   => sub { --$options{verbose} },
	'v|verbose' => sub { ++$options{verbose} },
	'<>' => sub {
	    if ($_[0] =~ /^--distrib-(.*)$/) {
		$options{distrib} = $1;
	    }
	    else {
		push @::cmdline, $_[0];
	    }
	},
    },

);

# common options setup

foreach my $k ("help|h", "version", "no-locales", "test!", "force", "root=s", "use-distrib=s",
    "parallel=s")
{
    $options_spec{urpme}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "version", "no-locales", "update", "media|mediums=s",
    "excludemedia|exclude-media=s", "sortmedia|sort-media=s",
    "synthesis=s", "env=s")
{
    $options_spec{urpmf}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "version", "wget", "curl", "proxy=s", "proxy-user=s") {
    $options_spec{'urpmi.update'}{$k} =
    $options_spec{urpmq}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "wget", "curl", "proxy=s", "proxy-user=s", "c", "f", "z",
    "limit-rate=s", "no-md5sum", "update")
{
    $options_spec{'urpmi.addmedia'}{$k} = $options_spec{'urpmi.update'}{$k};
}

sub parse_cmdline {
    my %args = @_;
    # set up global urpm object
    $urpm = $args{urpm};
    # get default values (and read config file)
    # TODO
    # parse options
    if ($tool eq 'urpmi') {
	foreach (@ARGV) { $_ = '-X' if $_ eq '--X' }
    }
    GetOptions(%{$options_spec{$tool}});
}

1;

__END__

=head1 NAME

urpm::args - command-line argument parser for the urpm* tools

=head1 SYNOPSIS

    urpm::args::parse_cmdline();

=head1 DESCRIPTION

=head1 COPYRIGHT

Copyright (C) 2000-2004 Mandrakesoft

=cut
