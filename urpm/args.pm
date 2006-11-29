package urpm::args;

# $Id$

use strict;
use warnings;
no warnings 'once';
use Getopt::Long;# 2.33;
use urpm::download;
use urpm::msg;
use Exporter;

our @ISA = 'Exporter';
our @EXPORT = '%options';

(our $VERSION) = q($Revision$) =~ /(\d+)/;

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

# used by urpmf
sub add_param_closure {
    my (@tags) = @_;
    return sub { $::qf .= join $::separator, '', map { "%$_" } @tags };
}

# options specifications for Getopt::Long

my %options_spec_all = (
	'debug' => sub { $urpm->{debug} = sub { print STDERR "$_[0]\n" } },
);

my %options_spec = (

    urpmi => {
	"version" => sub { require urpm; print "$tool $urpm::VERSION\n"; exit(0) },
	"help|h" => sub {
	    if (defined &::usage) { ::usage() } else { die "No help defined\n" }
	},
	"no-locales" => sub { $urpm::msg::no_translation = 1 },
	update => \$::update,
	'media|mediums=s' => \$::media,
	'excludemedia|exclude-media=s' => \$::excludemedia,
	'sortmedia|sort-media=s' => \$::sortmedia,
	'searchmedia|search-media=s' => \$::searchmedia,
	'synthesis=s' => \$::synthesis,
	auto => sub { $urpm->{options}{auto} =  1 },
	'allow-medium-change' => \$::allow_medium_change,
	'gui' => \$::gui,
	'auto-select' => \$::auto_select,
	'auto-update' => sub { $::auto_update = $::auto_select = 1 },
	'no-remove|no-uninstall' => \$::no_remove,
	'no-install|noinstall' => \$::no_install,
	'keep!' => sub { $urpm->{options}{keep} = $_[1] },
	'logfile=s' => \$::logfile,
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
	'no-priority-upgrade' => sub {
	    $urpm->{options}{'priority-upgrade'} = '';
	},
	force => \$::force,
	'allow-nodeps' => sub { $urpm->{options}{'allow-nodeps'} = 1 },
	'allow-force' => sub { $urpm->{options}{'allow-force'} = 1 },
	'parallel=s' => \$::parallel,
	wget => sub { $urpm->{options}{downloader} = 'wget' },
	curl => sub { $urpm->{options}{downloader} = 'curl' },
	prozilla => sub { $urpm->{options}{downloader} = 'prozilla' },
	'curl-options=s' => sub { $urpm->{options}{'curl-options'} = $_[1] },
	'rsync-options=s' => sub { $urpm->{options}{'rsync-options'} = $_[1] },
	'wget-options=s' => sub { $urpm->{options}{'wget-options'} = $_[1] },
	'prozilla-options=s' => sub { $urpm->{options}{'prozilla-options'} = $_[1] },
	'limit-rate=s' => sub { $urpm->{options}{'limit-rate'} = $_[1] },
	'resume!' => sub { $urpm->{options}{resume} = $_[1] },
	'retry=s' => sub { $urpm->{options}{retry} = $_[1] },
	'proxy=s' => sub {
	    my (undef, $value) = @_;
	    my ($proxy, $port) = $value =~ m,^(?:http://)?([^:/]+(:\d+)?)/*$,
		or die N("bad proxy declaration on command line\n");
	    $proxy .= ":1080" unless $port;
	    urpm::download::set_cmdline_proxy(http_proxy => "http://$proxy/");
	},
	'proxy-user=s' => sub {
	    my (undef, $value) = @_;
	    if ($value eq 'ask') { #- should prompt for user/password
		urpm::download::set_cmdline_proxy(ask => 1);
	    } else {
		$value =~ /(.+):(.+)/ or die N("bad proxy declaration on command line\n");
		urpm::download::set_cmdline_proxy(user => $1, pwd => $2);
	    }
	},
	'bug=s' => \$options{bug},
	'env=s' => \$::env,
	'verify-rpm!' => sub { $urpm->{options}{'verify-rpm'} = $_[1] },
	'strict-arch!' => sub { $urpm->{options}{'strict-arch'} = $_[1] },
	'norebuild!' => sub { $urpm->{options}{'build-hdlist-on-error'} = !$_[1] },
	'test!' => \$::test,
	'skip=s' => \$options{skip},
	'root=s' => sub {
	    require File::Spec;
	    $options{root} = File::Spec->rel2abs($_[1]);
	    if (!-d $options{root}) {
		$urpm->{fatal}->(9, N("chroot directory doesn't exist"));
	    }
	    $options{nolock} = 1;
	},
	'use-distrib=s' => \$options{usedistrib},
	'probe-synthesis' => sub { $options{probe_with} = 'synthesis' },
	'probe-hdlist' => sub { $options{probe_with} = 'hdlist' },
	'excludepath|exclude-path=s' => sub { $urpm->{options}{excludepath} = $_[1] },
	'excludedocs|exclude-docs' => sub { $urpm->{options}{excludedocs} = 1 },
	'ignoresize' => sub { $urpm->{options}{ignoresize} = 1 },
	'ignorearch' => sub { $urpm->{options}{ignorearch} = 1 },
	noscripts => sub { $urpm->{options}{noscripts} = 1 },
	repackage => sub { $urpm->{options}{repackage} = 1 },
	'more-choices' => sub { $urpm->{options}{morechoices} = 1 },
	'expect-install!' => \$::expect_install,
	'nolock' => \$options{nolock},
	restricted => \$::restricted,
	'no-md5sum' => \$::nomd5sum,
	'force-key' => \$::forcekey,
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
	noscripts => \$::noscripts,
	repackage => \$::repackage,
	restricted => \$::restricted,
	'bundle!' => sub { $::bundle = $_[1] },
    },

    #- see also below, autogenerated callbacks
    urpmf => {
	conffiles => add_param_closure('conf_files'),
	debug => \$::debug,
	'literal|l' => \$::literal,
	name => sub {
	    add_param_closure('name')->();
	    #- Remove default tag in front if --name is explicitly given
	    $::qf =~ s/^%default:?//;
	},
	'qf=s' => \$::qf,
	'uniq|u' => \$::uniq,
	'verbose|v' => \$::verbose,
	m => add_param_closure('media'),
	i => sub { $::pattern = 'i' },
	I => sub { $::pattern = '' },
	f => sub { $::full = 1 },
	'F=s' => sub { $::separator = $_[1] },
	'e=s' => sub { $::expr .= "($_[1])" },
	a => sub { $::expr .= ' && ' },
	o => sub { $::expr .= ' || ' },
	'<>' => sub {
	    my $p = shift;
	    if ($p =~ /^-?([!()])$/) {
		# This is for -! -( -)
		$::expr .= $1;
	    }
	    elsif ($p =~ /^--?(.+)/) {
		# unrecognized option
		die "Unknown option: $1\n";
	    }
	    else {
		# This is for non-option arguments.
		if ($::literal) {
		    $p = quotemeta $p;
		} else {
		    # quote "+" chars for packages with + in their names
		    $p =~ s/\+/\\+/g;
		}
		$::expr .= "m{$p}" . $::pattern;
	    }
	},
    },

    urpmq => {
	update => \$options{update},
	'media|mediums=s' => \$options{media},
	'excludemedia|exclude-media=s' => \$options{excludemedia},
	'sortmedia|sort-media=s' => \$options{sortmedia},
	'searchmedia|search-media=s' => \$options{searchmedia},
	'synthesis=s' => \$options{synthesis},
	'auto-select' => sub {
	    $options{deps} = $options{upgrade} = $options{auto_select} = 1;
	},
	fuzzy => sub { $urpm->{options}{fuzzy} = 1; $options{all} = 1 },
	keep => \$options{keep},
	list => \$options{list},
	changelog => \$options{changelog},
	'summary|S' => \$options{summary},
	'list-media:s' => sub { $options{list_media} = $_[1] || 'all' },
	'list-url' => \$options{list_url},
	'list-nodes' => \$options{list_nodes},
	'list-aliases' => \$options{list_aliases},
	'ignorearch' => \$options{ignorearch},
	'dump-config' => \$options{dump_config},
	'src|s' => \$options{src},
	sources => \$options{sources},
	force => \$options{force},
	'skip=s' => \$options{skip},
	'use-distrib=s' => sub {
	    if ($< != 0) {
		print STDERR N("You need to be root to use --use-distrib"), "\n";
		exit 1;
	    }
	    $options{usedistrib} = $_[1];
	},
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
	R => sub { ++$options{what_requires} },
	y => sub { $urpm->{options}{fuzzy} = 1; $options{all} = 1 },
	Y => sub { $urpm->{options}{fuzzy} = 1; $options{all} = $options{caseinsensitive} = 1 },
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
	    } elsif ($x =~ /^--?(.+)/) { # unrecognized option
		die "Unknown option: $1\n";
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
	f => sub { ++$options{force}; $options{force_building_hdlist} = 1 if $options{force} == 2 },
	z => sub { ++$options{compress} },
	update => \$options{update},
	'ignore!' => sub { $options{ignore} = $_[1] },
	'force-key' => \$options{forcekey},
	'no-md5sum' => \$options{nomd5sum},
	'noa|d' => \my $_dummy, #- default, kept for compatibility
	'q|quiet'   => sub { --$options{verbose} },
	'v|verbose' => sub { ++$options{verbose} },
	'norebuild!' => sub { $urpm->{options}{'build-hdlist-on-error'} = !$_[1]; $options{force} = 0 },
	'<>' => sub {
	    my ($p) = @_;
	    if ($p =~ /^--?(.+)/) { # unrecognized option
		die "Unknown option: $1\n";
	    }
	    push @::cmdline, $p;
	},
    },

    'urpmi.addmedia' => {
	'no-probe' => sub { $options{probe_with} = undef },
	distrib => sub { $options{distrib} = 1 },
        interactive => sub { $options{interactive} = 1 },
        'all-media' => sub { $options{allmedia} = 1 },
	'from=s' => \$options{mirrors_url},
	virtual => \$options{virtual},
	nopubkey => \$options{nopubkey},
	'q|quiet'   => sub { --$options{verbose} },
	'v|verbose' => sub { ++$options{verbose} },
	raw => \$options{raw},
    },

    'urpmi.recover' => {
	'list=s' => \$::listdate,
	'list-all' => sub { $::listdate = -1 },
	'list-safe' => sub { $::listdate = 'checkpoint' },
	checkpoint => \$::do_checkpoint,
	'rollback=s' => \$::rollback,
	noclean => \$::noclean,
	disable => \$::disable,
    },

);

# generate urpmf options callbacks

foreach my $k (qw(
    arch
    buildhost
    buildtime
    conflicts
    description
    distribution
    epoch
    filename
    files
    group
    obsoletes
    packager
    provides
    requires
    size
    sourcerpm
    summary
    url
    vendor
)) {
    $options_spec{urpmf}{$k} = add_param_closure($k);
}

# common options setup

foreach my $k ("help|h", "version", "no-locales", "test!", "force", "root=s", "use-distrib=s",
    "parallel=s")
{
    $options_spec{urpme}{$k} = $options_spec{urpmi}{$k};
}
foreach my $k ("root=s", "nolock")
{
    $options_spec{urpmq}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "version", "no-locales", "update", "media|mediums=s",
    "excludemedia|exclude-media=s", "sortmedia|sort-media=s",
    "synthesis=s", "env=s")
{
    $options_spec{urpmf}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "version", "wget", "curl", "prozilla", "proxy=s", "proxy-user=s",
    'limit-rate=s',
    "wget-options=s", "curl-options=s", "rsync-options=s", "prozilla-options=s")
{
    $options_spec{'urpmi.update'}{$k} =
    $options_spec{urpmq}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "wget", "curl", "prozilla", "proxy=s", "proxy-user=s", "c", "f", "z",
    "limit-rate=s", "no-md5sum", "update", "norebuild!",
    "wget-options=s", "curl-options=s", "rsync-options=s", "prozilla-options=s", '<>')
{
    $options_spec{'urpmi.addmedia'}{$k} = $options_spec{'urpmi.update'}{$k};
}

foreach my $k ("a", "c", 'v|verbose', 'q|quiet', '<>') {
    $options_spec{'urpmi.removemedia'}{$k} = $options_spec{'urpmi.update'}{$k};
}
foreach my $k ("y") {
    $options_spec{'urpmi.removemedia'}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("probe-synthesis", "probe-hdlist")
{
    $options_spec{'urpmi.addmedia'}{$k} = 
      $options_spec{urpme}{$k} = 
	$options_spec{urpmq}{$k} = $options_spec{urpmi}{$k};
}

foreach my $k ("help|h", "version") {
    $options_spec{'urpmi.removemedia'}{$k} = 
      $options_spec{'urpmi.recover'}{$k} = $options_spec{urpmi}{$k};
}

sub parse_cmdline {
    my %args = @_;
    $urpm = $args{urpm};
    foreach my $k (keys %{$args{defaults} || {}}) {
	$options{$k} = $args{defaults}{$k};
    }
    my $ret = GetOptions(%{$options_spec{$tool}}, %options_spec_all);

    if ($tool ne 'urpmi.addmedia' && $options{probe_with} && !$options{usedistrib}) {
	die N("Can't use %s without %s", "--probe-$options{probe_with}", "--use-distrib");
    }
    if ($tool eq 'urpmf' && @ARGV && $ARGV[0] eq '--') {
	if (@ARGV == 2) {
	    my $p = $ARGV[1];
	    if ($::literal) {
		$p = quotemeta $p;
	    } else {
		$p =~ s/\+/\\+/g;
	    }
	    $::expr .= "m{$p}" . $::pattern;
            $ret = 1;
	}
	else {
	    die N("Too many arguments\n");
	}
    }
    $ret;
}

1;

__END__

=head1 NAME

urpm::args - command-line argument parser for the urpm* tools

=head1 SYNOPSIS

    urpm::args::parse_cmdline();

=head1 DESCRIPTION

=head1 COPYRIGHT

Copyright (C) 2000, 2001, 2002, 2003, 2004, 2005 MandrakeSoft SA

Copyright (C) 2005, 2006 Mandriva SA

=cut

=for vim:ts=8:sts=4:sw=4
