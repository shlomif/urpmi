package urpm::args;

use strict;
use warnings;
no warnings 'once';
use Getopt::Long;# 2.33;

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

# options specifications for Getopt::Long
my %options_spec = (

    urpmi => {
	"help|h" => sub {
	    if (defined &::usage) { ::usage() } else { die "No help defined\n" }
	},
	"no-locales" => sub {
	    require urpm; # make sure it has been loaded
	    undef *::N; undef *urpm::N;
	    *::N = *urpm::N = sub { sprintf(@_) };
	},
	update => \$::update,
	'media|mediums=s' => \$::media,
	'excludemedia|exclude-media=s' => \$::excludemedia,
	'sortmedia|sort-media=s' => \$::sortmedia,
	'synthesis=s' => \$::synthesis,
	auto => \$urpm->{options}{auto},
	'allow-medium-change' => \$::allow_medium_change,
	'auto-select' => \$::auto_select,
	'no-remove|no-uninstall' => \$::no_remove,
	keep => \$urpm->{options}{keep},
	'split-level=s' => \$urpm->{options}{'split-level'},
	'split-length=s' => \$urpm->{options}{'split-length'},
	'fuzzy!' => \$urpm->{options}{fuzzy},
	'src|s' => \$::src,
	'install-src' => \$::install_src,
	clean => sub { $::clean = 1; $::noclean = 0 },
	noclean => sub {
	    $::clean = $urpm->{options}{'pre-clean'} = $urpm->{options}{'post-clean'} = 0;
	    $::noclean = 1;
	},
	'pre-clean!' => \$urpm->{options}{'pre-clean'},
	'post-clean!' => \$urpm->{options}{'post-clean'},
	'no-priority-upgrades' => sub {
	    $urpm->{options}{'priority-upgrade'} = '';
	},
	force => \$::force,
	'allow-nodeps' => \$urpm->{options}{'allow-nodeps'},
	'allow-force' => \$urpm->{options}{'allow-force'},
	'parallel=s' => \$::parallel,
	wget => sub { $urpm->{options}{downloader} = 'wget' },
	curl => sub { $urpm->{options}{downloader} = 'curl' },
	'limit-rate=s' => \$urpm->{options}{'limit-rate'},
	'resume!' => \$urpm->{options}{resume},
	proxy => sub {
	    my (undef, $value) = @_;
	    my ($proxy, $port) = $value =~ m,^(?:http://)?([^:]+(:\d+)?)/*$,
		or die N("bad proxy declaration on command line\n");
	    $proxy .= ":1080" unless $port;
	    $urpm->{proxy}{http_proxy} = "http://$proxy";
	},
	'proxy-user' => sub {
	    my (undef, $value) = @_;
	    $value =~ /(.+):(.+)/ or die N("bad proxy declaration on command line\n");
	    @{$urpm->{proxy}}{qw(user pwd)} = ($1, $2);
	},
	'bug=s' => \$::bug,
	'env=s' => \$::env,
	X => \$::X,
	WID => \$::WID,
	'best-output' => sub {
	    $::X ||= $ENV{DISPLAY} && system('/usr/X11R6/bin/xtest', '') == 0
	},
	'verify-rpm!' => \$urpm->{options}{'verify-rpm'},
	'test!' => \$::test,
	'skip=s' => \$::skip,
	'root=s' => \$::root,
	'use-distrib=s' => \$::usedistrib,
	'excludepath|exclude-path=s' => \$urpm->{options}{excludepath},
	'excludedocs|exclude-docs' => \$urpm->{options}{excludedocs},
	a => \$::all,
	q => sub { --$::verbose; $::rpm_opt = '' },
	v => sub { ++$::verbose; $::rpm_opt = 'vh' },
	p => sub { $::use_provides = 1 },
	P => sub { $::use_provides = 0 },
	y => \$urpm->{options}{fuzzy},
	z => \$urpm->{options}{compress},
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
	    {
		$::params{$k} = 1;
	    }
	},
	name => \$::params{filename},
	'group|size|epoch|summary|description|sourcerpm|packager|buildhost|url|provides|requires|files|conflicts|obsoletes' => sub {
	    $::params{$_[0]} = 1;
	},
	i => sub { $::pattern = 'i' },
	f => sub { $::full = 'full' },
	'e=s' => sub { $::expr .= "($_[0])" },
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
	update => \$::query->{update},
	'media|mediums=s' => \$::query->{media},
	'excludemedia|exclude-media=s' => \$::query->{excludemedia},
	'sortmedia|sort-media=s' => \$::query->{sortmedia},
	'synthesis=s' => \$::query->{sortmedia},
	'auto-select' => sub {
	    $::query->{deps} = $::query->{upgrade} = $::query->{auto_select} = 1;
	},
	fuzzy => sub {
	    $::query->{fuzzy} = $::query->{all} = 1;
	},
	keep => \$::query->{keep},
	list => \$::query->{list},
	'list-media' => \$::query->{list_media},
	'list-url' => \$::query->{list_url},
	'list-nodes' => \$::query->{list_nodes},
	'list-aliases' => \$::query->{list_aliases},
	'dump-config' => \$::query->{dump_config},
	'src|s' => \$::query->{src},
	headers => \$::query->{headers},
	sources => \$::query->{sources},
	force => \$::query->{force},
	'skip=s' => \$::query->{skip},
	'root=s' => \$::query->{root},
	'use-distrib=s' => \$::query->{usedistrib},
	'parallel=s' => \$::query->{parallel},
	'env=s' => \$::query->{env},
	'changelog=s' => \$::query->{changelog},
	d => \$::query->{deps},
	u => \$::query->{upgrade},
	a => \$::query->{all},
	'm|M' => sub { $::query->{deps} = $::query->{upgrade} = 1 },
	c => \$::query->{complete},
	g => \$::query->{group},
	p => \$::query->{use_provides},
	P => sub { $::query->{use_provides} = 0 },
	R => \$::query->{what_requires},
	y => sub { $::query->{fuzzy} = $::query->{all} = 1 },
	v => \$::query->{verbose},
	i => \$::query->{info},
	l => \$::query->{list_files},
	r => sub {
	    $::query->{version} = $::query->{release} = 1;
	},
	f => sub {
	    $::query->{version} = $::query->{release} = $::query->{arch} = 1;
	},
	'<>' => sub {
	    my $x = $_[0];
	    if ($x =~ /\.rpm$/) {
		if (-r $x) { push @::files, $x }
		else { print STDERR N("urpmq: cannot read rpm file \"%s\"\n", $x) }
	    } else {
		if ($::query->{src}) {
		    push @::src_names, $x;
		} else {
		    push @::names, $x;
		}
		$::query->{src} = 0; #- reset switch for next package.
	    }
	},
    },

    'urpmi.update' => {
	a => \$::options{all},
	c => sub { $::options{noclean} = 0 },
	f => sub { ++$::options{force} },
	z => sub { ++$::options{compress} },
	update => \$::options{update},
	'force-key' => \$::options{forcekey},
	'limit-rate=s' => \$::options{limit_rate},
	'no-md5sum' => \$::options{nomd5sum},
	'noa|d' => \my $dummy, # default, keeped for compatibility
	'<>' => sub { push @::toupdates, $_[0] },
    },

    'urpmi.addmedia' => {
	'probe-synthesis' => sub { $::options{probe_with} = 'synthesis' },
	'probe-hdlist' => sub { $::options{probe_with} = 'hdlist' },
	'no-probe' => sub { $::options{probe_with} = undef },
	distrib => sub { $::options{distrib} = undef },
	'from=s' => \$::options{mirrors_url},
	'version=s' => \$::options{version},
	'arch=s' => \$::options{arch},
	virtual => \$::options{virtual},
	'<>' => sub {
	    if ($_[0] =~ /^--distrib-(.*)$/) {
		$::options{distrib} = $1;
	    }
	    else {
		push @::cmdline, $_[0];
	    }
	},
    },

);

# common options setup
# TODO <> for arguments

foreach my $k ("help|h", "no-locales", "test!", "force", "root=s", "use-distrib=s",
    "parallel=s")
{
    $options_spec{urpme}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "no-locales", "update", "media|mediums=s",
    "excludemedia|exclude-media=s", "sortmedia|sort-media=s",
    "synthesis=s", "env=s")
{
    $options_spec{urpmf}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "wget", "curl", "proxy", "proxy-user") {
    $options_spec{'urpmi.update'}{$k} =
    $options_spec{urpmq}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "wget", "curl", "proxy", "proxy-user", "c", "f", "z",
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
    GetOptions(%{$options_spec{$tool}});
}

1;

__END__

=head1 NAME

urpm::args - command-line argument parser for the urpm* tools

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut
