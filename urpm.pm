package urpm;

# $Id$

no warnings 'utf8';
use strict;
use File::Find ();
use urpm::msg;
use urpm::download;
use urpm::util;
use urpm::sys;
use urpm::cfg;

our $VERSION = '4.8.16';
our @ISA = qw(URPM);

use URPM;
use URPM::Resolve;

BEGIN {
    # this won't work in 5.10 when encoding::warnings will be lexical
    if ($ENV{DEBUG_URPMI}) {
	require encoding::warnings;
	encoding::warnings->import;
    }
}

#- this violently overrides is_arch_compat() to always return true.
sub shunt_ignorearch {
    eval q( sub URPM::Package::is_arch_compat { 1 } );
}

#- create a new urpm object.
sub new {
    my ($class) = @_;
    my $self;
    $self = bless {
	# from URPM
	depslist   => [],
	provides   => {},

	config     => "/etc/urpmi/urpmi.cfg",
	skiplist   => "/etc/urpmi/skip.list",
	instlist   => "/etc/urpmi/inst.list",
	statedir   => "/var/lib/urpmi",
	cachedir   => "/var/cache/urpmi",
	media      => undef,
	options    => {},

	#- sync: first argument is options hashref, others are urls to fetch.
	sync       => sub { $self->sync_webfetch(@_) },
	fatal      => sub { printf STDERR "%s\n", $_[1]; exit($_[0]) },
	error      => sub { printf STDERR "%s\n", $_[0] },
	log        => sub { printf "%s\n", $_[0] },
	ui_msg     => sub {
	    $self->{log}($_[0]);
	    ref $self->{ui} && ref $self->{ui}{msg} and $self->{ui}{msg}->($_[1]);
	},
    }, $class;
    $self->set_nofatal(1);
    $self;
}

#- syncing algorithms.
sub sync_webfetch {
    my $urpm = shift;
    my $options = shift;
    my %files;
    #- currently ftp and http protocols are managed by curl or wget,
    #- ssh and rsync protocols are managed by rsync *AND* ssh.
    foreach (@_) {
	/^([^:_]*)[^:]*:/ or die N("unknown protocol defined for %s", $_);
	push @{$files{$1}}, $_;
    }
    if ($files{removable} || $files{file}) {
	eval {
	    sync_file($options, @{$files{removable} || []}, @{$files{file} || []});
	};
	$urpm->{fatal}(10, $@) if $@;
	delete @files{qw(removable file)};
    }
    for my $cpt (qw(wget-options curl-options rsync-options)) {
	$options->{$cpt} = $urpm->{options}{$cpt} if defined $urpm->{options}{$cpt};
    }
    if ($files{ftp} || $files{http} || $files{https}) {
	my @webfetch = qw(curl wget);
	my @available_webfetch = grep { -x "/usr/bin/$_" || -x "/bin/$_" } @webfetch;
	#- use user default downloader if provided and available
	my $option_downloader = $urpm->{options}{downloader}; #- cmd-line switch
	if (!$option_downloader && $options->{media}) { #- per-media config
	    (my $m) = grep { $_->{name} eq $options->{media} } @{$urpm->{media}};
	    ref $m && $m->{downloader} and $option_downloader = $m->{downloader};
	}
	#- global config
	!$option_downloader && exists $urpm->{global_config}{downloader}
	    and $option_downloader = $urpm->{global_config}{downloader};
	my ($preferred) = grep { $_ eq $option_downloader } @available_webfetch;
	#- else first downloader of @webfetch is the default one
	$preferred ||= $available_webfetch[0];
	if ($option_downloader ne $preferred && $option_downloader && !our $webfetch_not_available) {
	    $urpm->{log}(N("%s is not available, falling back on %s", $option_downloader, $preferred));
	    $webfetch_not_available = 1;
	}
	if ($preferred eq 'curl') {
	    sync_curl($options, @{$files{ftp} || []}, @{$files{http} || []}, @{$files{https} || []});
	} elsif ($preferred eq 'wget') {
	    sync_wget($options, @{$files{ftp} || []}, @{$files{http} || []}, @{$files{https} || []});
	} else {
	    die N("no webfetch found, supported webfetch are: %s\n", join(", ", @webfetch));
	}
	delete @files{qw(ftp http https)};
    }
    if ($files{rsync}) {
	sync_rsync($options, @{$files{rsync} || []});
	delete $files{rsync};
    }
    if ($files{ssh}) {
	my @ssh_files;
	foreach (@{$files{ssh} || []}) {
	    m|^ssh://([^/]*)(.*)| and push @ssh_files, "$1:$2";
	}
	sync_ssh($options, @ssh_files);
	delete $files{ssh};
    }
    %files and die N("unable to handle protocol: %s", join ', ', keys %files);
}

our @PER_MEDIA_OPT = qw(
    downloader
    hdlist
    ignore
    key-ids
    list
    md5sum
    noreconfigure
    priority
    removable
    static
    synthesis
    update
    verify-rpm
    virtual
    with_hdlist
);

#- Loads /etc/urpmi/urpmi.cfg and performs basic checks.
#- Does not handle old format: <name> <url> [with <path_hdlist>]
#- options :
#-    - nocheck_access : don't check presence of hdlist and other files
sub read_config {
    my ($urpm, %options) = @_;
    return if $urpm->{media}; #- media already loaded
    $urpm->{media} = [];
    my $config = urpm::cfg::load_config($urpm->{config})
	or $urpm->{fatal}(6, $urpm::cfg::err);

    #- global options
    if ($config->{''}) {
	foreach my $opt (qw(
	    allow-force
	    allow-nodeps
	    auto
	    compress
	    downloader
	    default-media
	    excludedocs
	    excludepath
	    fuzzy
	    ignoresize
	    keep
	    key-ids
	    limit-rate
	    nopubkey
	    norebuild
	    post-clean
	    pre-clean
	    priority-upgrade
	    prohibit-remove
	    repackage
	    resume
	    retry
	    split-length
	    split-level
	    strict-arch
	    verify-rpm
	    curl-options
	    rsync-options
	    wget-options
	)) {
	    if (defined $config->{''}{$opt} && !exists $urpm->{options}{$opt}) {
		$urpm->{options}{$opt} = $config->{''}{$opt};
	    }
	}
    }
    #- per-media options
    foreach my $m (grep { $_ ne '' } keys %$config) {
	my $medium = { name => $m, clear_url => $config->{$m}{url} };
	foreach my $opt (@PER_MEDIA_OPT) {
	    defined $config->{$m}{$opt} and $medium->{$opt} = $config->{$m}{$opt};
	}
	$urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
    }

    eval { require urpm::ldap; urpm::ldap::load_ldap_media($urpm, %options) };

    #- load default values
    foreach (qw(post-clean verify-rpm)) {
	exists $urpm->{options}{$_} or $urpm->{options}{$_} = 1;
    }

    $urpm->{media} = [ sort { $a->{priority} <=> $b->{priority} } @{$urpm->{media}} ];

    #- remember if an hdlist or list file is already used
    my %filelists;
    foreach (@{$urpm->{media}}) {
	foreach my $filetype (qw(hdlist list)) {
	    if ($_->{$filetype}) {
		exists($filelists{$filetype}{$_->{$filetype}})
		    and $_->{ignore} = 1,
		    $urpm->{error}(
			$filetype eq 'hdlist'
			    ? N("medium \"%s\" trying to use an already used hdlist, medium ignored", $_->{name})
			    : N("medium \"%s\" trying to use an already used list, medium ignored",   $_->{name})
		    );
		$filelists{$filetype}{$_->{$filetype}} = undef;
	    }
	}
    }

    #- check the presence of hdlist and list files if necessary.
    unless ($options{nocheck_access}) {
	foreach (@{$urpm->{media}}) {
	    $_->{ignore} and next;
	    -r "$urpm->{statedir}/$_->{hdlist}" || -r "$urpm->{statedir}/synthesis.$_->{hdlist}" && $_->{synthesis}
		or $_->{ignore} = 1,
		$urpm->{error}(N("unable to access hdlist file of \"%s\", medium ignored", $_->{name}));
	    $_->{list} && -r "$urpm->{statedir}/$_->{list}" || defined $_->{url}
		or $_->{ignore} = 1,
		$urpm->{error}(N("unable to access list file of \"%s\", medium ignored", $_->{name}));
	}
    }

    #- read MD5 sums (usually not in urpmi.cfg but in a separate file)
    my $md5sum = $urpm->open_safe("<", "$urpm->{statedir}/MD5SUM");
    if ($md5sum) {
	while (<$md5sum>) {
	    my ($md5sum, $file) = /(\S*)\s+(.*)/;
	    foreach (@{$urpm->{media}}) {
		($_->{synthesis} ? "synthesis." : "") . $_->{hdlist} eq $file
		    and $_->{md5sum} = $md5sum, last;
	    }
	}
	close $md5sum;
    }

    #- remember global options for write_config
    $urpm->{global_config} = $config->{''};
}

#- probe medium to be used, take old medium into account too.
sub probe_medium {
    my ($urpm, $medium, %options) = @_;
    local $_;

    foreach (@{$urpm->{media}}) {
	if ($_->{name} eq $medium->{name}) {
	    $urpm->{error}(N("trying to override existing medium \"%s\", skipping", $medium->{name}));
	    return;
	}
    }

    $medium->{url} ||= $medium->{clear_url};

    if ($medium->{virtual}) {
	#- a virtual medium needs to have an url available without using a list file.
	if ($medium->{hdlist} || $medium->{list}) {
	    $medium->{ignore} = 1;
	    $urpm->{error}(N("virtual medium \"%s\" should not have defined hdlist or list file, medium ignored",
			     $medium->{name}));
	}
	unless ($medium->{url}) {
	    $medium->{ignore} = 1;
	    $urpm->{error}(N("virtual medium \"%s\" should have a clear url, medium ignored",
			     $medium->{name}));
	}
    } else {
	unless ($medium->{ignore} || $medium->{hdlist}) {
	    $medium->{hdlist} = "hdlist.$medium->{name}.cz";
	    -e "$urpm->{statedir}/$medium->{hdlist}" or $medium->{hdlist} = "hdlist.$medium->{name}.cz2";
	    -e "$urpm->{statedir}/$medium->{hdlist}" or
	      $medium->{ignore} = 1,
		$urpm->{error}(N("unable to find hdlist file for \"%s\", medium ignored", $medium->{name}));
	}
	unless ($medium->{ignore} || $medium->{list}) {
	    unless (defined $medium->{url}) {
		$medium->{list} = "list.$medium->{name}";
		unless (-e "$urpm->{statedir}/$medium->{list}") {
		    $medium->{ignore} = 1,
		      $urpm->{error}(N("unable to find list file for \"%s\", medium ignored", $medium->{name}));
		}
	    }
	}

	#- there is a little more to do at this point as url is not known, inspect directly list file for it.
	unless ($medium->{url}) {
	    my %probe;
	    if (-r "$urpm->{statedir}/$medium->{list}") {
		my $listfile = $urpm->open_safe("<", "$urpm->{statedir}/$medium->{list}");
		if ($listfile) {
		    while (<$listfile>) {
			#- /./ is end of url marker in list file (typically generated by a
			#- find . -name "*.rpm" > list
			#- for exportable list file.
			m|^(.*)/\./| and $probe{$1} = undef;
			m|^(.*)/[^/]*$| and $probe{$1} = undef;
		    }
		    close $listfile;
		}
	    }
	    foreach (sort { length($a) <=> length($b) } keys %probe) {
		if ($medium->{url}) {
		    if ($medium->{url} ne substr($_, 0, length($medium->{url}))) {
			$medium->{ignore} or $urpm->{error}(N("inconsistent list file for \"%s\", medium ignored", $medium->{name}));
			$medium->{ignore} = 1;
			last;
		    }
		} else {
		    $medium->{url} = $_;
		}
	    }
	    unless ($options{nocheck_access}) {
		unless ($medium->{url}) {
		    $medium->{ignore} or $urpm->{error}(N("unable to inspect list file for \"%s\", medium ignored", $medium->{name}));
		    $medium->{ignore} = 1;
		}
	    }
	}
    }

    #- probe removable device.
    $urpm->probe_removable_device($medium);

    #- clear URLs for trailing /es.
    $medium->{url} and $medium->{url} =~ s|(.*?)/*$|$1|;
    $medium->{clear_url} and $medium->{clear_url} =~ s|(.*?)/*$|$1|;

    $medium;
}

#- returns the removable device name if it corresponds to an iso image, '' otherwise
sub is_iso {
    my ($removable_dev) = @_;
    $removable_dev && $removable_dev =~ /\.iso$/i ? $removable_dev : '';
}

#- probe device associated with a removable device.
sub probe_removable_device {
    my ($urpm, $medium) = @_;

    #- try to find device name in url scheme
    if ($medium->{url} && $medium->{url} =~ /^removable_?([^_:]*)(?:_[^:]*)?:/) {
	$medium->{removable} ||= $1 && "/dev/$1";
    } else {
	delete $medium->{removable};
    }

    #- try to find device to open/close for removable medium.
    if (exists($medium->{removable})) {
	if (my ($dir) = $medium->{url} =~ m!^(?:(?:file|removable)[^:]*:/)?(/.*)!) {
	    my %infos;
	    my @mntpoints = urpm::sys::find_mntpoints($dir, \%infos);
	    if (@mntpoints > 1) { #- return value is suitable for an hash.
		$urpm->{log}(N("too many mount points for removable medium \"%s\"", $medium->{name}));
		$urpm->{log}(N("taking removable device as \"%s\"", join ',', map { $infos{$_}{device} } @mntpoints));
	    }
	    if (is_iso($medium->{removable})) {
		$urpm->{log}(N("Medium \"%s\" is an ISO image, will be mounted on-the-fly", $medium->{name}));
	    } elsif (@mntpoints) {
		if ($medium->{removable} && $medium->{removable} ne $infos{$mntpoints[-1]}{device}) {
		    $urpm->{log}(N("using different removable device [%s] for \"%s\"",
				   $infos{$mntpoints[-1]}{device}, $medium->{name}));
		}
		$medium->{removable} = $infos{$mntpoints[-1]}{device};
	    } else {
		$urpm->{error}(N("unable to retrieve pathname for removable medium \"%s\"", $medium->{name}));
	    }
	} else {
	    $urpm->{error}(N("unable to retrieve pathname for removable medium \"%s\"", $medium->{name}));
	}
    }
}

#- Writes the urpmi.cfg file.
sub write_config {
    my ($urpm) = @_;

    #- avoid trashing exiting configuration if it wasn't loaded
    $urpm->{media} or return;

    my $config = {
	#- global config options found in the config file, without the ones
	#- set from the command-line
	'' => $urpm->{global_config},
    };
    foreach my $medium (@{$urpm->{media}}) {
	next if $medium->{external};
	my $medium_name = $medium->{name};
	$config->{$medium_name}{url} = $medium->{clear_url};
	foreach (qw(hdlist with_hdlist list removable key-ids priority priority-upgrade update noreconfigure static ignore synthesis virtual)) {
	    defined $medium->{$_} and $config->{$medium_name}{$_} = $medium->{$_};
	}
    }
    urpm::cfg::dump_config($urpm->{config}, $config)
	or $urpm->{fatal}(6, N("unable to write config file [%s]", $urpm->{config}));

    #- write MD5SUM file
    my $md5sum = $urpm->open_safe('>', "$urpm->{statedir}/MD5SUM") or return 0;
    foreach my $medium (@{$urpm->{media}}) {
	$medium->{md5sum}
	    and print $md5sum "$medium->{md5sum}  " . ($medium->{synthesis} && "synthesis.") . $medium->{hdlist} . "\n";
    }
    close $md5sum;

    $urpm->{log}(N("wrote config file [%s]", $urpm->{config}));

    #- everything should be synced now.
    delete $urpm->{modified};
}

#- read urpmi.cfg file as well as necessary synthesis files
#- options :
#-	callback
#-	call_back_only_once
#-	excludemedia
#-	hdlist
#-	media
#-	nodepslist
#-	noinstalling
#-	noskipping
#-	parallel
#-	root
#-	searchmedia
#-	skip
#-	sortmedia
#-	update
#-	usedistrib
sub configure {
    my ($urpm, %options) = @_;

    $urpm->clean;

    $options{parallel} && $options{usedistrib} and $urpm->{fatal}(1, N("Can't use parallel mode with use-distrib mode"));

    if ($options{parallel}) {
	my ($parallel_options, $parallel_handler);
	#- read parallel configuration
	local $_;
	my $parallel = $urpm->open_safe("<", "/etc/urpmi/parallel.cfg");
	if ($parallel) {
	    while (<$parallel>) {
		chomp; s/#.*$//; s/^\s*//; s/\s*$//;
		/\s*([^:]*):(.*)/ or $urpm->{error}(N("unable to parse \"%s\" in file [%s]", $_, "/etc/urpmi/parallel.cfg")), next;
		$1 eq $options{parallel} and $parallel_options = ($parallel_options && "\n") . $2;
	    }
	    close $parallel;
	}
	#- if a configuration option has been found, use it; else fatal error.
	if ($parallel_options) {
	    foreach my $dir (grep { -d $_ } map { "$_/urpm" } @INC) {
		my $dh = $urpm->opendir_safe($dir);
		if ($dh) {
		    while (defined ($_ = readdir $dh)) { #- load parallel modules
			/parallel.*\.pm$/ && -f "$dir/$_" or next;
			$urpm->{log}->(N("examining parallel handler in file [%s]", "$dir/$_"));
			eval { require "$dir/$_"; $parallel_handler = $urpm->handle_parallel_options($parallel_options) };
			$parallel_handler and last;
		    }
		    closedir $dh;
		}
		$parallel_handler and last;
	    }
	}
	if ($parallel_handler) {
	    if ($parallel_handler->{nodes}) {
		$urpm->{log}->(N("found parallel handler for nodes: %s", join(', ', keys %{$parallel_handler->{nodes}})));
	    }
	    if (!$options{media} && $parallel_handler->{media}) {
		$options{media} = $parallel_handler->{media};
		$urpm->{log}->(N("using associated media for parallel mode: %s", $options{media}));
	    }
	    $urpm->{parallel_handler} = $parallel_handler;
	} else {
	    $urpm->{fatal}(1, N("unable to use parallel option \"%s\"", $options{parallel}));
	}
    } else {
	#- parallel is exclusive against root options.
	$urpm->{root} = $options{root};
    }

    $urpm->{root} && ! -c "$urpm->{root}/dev/null"
	and $urpm->{error}(N("there doesn't seem to be devices in the chroot in \"%s\"", $urpm->{root}));

    if ($options{synthesis}) {
	if ($options{synthesis} ne 'none') {
	    #- synthesis take precedence over media, update options.
	    $options{media} || $options{excludemedia} || $options{sortmedia} || $options{update} || $options{parallel} and
	      $urpm->{fatal}(1, N("--synthesis cannot be used with --media, --excludemedia, --sortmedia, --update or --parallel"));
	    $urpm->parse_synthesis($options{synthesis});
	    #- synthesis disables the split of transaction (too risky and not useful).
	    $urpm->{options}{'split-length'} = 0;
	}
    } else {
        if ($options{usedistrib}) {
            $urpm->{media} = [];
            $urpm->add_distrib_media("Virtual", $options{usedistrib}, %options, 'virtual' => 1);
        } else {
	    $urpm->read_config(%options);
	    if (!$options{media} && $urpm->{options}{'default-media'}) {
		$options{media} = $urpm->{options}{'default-media'};
	    }
        }
	if ($options{media}) {
	    delete $_->{modified} foreach @{$urpm->{media} || []};
	    $urpm->select_media(split /,/, $options{media});
	    foreach (grep { !$_->{modified} } @{$urpm->{media} || []}) {
		#- this is only a local ignore that will not be saved.
		$_->{ignore} = 1;
	    }
	}
	if ($options{searchmedia}) {
	   $urpm->select_media($options{searchmedia}); #- Ensure this media has been selected
	   foreach (grep { !$_->{ignore} } @{$urpm->{media} || []}) {
		$_->{name} eq $options{searchmedia} and do {
			$_->{searchmedia} = 1;
			last;
		};
	   }
	}
	if ($options{excludemedia}) {
	    delete $_->{modified} foreach @{$urpm->{media} || []};
	    $urpm->select_media(split /,/, $options{excludemedia});
	    foreach (grep { $_->{modified} } @{$urpm->{media} || []}) {
		#- this is only a local ignore that will not be saved.
		$_->{ignore} = 1;
	    }
	}
	if ($options{sortmedia}) {
	    delete $_->{modified} foreach @{$urpm->{media} || []};
	    my @oldmedia = @{$urpm->{media} || []};
	    my @newmedia;
	    foreach (split /,/, $options{sortmedia}) {
		$urpm->select_media($_);
		push @newmedia, grep { $_->{modified} } @oldmedia;
		@oldmedia = grep { !$_->{modified} } @oldmedia;
	    }
	    #- anything not selected should be added here, as it's after the selected ones.
	    $urpm->{media} = [ @newmedia, @oldmedia ];
	    #- forget remaining modified flags.
	    delete $_->{modified} foreach @{$urpm->{media} || []};
	}
	unless ($options{nodepslist}) {
	    my $second_pass;
	    do {
		foreach (grep { !$_->{ignore} && (!$options{update} || $_->{update}) } @{$urpm->{media} || []}) {
		    our $currentmedia = $_; #- hack for urpmf
		    delete @$_{qw(start end)};
		    if ($_->{virtual}) {
			my $path = $_->{url} =~ m!^(?:file:/*)?(/[^/].*[^/])/*\Z! && $1;
			if ($path) {
			    if ($_->{synthesis}) {
				$urpm->{log}(N("examining synthesis file [%s]", "$path/$_->{with_hdlist}"));
				($_->{start}, $_->{end}) = $urpm->parse_synthesis(
				    "$path/$_->{with_hdlist}", callback => $options{callback});
			    } else {
				$urpm->{log}(N("examining hdlist file [%s]", "$path/$_->{with_hdlist}"));
				#- we'll need a second pass
				defined $second_pass or $second_pass = 1;
				($_->{start}, $_->{end}) = $urpm->parse_hdlist(
				    "$path/$_->{with_hdlist}",
				    packing => 1,
				    callback => $options{call_back_only_once} && $second_pass ? undef : $options{callback},
				);
			    }
			} else {
			    $urpm->{error}(N("virtual medium \"%s\" is not local, medium ignored", $_->{name}));
			    $_->{ignore} = 1;
			}
		    } else {
			if ($options{hdlist} && -e "$urpm->{statedir}/$_->{hdlist}" && -s _ > 32) {
			    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$_->{hdlist}"));
			    ($_->{start}, $_->{end}) = $urpm->parse_hdlist(
				"$urpm->{statedir}/$_->{hdlist}",
				packing => 1,
				callback => $options{callback},
			    );
			} else {
			    $urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$_->{hdlist}"));
			    ($_->{start}, $_->{end}) = $urpm->parse_synthesis(
				"$urpm->{statedir}/synthesis.$_->{hdlist}",
				callback => $options{callback},
			    );
			    unless (defined $_->{start} && defined $_->{end}) {
				$urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$_->{hdlist}"));
				($_->{start}, $_->{end}) = $urpm->parse_hdlist("$urpm->{statedir}/$_->{hdlist}",
				    packing => 1,
				    callback => $options{callback},
				);
			    }
			}
		    }
		    unless ($_->{ignore}) {
			if (defined $_->{start} && defined $_->{end}) {
			    if ($_->{searchmedia}) {
			        ($urpm->{searchmedia}{start}, $urpm->{searchmedia}{end}) = ($_->{start}, $_->{end});
				$urpm->{log}(N("Search start: %s end: %s",
					$urpm->{searchmedia}{start}, $urpm->{searchmedia}{end}));
				delete $_->{searchmedia};
			    }
			} else {
			    $urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $_->{name}));
			    $_->{ignore} = 1;
			}
		    }
		}
	    } while $second_pass && do {
		require URPM::Build;
		$urpm->{log}(N("performing second pass to compute dependencies\n"));
		$urpm->unresolved_provides_clean;
		$second_pass--;
	    };
	}
    }
    #- determine package to withdraw (from skip.list file) only if something should be withdrawn.
    unless ($options{noskipping}) {
	my %uniq;
	$urpm->compute_flags(
	    get_packages_list($urpm->{skiplist}, $options{skip}),
	    skip => 1,
	    callback => sub {
		my ($urpm, $pkg) = @_;
		$pkg->is_arch_compat && ! exists $uniq{$pkg->fullname} or return;
		$uniq{$pkg->fullname} = undef;
		$urpm->{log}(N("skipping package %s", scalar($pkg->fullname)));
	    },
	);
    }
    unless ($options{noinstalling}) {
	my %uniq;
	$urpm->compute_flags(
	    get_packages_list($urpm->{instlist}),
	    disable_obsolete => 1,
	    callback => sub {
		my ($urpm, $pkg) = @_;
		$pkg->is_arch_compat && ! exists $uniq{$pkg->fullname} or return;
		$uniq{$pkg->fullname} = undef;
		$urpm->{log}(N("would install instead of upgrade package %s", scalar($pkg->fullname)));
	    },
	);
    }
    if ($options{bug}) {
	#- and a dump of rpmdb itself as synthesis file.
	my $db = URPM::DB::open($options{root});
	my $sig_handler = sub { undef $db; exit 3 };
	local $SIG{INT} = $sig_handler;
	local $SIG{QUIT} = $sig_handler;

	$db or $urpm->{fatal}(9, N("unable to open rpmdb"));
	open my $rpmdb, "| " . ($ENV{LD_LOADER} || '') . " gzip -9 >'$options{bug}/rpmdb.cz'"
	    or $urpm->syserror("Can't fork", "gzip");
	$db->traverse(sub {
			  my ($p) = @_;
			  #- this is not right but may be enough.
			  my $files = join '@', grep { exists($urpm->{provides}{$_}) } $p->files;
			  $p->pack_header;
			  $p->build_info(fileno $rpmdb, $files);
		      });
	close $rpmdb;
    }
}

#- add a new medium, sync the config file accordingly.
#- returns the new medium's name. (might be different from the requested
#- name if index_name was specified)
sub add_medium {
    my ($urpm, $name, $url, $with_hdlist, %options) = @_;

    #- make sure configuration has been read.
    $urpm->{media} or $urpm->read_config;
    $options{nolock} or $urpm->exlock_urpmi_db;

    #- if a medium with that name has already been found, we have to exit now
    my $medium;
    if (defined $options{index_name}) {
	my $i = $options{index_name};
	do {
	    ++$i;
	    undef $medium;
	    foreach (@{$urpm->{media}}) {
		$_->{name} eq $name . $i and $medium = $_;
	    }
	} while $medium;
	$name .= $i;
    } else {
	foreach (@{$urpm->{media}}) {
	    $_->{name} eq $name and $medium = $_;
	}
    }
    $medium and $urpm->{fatal}(5, N("medium \"%s\" already exists", $medium->{name}));

    $url =~ s,/*$,,; #- clear URLs for trailing /es.

    #- creating the medium info.
    $medium = { name => $name, url => $url, update => $options{update}, modified => 1, ignore => $options{ignore} };
    if ($options{virtual}) {
	$url =~ m!^(?:file:)?/! or $urpm->{fatal}(1, N("virtual medium needs to be local"));
	$medium->{virtual} = 1;
    } else {
	$medium->{hdlist} = "hdlist.$name.cz";
	$medium->{list} = "list.$name";
	#- check if the medium is using a local or a removable medium.
	$url =~ m!^(?:(removable[^:]*|file):/)?(/.*)! and $urpm->probe_removable_device($medium);
    }

    #- local media have priority, other are added at the end.
    if ($url =~ m!^(?:file:)?/!) {
	$medium->{priority} = 0.5;
    } else {
	$medium->{priority} = 1 + @{$urpm->{media}};
    }

    #- check whether a password is visible, if not, set clear_url.
    my $has_password = $url =~ m|([^:]*://[^/:\@]*:)[^/:\@]*(\@.*)|;
    $medium->{clear_url} = $url unless $has_password;

    $with_hdlist and $medium->{with_hdlist} = $with_hdlist;

    #- create an entry in media list.
    push @{$urpm->{media}}, $medium;

    $urpm->{log}(N("added medium %s", $name));

    #- we need to reload the config, since some string substitutions may have occured
    unless ($options{no_reload_config}) {
	$urpm->write_config;
	delete $urpm->{media};
	$urpm->read_config(nocheck_access => 1);
	#- Remember that the database has been modified and base files need to
	#- be updated. This will be done automatically by transferring the
	#- "modified" flag from medium to global.
	$_->{name} eq $name and $_->{modified} = 1 foreach @{$urpm->{media}};
	$urpm->{modified} = 1;
    }
    if ($has_password) {
	foreach (grep { $_->{name} eq $name } @{$urpm->{media}}) {
	    $_->{url} = $url;
	}
    }

    $options{nolock} or $urpm->unlock_urpmi_db;
    $name;
}

#- add distribution media, according to url given.
#- returns the list of names of added media.
#- options :
#- - limit_rate, compress : for downloading files
#- - initial_number : when adding several numbered media, start with this number
#- - probe_with : if eq 'synthesis', use synthesis instead of hdlists
#- other options are passed to add_medium()
sub add_distrib_media {
    my ($urpm, $name, $url, %options) = @_;
    my ($hdlists_file);
    my $distrib_root = "media/media_info";

    #- make sure configuration has been read.
    # (Olivier Thauvin): Is this a workaround ?
    $urpm->{media} or $urpm->read_config;

    #- try to copy/retrieve the hdlists file.
    if (my ($dir) = $url =~ m!^(?:removable[^:]*:/|file:/)?(/.*)!) {
	#- be compatible with pre-10.1 layout
	-d "$dir/$distrib_root" or $distrib_root = "Mandrake/base";

	$hdlists_file = reduce_pathname("$dir/$distrib_root/hdlists");

	$urpm->try_mounting($hdlists_file) or $urpm->{error}(N("unable to access first installation medium")), return ();

	if (-e $hdlists_file) {
	    unlink "$urpm->{cachedir}/partial/hdlists";
	    $urpm->{log}(N("copying hdlists file..."));
	    urpm::util::copy($hdlists_file, "$urpm->{cachedir}/partial/hdlists")
		? $urpm->{log}(N("...copying done"))
		: do { $urpm->{error}(N("...copying failed")); return () };
	    chown 0, 0, "$urpm->{cachedir}/partial/hdlists";
	} else {
	    $urpm->{error}(N("unable to access first installation medium (no hdlists file found)"));
	    return ();
	}
    } else {
	#- try to get the description of the hdlists if it has been found.
	unlink "$urpm->{cachedir}/partial/hdlists";
	eval {
	    $urpm->{log}(N("retrieving hdlists file..."));
	    $urpm->{sync}(
		{
		    dir => "$urpm->{cachedir}/partial",
		    quiet => 1,
		    limit_rate => $options{limit_rate},
		    compress => $options{compress},
		    retry => $urpm->{options}{retry},
		    proxy => get_proxy(),
		},
		reduce_pathname("$url/$distrib_root/hdlists"),
	    );
	    $urpm->{log}(N("...retrieving done"));
	};
	$@ and $urpm->{error}(N("...retrieving failed: %s", $@));
	if (-e "$urpm->{cachedir}/partial/hdlists") {
	    $hdlists_file = "$urpm->{cachedir}/partial/hdlists";
	} else {
	    $urpm->{error}(N("unable to access first installation medium (no hdlists file found)"));
	    return ();
	}
    }

    #- cosmetic update of name if it contains spaces.
    $name =~ /\s/ and $name .= ' ';

    my @newnames;
    #- at this point, we have found an hdlists file, so parse it
    #- and create all necessary media according to it.
    my $hdlistsfh;
    if ($hdlistsfh = $urpm->open_safe("<", $hdlists_file)) {
	my $medium = $options{initial_number} || 1;
	foreach (<$hdlistsfh>) {
	    chomp;
	    s/\s*#.*$//;
	    /^\s*$/ and next;
	    /^(?:suppl|askmedia)/ and next;
	    /^\s*(noauto:)?(hdlist\S*\.cz2?)\s+(\S+)\s*([^(]*)(\(.+\))?$/
		or $urpm->{error}(N("invalid hdlist description \"%s\" in hdlists file", $_));
	    my ($noauto, $hdlist, $rpmsdir, $descr) = ($1, $2, $3, $4);
	    next if $noauto;
	    $descr =~ s/\s+$//;

	    push @newnames, $urpm->add_medium(
		$name ? "$descr ($name$medium)" : $descr,
		"$url/$rpmsdir",
		offset_pathname($url, $rpmsdir) . "/$distrib_root/" . ($options{probe_with} eq 'synthesis' ? 'synthesis.' : '') . $hdlist,
		index_name => $name ? undef : 0,
		no_reload_config => 1, #- no need to reload config each time, since we don't update the media
		%options,
	    );

	    ++$medium;
	}
	close $hdlistsfh;
	return @newnames;
    } else {
	$urpm->{error}(N("unable to access first installation medium (no hdlists file found)"));
	return ();
    }
}

sub select_media {
    my $urpm = shift;
    my $options = {};
    if (ref $_[0]) { $options = shift }
    my %media; @media{@_} = ();

    foreach (@{$urpm->{media}}) {
	if (exists($media{$_->{name}})) {
	    $media{$_->{name}} = 1; #- keep in mind this one has been selected.
	    #- select medium by setting the modified flag, do not check ignore.
	    $_->{modified} = 1;
	}
    }

    #- check if some arguments don't correspond to the medium name.
    #- in such case, try to find the unique medium (or list candidate
    #- media found).
    foreach (keys %media) {
	unless ($media{$_}) {
	    my $q = quotemeta;
	    my (@found, @foundi);
	    my $regex  = $options->{strict_match} ? qr/^$q$/  : qr/$q/;
	    my $regexi = $options->{strict_match} ? qr/^$q$/i : qr/$q/i;
	    foreach my $medium (@{$urpm->{media}}) {
		$medium->{name} =~ $regex  and push @found, $medium;
		$medium->{name} =~ $regexi and push @foundi, $medium;
	    }
	    if (@found == 1) {
		$found[0]{modified} = 1;
	    } elsif (@foundi == 1) {
		$foundi[0]{modified} = 1;
	    } elsif (@found == 0 && @foundi == 0) {
		$urpm->{error}(N("trying to select nonexistent medium \"%s\"", $_));
	    } else { #- several elements in found and/or foundi lists.
		$urpm->{log}(N("selecting multiple media: %s", join(", ", map { qq("$_->{name}") } (@found ? @found : @foundi))));
		#- changed behaviour to select all occurences by default.
		foreach (@found ? @found : @foundi) {
		    $_->{modified} = 1;
		}
	    }
	}
    }
}

sub remove_selected_media {
    my ($urpm) = @_;
    my @result;

    foreach (@{$urpm->{media}}) {
	if ($_->{modified}) {
	    $urpm->{log}(N("removing medium \"%s\"", $_->{name}));

	    #- mark to re-write configuration.
	    $urpm->{modified} = 1;

	    #- remove files associated with this medium.
	    foreach ($_->{hdlist}, $_->{list}, "synthesis.$_->{hdlist}", "descriptions.$_->{name}", "names.$_->{name}",
		     "$_->{name}.cache") {
		$_ and unlink "$urpm->{statedir}/$_";
	    }

	    #- remove proxy settings for this media
	    urpm::download::remove_proxy_media($_->{name});
	} else {
	    push @result, $_; #- not removed so keep it
	}
    }

    #- restore newer media list.
    $urpm->{media} = \@result;
}

#- return list of synthesis or hdlist reference to probe.
sub _probe_with_try_list {
    my ($suffix, $probe_with) = @_;
    my @probe = (
	"media_info/synthesis.hdlist.cz",
	"../media_info/synthesis.hdlist_$suffix.cz",
	"synthesis.hdlist.cz",
    );
    my @probe_hdlist = (
	"media_info/hdlist.cz",
	"../media_info/hdlist_$suffix.cz",
	"hdlist.cz",
    );
    if ($probe_with =~ /synthesis/) {
	push @probe, @probe_hdlist;
    } else {
	unshift @probe, @probe_hdlist;
    }
    @probe;
}

#- read a reconfiguration file for urpmi, and reconfigure media accordingly
#- $rfile is the reconfiguration file (local), $name is the media name
sub reconfig_urpmi {
    my ($urpm, $rfile, $name) = @_;
    my @replacements;
    my @reconfigurable = qw(url with_hdlist clear_url);
    my $reconfigured = 0;
    my $fh = $urpm->open_safe("<", $rfile) or return undef;
    $urpm->{log}(N("reconfiguring urpmi for media \"%s\"", $name));
    #- the first line of reconfig.urpmi must be magic, to be sure it's not an error file
    my $magic = <$fh>;
    $magic =~ /^# this is an urpmi reconfiguration file/ or return undef;
    while (<$fh>) {
	chomp;
	s/^\s*//; s/#.*$//; s/\s*$//;
	$_ or next;
	my ($p, $r, $f) = split /\s+/, $_, 3;
	$f ||= 1;
	push @replacements, [ quotemeta $p, $r, $f ];
    }
  MEDIA:
    foreach my $medium (grep { $_->{name} eq $name } @{$urpm->{media}}) {
        my %orig = map { $_ => $medium->{$_} } @reconfigurable;
      URLS:
	foreach my $k (@reconfigurable) {
	    foreach my $r (@replacements) {
		if ($medium->{$k} =~ s/$r->[0]/$r->[1]/) {
		    $reconfigured = 1;
		    #- Flags stolen from mod_rewrite: L(ast), N(ext)
		    last if $r->[2] =~ /L/;
		    redo URLS if $r->[2] =~ /N/;
		}
	    }
	    #- check that the new url exists before committing changes (local mirrors)
	    if ($medium->{$k} =~ m!^(?:file:/*)?(/[^/].*[^/])/*\Z! && !-e $1) {
		$medium->{$k} = $orig{$k} foreach @reconfigurable;
		$reconfigured = 0;
		$urpm->{log}(N("...reconfiguration failed"));
		last MEDIA;
	    }
	}
    }
    close $fh;
    if ($reconfigured) {
	$urpm->{log}(N("reconfiguration done"));
	$urpm->write_config;
    }
    $reconfigured;
}

sub _guess_hdlist_suffix {
    my ($dir) = @_;
    my ($suffix) = $dir =~ m!\bmedia/(\w+)/*\Z!;
    $suffix;
}

sub _guess_pubkey_name {
    my ($medium) = @_;
    return $medium->{with_hdlist} =~ /hdlist(.*?)(?:\.src)?\.cz2?$/ ? "pubkey$1" : 'pubkey';
}

#- Update the urpmi database w.r.t. the current configuration.
#- Takes care of modifications, and tries some tricks to bypass
#- the recomputation of base files.
#- Recognized options :
#-   all         : all medias are being rebuilt
#-   callback    : UI callback
#-   compress    : use compressed download (for rsync)
#-   forcekey    : force retrieval of pubkey
#-   force       : try to force rebuilding base files (1) or hdlist from rpm files (2)
#-   limit_rate  : download limit rate
#-   noclean     : keep old files in the header cache directory
#-   nolock      : don't lock the urpmi database
#-   nomd5sum    : don't verify MD5SUM of retrieved files
#-   nopubkey    : don't use rpm pubkeys
#-   norebuild   : don't try to rebuild hdlists from rpm headers
#-   probe_with  : probe synthesis or hdlist (or none)
#-   quiet       : download hdlists quietly
#-   ratio       : use this compression ratio (with gzip, default is 4)
sub update_media {
    my ($urpm, %options) = @_;
    my $clean_cache = !$options{noclean};
    my $second_pass;

    $urpm->{media} or return; # verify that configuration has been read

    my $nopubkey = $options{nopubkey} || $urpm->{options}{nopubkey};
    #- get gpg-pubkey signature.
    if (!$nopubkey) {
	$urpm->exlock_rpm_db;
	$urpm->{keys} or $urpm->parse_pubkeys(root => $urpm->{root});
    }
    #- lock database if allowed.
    $options{nolock} or $urpm->exlock_urpmi_db;

    #- examine each medium to see if one of them needs to be updated.
    #- if this is the case and if not forced, try to use a pre-calculated
    #- hdlist file, else build it from rpm files.
    $urpm->clean;

    my %media_redone;
  MEDIA:
    foreach my $medium (@{$urpm->{media}}) {
	$medium->{ignore} and next MEDIA;

	$options{forcekey} and delete $medium->{'key-ids'};

	#- we should create the associated synthesis file if it does not already exist...
	-e "$urpm->{statedir}/synthesis.$medium->{hdlist}" && -s _ > 32
	    or $medium->{modified_synthesis} = 1;

	#- if we're rebuilding all media, mark them as modified (except removable ones)
	$medium->{modified} ||= $options{all} && $medium->{url} !~ m!^removable://!;
	#- don't ever update static media
	$medium->{static} and $medium->{modified} = 0;

	unless ($medium->{modified}) {
	    #- the medium is not modified, but to compute dependencies,
	    #- we still need to read it and all synthesis will be written if
	    #- an unresolved provides is found.
	    #- to speed up the process, we only read the synthesis at the beginning.
	    delete @$medium{qw(start end)};
	    if ($medium->{virtual}) {
		my ($path) = $medium->{url} =~ m!^(?:file:)?/*(/[^/].*[^/])/*\Z!;
		if ($path) {
		    my $with_hdlist_file = "$path/$medium->{with_hdlist}";
		    if ($medium->{synthesis}) {
			$urpm->{log}(N("examining synthesis file [%s]", $with_hdlist_file));
			($medium->{start}, $medium->{end}) = $urpm->parse_synthesis($with_hdlist_file);
		    } else {
			$urpm->{log}(N("examining hdlist file [%s]", $with_hdlist_file));
			($medium->{start}, $medium->{end}) = $urpm->parse_hdlist($with_hdlist_file, packing => 1);
		    }
		} else {
		    $urpm->{error}(N("virtual medium \"%s\" is not local, medium ignored", $medium->{name}));
		    $_->{ignore} = 1;
		}
	    } else {
		$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
		($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
		unless (defined $medium->{start} && defined $medium->{end}) {
		    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
		    ($medium->{start}, $medium->{end}) = $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1);
		}
	    }
	    unless ($medium->{ignore}) {
		unless (defined $medium->{start} && defined $medium->{end}) {
		    #- this is almost a fatal error, ignore it by default?
		    $urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $medium->{name}));
		    $medium->{ignore} = 1;
		}
	    }
	    next;
	}

	#- list of rpm files for this medium, only available for local medium where
	#- the source hdlist is not used (use force).
	my ($prefix, $dir, $error, $retrieved_md5sum, @files);

	#- always delete a remaining list file or pubkey file in cache.
	foreach (qw(list pubkey)) {
	    unlink "$urpm->{cachedir}/partial/$_";
	}

	#- check if the medium is using a local or a removable medium.
	if (($prefix, $dir) = $medium->{url} =~ m!^(?:(removable[^:]*|file):/)?(/.*)!) {
	    $prefix ||= 'file';
	    #- check for a reconfig.urpmi file (if not already reconfigured)
	    if (!$media_redone{$medium->{name}} && !$medium->{noreconfigure}) {
		my $reconfig_urpmi = reduce_pathname("$dir/reconfig.urpmi");
		if (-s $reconfig_urpmi && $urpm->reconfig_urpmi($reconfig_urpmi, $medium->{name})) {
		    $media_redone{$medium->{name}} = 1;
		    redo MEDIA;
		}
	    }

	    #- try to figure a possible hdlist_path (or parent directory of searched directory).
	    #- this is used to probe for a possible hdlist file.
	    my $with_hdlist_dir = reduce_pathname($dir . ($medium->{with_hdlist} ? "/$medium->{with_hdlist}" : "/.."));

	    #- the directory given does not exist and may be accessible
	    #- by mounting some other directory. Try to figure it out and mount
	    #- everything that might be necessary.
	    -d $dir or $urpm->try_mounting(
		$options{force} < 2 && ($options{probe_with} || $medium->{with_hdlist})
		    ? $with_hdlist_dir : $dir,
		#- in case of an iso image, pass its name
		is_iso($medium->{removable}),
	    ) or $urpm->{error}(N("unable to access medium \"%s\",
this could happen if you mounted manually the directory when creating the medium.", $medium->{name})), next;

	    #- try to probe for possible with_hdlist parameter, unless
	    #- it is already defined (and valid).
	    if ($options{probe_with} && (!$medium->{with_hdlist} || ! -e "$dir/$medium->{with_hdlist}")) {
		foreach (_probe_with_try_list(_guess_hdlist_suffix($dir), $options{probe_with})) {
		    if (-e "$dir/$_" && -s _ > 32) {
			$medium->{with_hdlist} = $_;
			last;
		    }
		}
		#- redo...
		$with_hdlist_dir = reduce_pathname($dir . ($medium->{with_hdlist} ? "/$medium->{with_hdlist}" : "/.."));
	    }

	    if ($medium->{virtual}) {
		#- syncing a virtual medium is very simple, just try to read the file in order to
		#- determine its type, once a with_hdlist has been found (but is mandatory).
		if ($medium->{with_hdlist} && -e $with_hdlist_dir) {
		    delete @$medium{qw(start end)};
		    if ($medium->{synthesis}) {
			$urpm->{log}(N("examining synthesis file [%s]", $with_hdlist_dir));
			($medium->{start}, $medium->{end}) = $urpm->parse_synthesis($with_hdlist_dir);
			delete $medium->{modified};
			$medium->{synthesis} = 1;
			$urpm->{modified} = 1;
			unless (defined $medium->{start} && defined $medium->{end}) {
			    $urpm->{log}(N("examining hdlist file [%s]", $with_hdlist_dir));
			    ($medium->{start}, $medium->{end}) = $urpm->parse_hdlist($with_hdlist_dir, packing => 1);
			    delete @$medium{qw(modified synthesis)};
			    $urpm->{modified} = 1;
			}
		    } else {
			$urpm->{log}(N("examining hdlist file [%s]", $with_hdlist_dir));
			($medium->{start}, $medium->{end}) = $urpm->parse_hdlist($with_hdlist_dir, packing => 1);
			delete @$medium{qw(modified synthesis)};
			$urpm->{modified} = 1;
			unless (defined $medium->{start} && defined $medium->{end}) {
			    $urpm->{log}(N("examining synthesis file [%s]", $with_hdlist_dir));
			    ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis($with_hdlist_dir);
			    delete $medium->{modified};
			    $medium->{synthesis} = 1;
			    $urpm->{modified} = 1;
			}
		    }
		    unless (defined $medium->{start} && defined $medium->{end}) {
			$urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $medium->{name}));
			$medium->{ignore} = 1;
		    }
		} else {
		    $urpm->{error}(N("virtual medium \"%s\" should have valid source hdlist or synthesis, medium ignored",
				     $medium->{name}));
		    $medium->{ignore} = 1;
		}
	    }
	    #- try to get the description if it has been found.
	    unlink "$urpm->{statedir}/descriptions.$medium->{name}";
	    my $description_file = "$dir/media_info/descriptions"; #- new default location
	    -e $description_file or $description_file = "$dir/../descriptions";
	    if (-e $description_file) {
		$urpm->{log}(N("copying description file of \"%s\"...", $medium->{name}));
		urpm::util::copy($description_file, "$urpm->{statedir}/descriptions.$medium->{name}")
		    ? $urpm->{log}(N("...copying done"))
		    : do { $urpm->{error}(N("...copying failed")); $medium->{ignore} = 1 };
		chown 0, 0, "$urpm->{statedir}/descriptions.$medium->{name}";
	    }

	    #- examine if a distant MD5SUM file is available.
	    #- this will only be done if $with_hdlist is not empty in order to use
	    #- an existing hdlist or synthesis file, and to check if download was good.
	    #- if no MD5SUM is available, do it as before...
	    #- we can assume at this point a basename is existing, but it needs
	    #- to be checked for being valid, nothing can be deduced if no MD5SUM
	    #- file is present.
	    my $basename = urpm::download::basename($with_hdlist_dir);

	    unless ($medium->{virtual}) {
		if ($medium->{with_hdlist}) {
		    if (!$options{nomd5sum} && -s reduce_pathname("$with_hdlist_dir/../MD5SUM") > 32) {
			recompute_local_md5sum($urpm, $medium, $options{force});
			if ($medium->{md5sum}) {
			    $retrieved_md5sum = parse_md5sum($urpm, reduce_pathname("$with_hdlist_dir/../MD5SUM"), $basename);
			    #- If an existing hdlist or synthesis file has the same md5sum, we assume
			    #- the files are the same.
			    #- If the local md5sum is the same as the distant md5sum, this means
			    #- that there is no need to download the hdlist or synthesis file again.
			    if (defined $retrieved_md5sum && $medium->{md5sum} eq $retrieved_md5sum) {
				unlink "$urpm->{cachedir}/partial/$basename";
				#- the medium is now considered not modified.
				$medium->{modified} = 0;
				#- XXX we could link the new hdlist to the old one.
				#- (However links need to be managed. see bug #12391.)
				#- as previously done, just read synthesis file here, this is enough.
				$urpm->{log}(N("examining synthesis file [%s]",
				    "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
				($medium->{start}, $medium->{end}) =
				    $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
				unless (defined $medium->{start} && defined $medium->{end}) {
				    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
				    ($medium->{start}, $medium->{end}) =
					$urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1);
				    unless (defined $medium->{start} && defined $medium->{end}) {
					$urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"",
					    $medium->{name}));
					$medium->{ignore} = 1;
				    }
				}
			    }
			    $medium->{modified} or next MEDIA;
			}
		    }

		    #- if the source hdlist is present and we are not forcing using rpm files
		    if ($options{force} < 2 && -e $with_hdlist_dir) {
			unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
			$urpm->{log}(N("copying source hdlist (or synthesis) of \"%s\"...", $medium->{name}));
			$options{callback} and $options{callback}('copy', $medium->{name});
			if (urpm::util::copy($with_hdlist_dir, "$urpm->{cachedir}/partial/$medium->{hdlist}")) {
			    $options{callback} and $options{callback}('done', $medium->{name});
			    $urpm->{log}(N("...copying done"));
			    chown 0, 0, "$urpm->{cachedir}/partial/$medium->{hdlist}";
			} else {
			    $options{callback} and $options{callback}('failed', $medium->{name});
			    #- force error, reported afterwards
			    unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
			}
		    }

		    -e "$urpm->{cachedir}/partial/$medium->{hdlist}" && -s _ > 32 or
		      $error = 1, $urpm->{error}(N("copy of [%s] failed (file is suspiciously small)",
                                             "$urpm->{cachedir}/partial/$medium->{hdlist}"));

		    #- keep checking md5sum of file just copied ! (especially on nfs or removable device).
		    if (!$error && $retrieved_md5sum) {
			$urpm->{log}(N("computing md5sum of copied source hdlist (or synthesis)"));
			md5sum("$urpm->{cachedir}/partial/$medium->{hdlist}") eq $retrieved_md5sum or
			  $error = 1, $urpm->{error}(N("copy of [%s] failed (md5sum mismatch)", $with_hdlist_dir));
		    }

		    #- check if the files are equal... and no force copy...
		    if (!$error && !$options{force} && -e "$urpm->{statedir}/synthesis.$medium->{hdlist}") {
			my @sstat = stat "$urpm->{cachedir}/partial/$medium->{hdlist}";
			my @lstat = stat "$urpm->{statedir}/$medium->{hdlist}";
			if ($sstat[7] == $lstat[7] && $sstat[9] == $lstat[9]) {
			    #- the two files are considered equal here, the medium is so not modified.
			    $medium->{modified} = 0;
			    unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
			    #- as previously done, just read synthesis file here, this is enough, but only
			    #- if synthesis exists, else it needs to be recomputed.
			    $urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
			    ($medium->{start}, $medium->{end}) =
				$urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
			    unless (defined $medium->{start} && defined $medium->{end}) {
				$urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
				($medium->{start}, $medium->{end}) =
				    $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1);
				unless (defined $medium->{start} && defined $medium->{end}) {
				    $urpm->{error}(N("problem reading synthesis file of medium \"%s\"", $medium->{name}));
				    $medium->{ignore} = 1;
				}
			    }
			    next MEDIA;
			}
		    }
		} else {
		    if ($urpm->{options}{norebuild}) {
			$urpm->{error}(N("unable to access hdlist file of \"%s\", medium ignored", $medium->{name}));
			$medium->{ignore} = 1;
		    } else {
			$options{force} < 2 and $options{force} = 2;
		    }
		}

		#- if copying hdlist has failed, try to build it directly.
		if ($error) {
		    if ($urpm->{options}{norebuild}) {
			$urpm->{error}(N("unable to access hdlist file of \"%s\", medium ignored", $_->{name}));
			$medium->{ignore} = 1;
		    } else {
			$options{force} < 2 and $options{force} = 2;
			#- clear error state now.
			$error = undef;
		    }
		}

		if ($options{force} < 2) {
		    #- examine if a local list file is available (always probed according to with_hdlist)
		    #- and check hdlist wasn't named very strangely...
		    if ($medium->{hdlist} ne 'list') {
			my $local_list = $medium->{with_hdlist} =~ /hd(list.*)\.cz2?$/ ? $1 : 'list';
			my $path_list = reduce_pathname("$with_hdlist_dir/../$local_list");
			-e $path_list or $path_list = "$dir/list";
			if (-e $path_list) {
			    urpm::util::copy($path_list, "$urpm->{cachedir}/partial/list")
				or do { $urpm->{error}(N("...copying failed")); $error = 1 };
			    chown 0, 0, "$urpm->{cachedir}/partial/list";
			}
		    }
		} else {
		    {
			my %f;
			File::Find::find(
			    {
				wanted => sub { -f $_ && /\.rpm$/ and $f{"$File::Find::dir/$_"} = 1 },
				follow_fast => 1,
			    },
			    $dir,
			);
			push @files, keys %f;
		    }

		    #- check files contains something good!
		    if (@files > 0) {
			#- we need to rebuild from rpm files the hdlist.
			eval {
			    $urpm->{log}(N("reading rpm files from [%s]", $dir));
			    my @unresolved_before = grep {
				! defined $urpm->{provides}{$_};
			    } keys %{$urpm->{provides} || {}};
			    $medium->{start} = @{$urpm->{depslist}};
			    $medium->{headers} = [ $urpm->parse_rpms_build_headers(
				dir   => "$urpm->{cachedir}/headers",
				rpms  => \@files,
				clean => $clean_cache,
			    ) ];
			    $medium->{end} = $#{$urpm->{depslist}};
			    if ($medium->{start} > $medium->{end}) {
				#- an error occured (provided there are files in input.)
				delete $medium->{start};
				delete $medium->{end};
				$urpm->{fatal}(9, N("no rpms read"));
			    } else {
				#- make sure the headers will not be removed for another media.
				$clean_cache = 0;
				my @unresolved = grep {
				    ! defined $urpm->{provides}{$_};
				} keys %{$urpm->{provides} || {}};
				@unresolved_before == @unresolved or $second_pass = 1;
			    }
			};
			$@ and $error = 1, $urpm->{error}(N("unable to read rpm files from [%s]: %s", $dir, $@));
			$error and delete $medium->{headers}; #- do not propagate these.
			$error or delete $medium->{synthesis}; #- when building hdlist by ourself, drop synthesis property.
		    } else {
			$error = 1;
			$urpm->{error}(N("no rpm files found from [%s]", $dir));
			$medium->{ignore} = 1;
		    }
		}
	    }

	    #- examine if a local pubkey file is available.
	    if (!$nopubkey && $medium->{hdlist} ne 'pubkey' && !$medium->{'key-ids'}) {
		my $path_pubkey = reduce_pathname("$with_hdlist_dir/../" . _guess_pubkey_name($medium));
		-e $path_pubkey or $path_pubkey = "$dir/pubkey";
		if ($path_pubkey) {
		    urpm::util::copy($path_pubkey, "$urpm->{cachedir}/partial/pubkey")
			or do { $urpm->{error}(N("...copying failed")) };
		}
		chown 0, 0, "$urpm->{cachedir}/partial/pubkey";
	    }
	} else {
	    #- check for a reconfig.urpmi file (if not already reconfigured)
	    if (!$media_redone{$medium->{name}} && !$medium->{noreconfigure}) {
		my $reconfig_urpmi_url = "$medium->{url}/reconfig.urpmi";
		unlink(my $reconfig_urpmi = "$urpm->{cachedir}/partial/reconfig.urpmi");
		eval {
		    $urpm->{sync}(
			{
			    dir => "$urpm->{cachedir}/partial",
			    quiet => 1,
			    limit_rate => $options{limit_rate},
			    compress => $options{compress},
			    proxy => get_proxy($medium->{name}),
			    media => $medium->{name},
			    retry => $urpm->{options}{retry},
			},
			reduce_pathname("$medium->{url}/reconfig.urpmi"),
		    );
		};
		$@ and $urpm->{error}(N("...retrieving failed: %s", $@));
		if (-s $reconfig_urpmi && $urpm->reconfig_urpmi($reconfig_urpmi, $medium->{name})) {
		    $media_redone{$medium->{name}} = 1, redo MEDIA unless $media_redone{$medium->{name}};
		}
		unlink $reconfig_urpmi;
	    }

	    my $basename;

	    #- try to get the description if it has been found.
	    unlink "$urpm->{cachedir}/partial/descriptions";
	    if (-e "$urpm->{statedir}/descriptions.$medium->{name}") {
		urpm::util::move("$urpm->{statedir}/descriptions.$medium->{name}", "$urpm->{cachedir}/partial/descriptions");
	    }
	    my $syncopts = {
		dir => "$urpm->{cachedir}/partial",
		quiet => 1,
		limit_rate => $options{limit_rate},
		compress => $options{compress},
		proxy => get_proxy($medium->{name}),
		retry => $urpm->{options}{retry},
		media => $medium->{name},
	    };
	    eval { $urpm->{sync}($syncopts, reduce_pathname("$medium->{url}/media_info/descriptions")) };
	    #- It is possible that the original fetch of the descriptions
	    #- failed, but the file still remains in partial/ because it was
	    #- moved from $urpm->{statedir} earlier. So we need to check if
	    #- the previous download failed.
	    if ($@ || (! -e "$urpm->{cachedir}/partial/descriptions")) {
		eval {
		    #- try older location
		    $urpm->{sync}($syncopts, reduce_pathname("$medium->{url}/../descriptions"));
		};
	    }
	    $@ and $urpm->{error}(N("...retrieving failed: %s", $@));
	    if (-e "$urpm->{cachedir}/partial/descriptions") {
		urpm::util::move("$urpm->{cachedir}/partial/descriptions", "$urpm->{statedir}/descriptions.$medium->{name}");
	    }

	    #- examine if a distant MD5SUM file is available.
	    #- this will only be done if $with_hdlist is not empty in order to use
	    #- an existing hdlist or synthesis file, and to check if download was good.
	    #- if no MD5SUM is available, do it as before...
	    if ($medium->{with_hdlist}) {
		#- we can assume at this point a basename is existing, but it needs
		#- to be checked for being valid, nothing can be deduced if no MD5SUM
		#- file is present.
		$basename = urpm::download::basename($medium->{with_hdlist});

		unlink "$urpm->{cachedir}/partial/MD5SUM";
		eval {
		    if (!$options{nomd5sum}) {
			$urpm->{sync}(
			    {
				dir => "$urpm->{cachedir}/partial",
				quiet => 1,
				limit_rate => $options{limit_rate},
				compress => $options{compress},
				proxy => get_proxy($medium->{name}),
				media => $medium->{name},
				retry => $urpm->{options}{retry},
			    },
			    reduce_pathname("$medium->{url}/$medium->{with_hdlist}/../MD5SUM"),
			);
		    }
		};
		$@ and $urpm->{error}(N("...retrieving failed: %s", $@));
		if (!$@ && -e "$urpm->{cachedir}/partial/MD5SUM" && -s _ > 32) {
		    recompute_local_md5sum($urpm, $medium, $options{force} >= 2);
		    if ($medium->{md5sum}) {
			$retrieved_md5sum = parse_md5sum($urpm, "$urpm->{cachedir}/partial/MD5SUM", $basename);
			#- if an existing hdlist or synthesis file has the same md5sum, we assume the
			#- files are the same.
			#- if local md5sum is the same as distant md5sum, this means there is no need to
			#- download hdlist or synthesis file again.
			if (defined $retrieved_md5sum && $medium->{md5sum} eq $retrieved_md5sum) {
			    unlink "$urpm->{cachedir}/partial/$basename";
			    #- the medium is now considered not modified.
			    $medium->{modified} = 0;
			    #- XXX we could link the new hdlist to the old one.
			    #- (However links need to be managed. see bug #12391.)
			    #- as previously done, just read synthesis file here, this is enough.
			    $urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
			    ($medium->{start}, $medium->{end}) =
				$urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
			    unless (defined $medium->{start} && defined $medium->{end}) {
				$urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
				($medium->{start}, $medium->{end}) =
				    $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1);
				unless (defined $medium->{start} && defined $medium->{end}) {
				    $urpm->{error}(N("problem reading synthesis file of medium \"%s\"", $medium->{name}));
				    $medium->{ignore} = 1;
				}
			    }
			}
			$medium->{modified} or next MEDIA;
		    }
		} else {
		    #- at this point, we don't if a basename exists and is valid, let probe it later.
		    $basename = undef;
		}
	    }

	    #- try to probe for possible with_hdlist parameter, unless
	    #- it is already defined (and valid).
	    $urpm->{log}(N("retrieving source hdlist (or synthesis) of \"%s\"...", $medium->{name}));
	    $options{callback} and $options{callback}('retrieve', $medium->{name});
	    if ($options{probe_with}) {
		my @probe_list = (
		    $medium->{with_hdlist}
		    ? $medium->{with_hdlist}
		    : _probe_with_try_list(_guess_hdlist_suffix($dir), $options{probe_with})
		);
		foreach my $with_hdlist (@probe_list) {
		    $basename = urpm::download::basename($with_hdlist) or next;
		    $options{force} and unlink "$urpm->{cachedir}/partial/$basename";
		    eval {
			$urpm->{sync}(
			    {
				dir => "$urpm->{cachedir}/partial",
				quiet => $options{quiet},
				limit_rate => $options{limit_rate},
				compress => $options{compress},
				callback => $options{callback},
				proxy => get_proxy($medium->{name}),
				media => $medium->{name},
				retry => $urpm->{options}{retry},
			    },
			    reduce_pathname("$medium->{url}/$with_hdlist"),
			);
		    };
		    $@ and $urpm->{error}(N("...retrieving failed: %s", $@));
		    if (!$@ && -e "$urpm->{cachedir}/partial/$basename" && -s _ > 32) {
			$medium->{with_hdlist} = $with_hdlist;
			$urpm->{log}(N("found probed hdlist (or synthesis) as %s", $medium->{with_hdlist}));
			last; #- found a suitable with_hdlist in the list above.
		    }
		}
	    } else {
		$basename = urpm::download::basename($medium->{with_hdlist});

		#- try to sync (copy if needed) local copy after restored the previous one.
		$options{force} and unlink "$urpm->{cachedir}/partial/$basename";
		unless ($options{force}) {
		    if ($medium->{synthesis}) {
			if (-e "$urpm->{statedir}/synthesis.$medium->{hdlist}") {
			    urpm::util::copy(
				"$urpm->{statedir}/synthesis.$medium->{hdlist}",
				"$urpm->{cachedir}/partial/$basename",
			    ) or $urpm->{error}(N("...copying failed")), $error = 1;
			}
		    } else {
			if (-e "$urpm->{statedir}/$medium->{hdlist}") {
			    urpm::util::copy(
				"$urpm->{statedir}/$medium->{hdlist}",
				"$urpm->{cachedir}/partial/$basename",
			    ) or $urpm->{error}(N("...copying failed")), $error = 1;
			}
		    }
		    chown 0, 0, "$urpm->{cachedir}/partial/$basename";
		}
		eval {
		    $urpm->{sync}(
			{
			    dir => "$urpm->{cachedir}/partial",
			    quiet => $options{quiet},
			    limit_rate => $options{limit_rate},
			    compress => $options{compress},
			    callback => $options{callback},
			    proxy => get_proxy($medium->{name}),
			    media => $medium->{name},
			    retry => $urpm->{options}{retry},
			},
			reduce_pathname("$medium->{url}/$medium->{with_hdlist}"),
		    );
		};
		if ($@) {
		    $urpm->{error}(N("...retrieving failed: %s", $@));
		    unlink "$urpm->{cachedir}/partial/$basename";
		}
	    }

	    #- check downloaded file has right signature.
	    if (-e "$urpm->{cachedir}/partial/$basename" && -s _ > 32 && $retrieved_md5sum) {
		$urpm->{log}(N("computing md5sum of retrieved source hdlist (or synthesis)"));
		unless (md5sum("$urpm->{cachedir}/partial/$basename") eq $retrieved_md5sum) {
		    $urpm->{error}(N("...retrieving failed: md5sum mismatch"));
		    unlink "$urpm->{cachedir}/partial/$basename";
		}
	    }

	    if (-e "$urpm->{cachedir}/partial/$basename" && -s _ > 32) {
		$options{callback} and $options{callback}('done', $medium->{name});
		$urpm->{log}(N("...retrieving done"));

		unless ($options{force}) {
		    my @sstat = stat "$urpm->{cachedir}/partial/$basename";
		    my @lstat = stat "$urpm->{statedir}/$medium->{hdlist}";
		    if ($sstat[7] == $lstat[7] && $sstat[9] == $lstat[9]) {
			#- the two files are considered equal here, the medium is so not modified.
			$medium->{modified} = 0;
			unlink "$urpm->{cachedir}/partial/$basename";
			#- as previously done, just read synthesis file here, this is enough.
			$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
			($medium->{start}, $medium->{end}) =
			    $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
			unless (defined $medium->{start} && defined $medium->{end}) {
			    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
			    ($medium->{start}, $medium->{end}) =
				$urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1);
			    unless (defined $medium->{start} && defined $medium->{end}) {
				$urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $medium->{name}));
				$medium->{ignore} = 1;
			    }
			}
			next MEDIA;
		    }
		}

		#- the files are different, update local copy.
		rename("$urpm->{cachedir}/partial/$basename", "$urpm->{cachedir}/partial/$medium->{hdlist}");

		#- retrieval of hdlist or synthesis has been successful,
		#- check whether a list file is available.
		#- and check hdlist wasn't named very strangely...
		if ($medium->{hdlist} ne 'list') {
		    my $local_list = $medium->{with_hdlist} =~ /hd(list.*)\.cz2?$/ ? $1 : 'list';
		    foreach (reduce_pathname("$medium->{url}/$medium->{with_hdlist}/../$local_list"),
			     reduce_pathname("$medium->{url}/list"),
			    ) {
			eval {
			    $urpm->{sync}(
				{
				    dir => "$urpm->{cachedir}/partial",
				    quiet => 1,
				    limit_rate => $options{limit_rate},
				    compress => $options{compress},
				    proxy => get_proxy($medium->{name}),
				    media => $medium->{name},
				    retry => $urpm->{options}{retry},
				},
				$_
			    );
			    $local_list ne 'list' && -e "$urpm->{cachedir}/partial/$local_list" && -s _
				and rename(
				    "$urpm->{cachedir}/partial/$local_list",
				    "$urpm->{cachedir}/partial/list");
			};
			if ($@) {
			    $urpm->{error}(N("...retrieving failed: %s", $@));
			    unlink "$urpm->{cachedir}/partial/list";
			}
			-s "$urpm->{cachedir}/partial/list" and last;
		    }
		}

		#- retrieve pubkey file.
		if (!$nopubkey && $medium->{hdlist} ne 'pubkey' && !$medium->{'key-ids'}) {
		    my $local_pubkey = _guess_pubkey_name($medium);
		    foreach (reduce_pathname("$medium->{url}/$medium->{with_hdlist}/../$local_pubkey"),
			     reduce_pathname("$medium->{url}/pubkey"),
			    ) {
			eval {
			    $urpm->{sync}(
				{
				    dir => "$urpm->{cachedir}/partial",
				    quiet => 1,
				    limit_rate => $options{limit_rate},
				    compress => $options{compress},
				    proxy => get_proxy($medium->{name}),
				    media => $medium->{name},
				    retry => $urpm->{options}{retry},
				},
				$_,
			    );
			    $local_pubkey ne 'pubkey' && -e "$urpm->{cachedir}/partial/$local_pubkey" && -s _
				and rename(
				    "$urpm->{cachedir}/partial/$local_pubkey",
				    "$urpm->{cachedir}/partial/pubkey");
			};
			if ($@) {
			    $urpm->{error}(N("...retrieving failed: %s", $@));
			    unlink "$urpm->{cachedir}/partial/pubkey";
			}
			-s "$urpm->{cachedir}/partial/pubkey" and last;
		    }
		}
	    } else {
		$error = 1;
		$options{callback} and $options{callback}('failed', $medium->{name});
		$urpm->{error}(N("retrieval of source hdlist (or synthesis) failed"));
	    }
	}

	#- build list file according to hdlist.
	unless ($medium->{headers} || -e "$urpm->{cachedir}/partial/$medium->{hdlist}" && -s _ > 32) {
	    $error = 1;
	    $urpm->{error}(N("no hdlist file found for medium \"%s\"", $medium->{name}));
	}

	unless ($error || $medium->{virtual}) {
	    #- sort list file contents according to id.
	    my %list;
	    if ($medium->{headers}) {
		#- rpm files have already been read (first pass), there is just a need to
		#- build list hash.
		foreach (@files) {
		    m|/([^/]*\.rpm)$| or next;
		    $list{$1} and $urpm->{error}(N("file [%s] already used in the same medium \"%s\"", $1, $medium->{name})), next;
		    $list{$1} = "$prefix:/$_\n";
		}
	    } else {
		#- read first pass hdlist or synthesis, try to open as synthesis, if file
		#- is larger than 1MB, this is probably an hdlist else a synthesis.
		#- anyway, if one tries fails, try another mode.
		$options{callback} and $options{callback}('parse', $medium->{name});
		my @unresolved_before = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};
		if (!$medium->{synthesis}
		    || -e "$urpm->{cachedir}/partial/$medium->{hdlist}" && -s _ > 262144)
		{
		    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
		    ($medium->{start}, $medium->{end}) =
			     $urpm->parse_hdlist("$urpm->{cachedir}/partial/$medium->{hdlist}", 1);
		    if (defined $medium->{start} && defined $medium->{end}) {
			delete $medium->{synthesis};
		    } else {
			$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
			($medium->{start}, $medium->{end}) =
				 $urpm->parse_synthesis("$urpm->{cachedir}/partial/$medium->{hdlist}");
			defined $medium->{start} && defined $medium->{end} and $medium->{synthesis} = 1;
		    }
		} else {
		    $urpm->{log}(N("examining synthesis file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
		    ($medium->{start}, $medium->{end}) =
			     $urpm->parse_synthesis("$urpm->{cachedir}/partial/$medium->{hdlist}");
		    if (defined $medium->{start} && defined $medium->{end}) {
			$medium->{synthesis} = 1;
		    } else {
			$urpm->{log}(N("examining hdlist file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
			($medium->{start}, $medium->{end}) =
				 $urpm->parse_hdlist("$urpm->{cachedir}/partial/$medium->{hdlist}", 1);
			defined $medium->{start} && defined $medium->{end} and delete $medium->{synthesis};
		    }
		}
		if (defined $medium->{start} && defined $medium->{end}) {
		    $options{callback} && $options{callback}('done', $medium->{name});
		} else {
		    $error = 1;
		    $urpm->{error}(N("unable to parse hdlist file of \"%s\"", $medium->{name}));
		    $options{callback} && $options{callback}('failed', $medium->{name});
		    #- we will have to read back the current synthesis file unmodified.
		}

		unless ($error) {
		    my @unresolved_after = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};
		    @unresolved_before == @unresolved_after or $second_pass = 1;

		    if ($medium->{hdlist} ne 'list' && -s "$urpm->{cachedir}/partial/list") {
			if (open my $fh, "$urpm->{cachedir}/partial/list") {
			    local $_;
			    while (<$fh>) {
				m|/([^/]*\.rpm)$| or next;
				$list{$1} and $urpm->{error}(N("file [%s] already used in the same medium \"%s\"", $1, $medium->{name})), next;
				$list{$1} = "$medium->{url}/$_";
			    }
			    close $fh;
			}
		    } else {
			#- if url is clear and no relative list file has been downloaded,
			#- there is no need for a list file.
			if ($medium->{url} ne $medium->{clear_url}) {
			    foreach ($medium->{start} .. $medium->{end}) {
				my $filename = $urpm->{depslist}[$_]->filename;
				$list{$filename} = "$medium->{url}/$filename\n";
			    }
			}
		    }
		}
	    }

	    unless ($error) {
		if (keys %list) {
		    #- write list file.
		    #- make sure group and other do not have any access to this file, used to hide passwords.
		    if ($medium->{list}) {
			my $mask = umask 077;
			open my $listfh, ">$urpm->{cachedir}/partial/$medium->{list}"
			    or $error = 1, $urpm->{error}(N("unable to write list file of \"%s\"", $medium->{name}));
			umask $mask;
			print $listfh values %list;
			close $listfh;
		    }

		    #- check if at least something has been written into list file.
		    if ($medium->{list} && -s "$urpm->{cachedir}/partial/$medium->{list}") {
			$urpm->{log}(N("writing list file for medium \"%s\"", $medium->{name}));
		    } else {
			$error = 1, $urpm->{error}(N("nothing written in list file for \"%s\"", $medium->{name}));
		    }
		} else {
		    #- the flag is no longer necessary.
		    if ($medium->{list}) {
			unlink "$urpm->{statedir}/$medium->{list}";
			delete $medium->{list};
		    }
		}
	    }
	}

	unless ($error) {
	    #- now... on pubkey
	    if (-s "$urpm->{cachedir}/partial/pubkey") {
		$urpm->{log}(N("examining pubkey file of \"%s\"...", $medium->{name}));
		my %key_ids;
		$urpm->import_needed_pubkeys([ $urpm->parse_armored_file("$urpm->{cachedir}/partial/pubkey") ],
					     root => $urpm->{root}, callback => sub {
						 my (undef, undef, $k, $id, $imported) = @_;
						 if ($id) {
						     $key_ids{$id} = undef;
						     $imported and $urpm->{log}(N("...imported key %s from pubkey file of \"%s\"",
										  $id, $medium->{name}));
						 } else {
						     $urpm->{error}(N("unable to import pubkey file of \"%s\"", $medium->{name}));
						 }
					     });
		keys(%key_ids) and $medium->{'key-ids'} = join ',', keys %key_ids;
	    }
	}

	unless ($medium->{virtual}) {
	    if ($error) {
		#- an error has occured for updating the medium, we have to remove temporary files.
		unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
		$medium->{list} and unlink "$urpm->{cachedir}/partial/$medium->{list}";
		#- read default synthesis (we have to make sure nothing get out of depslist).
		$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
		($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
		unless (defined $medium->{start} && defined $medium->{end}) {
		    $urpm->{error}(N("problem reading synthesis file of medium \"%s\"", $medium->{name}));
		    $medium->{ignore} = 1;
		}
	    } else {
		#- make sure to rebuild base files and clear medium modified state.
		$medium->{modified} = 0;
		$urpm->{modified} = 1;

		#- but use newly created file.
		unlink "$urpm->{statedir}/$medium->{hdlist}";
		$medium->{synthesis} and unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
		$medium->{list} and unlink "$urpm->{statedir}/$medium->{list}";
		unless ($medium->{headers}) {
		    unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
		    unlink "$urpm->{statedir}/$medium->{hdlist}";
		    urpm::util::move("$urpm->{cachedir}/partial/$medium->{hdlist}",
			$medium->{synthesis}
			    ? "$urpm->{statedir}/synthesis.$medium->{hdlist}"
			    : "$urpm->{statedir}/$medium->{hdlist}"
		    );
		}
		if ($medium->{list}) {
		    urpm::util::move("$urpm->{cachedir}/partial/$medium->{list}", "$urpm->{statedir}/$medium->{list}");
		}
		$medium->{md5sum} = $retrieved_md5sum; #- anyway, keep it, the previous one is no longer useful.

		#- and create synthesis file associated.
		$medium->{modified_synthesis} = !$medium->{synthesis};
	    }
	}
    }

    #- some unresolved provides may force to rebuild all synthesis,
    #- a second pass will be necessary.
    if ($second_pass) {
	$urpm->{log}(N("performing second pass to compute dependencies\n"));
	$urpm->unresolved_provides_clean;
    }

    #- second pass consists in reading again synthesis or hdlists.
    foreach my $medium (@{$urpm->{media}}) {
	#- take care of modified medium only, or all if all have to be recomputed.
	$medium->{ignore} and next;

	$options{callback} and $options{callback}('parse', $medium->{name});
	#- a modified medium is an invalid medium, we have to read back the previous hdlist
	#- or synthesis which has not been modified by first pass above.
	if ($medium->{headers} && !$medium->{modified}) {
	    if ($second_pass) {
		$urpm->{log}(N("reading headers from medium \"%s\"", $medium->{name}));
		($medium->{start}, $medium->{end}) = $urpm->parse_headers(dir     => "$urpm->{cachedir}/headers",
									  headers => $medium->{headers},
									 );
	    }
	    $urpm->{log}(N("building hdlist [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
	    #- finish building operation of hdlist.
	    $urpm->build_hdlist(start  => $medium->{start},
				end    => $medium->{end},
				dir    => "$urpm->{cachedir}/headers",
				hdlist => "$urpm->{statedir}/$medium->{hdlist}",
			       );
	    #- synthesis needs to be created, since the medium has been built from rpm files.
	    eval { $urpm->build_synthesis(
	        start     => $medium->{start},
	        end       => $medium->{end},
	        synthesis => "$urpm->{statedir}/synthesis.$medium->{hdlist}",
	    ) };
	    if ($@) {
		#- XXX this happens when building a synthesis for a local media from RPMs... why ?
		$urpm->{error}(N("Unable to build synthesis file for medium \"%s\". Your hdlist file may be corrupted.", $medium->{name}));
		$urpm->{error}($@);
		unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
	    } else {
		$urpm->{log}(N("built hdlist synthesis file for medium \"%s\"", $medium->{name}));
	    }
	    #- keep in mind we have a modified database, sure at this point.
	    $urpm->{modified} = 1;
	} elsif ($medium->{synthesis}) {
	    if ($second_pass) {
		if ($medium->{virtual}) {
		    my ($path) = $medium->{url} =~ m!^(?:file:/*)?(/[^/].*[^/])/*\Z!;
		    my $with_hdlist_file = "$path/$medium->{with_hdlist}";
		    if ($path) {
			$urpm->{log}(N("examining synthesis file [%s]", $with_hdlist_file));
			($medium->{start}, $medium->{end}) = $urpm->parse_synthesis($with_hdlist_file);
		    }
		} else {
		    $urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
		    ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
		}
	    }
	} else {
	    if ($second_pass) {
		$urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
		($medium->{start}, $medium->{end}) = $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", 1);
	    }
	    #- check if the synthesis file can be built.
	    if (($second_pass || $medium->{modified_synthesis}) && !$medium->{modified}) {
		unless ($medium->{virtual}) {
		    eval { $urpm->build_synthesis(
			start     => $medium->{start},
			end       => $medium->{end},
			synthesis => "$urpm->{statedir}/synthesis.$medium->{hdlist}",
		    ) };
		    if ($@) {
			$urpm->{error}(N("Unable to build synthesis file for medium \"%s\". Your hdlist file may be corrupted.", $medium->{name}));
			$urpm->{error}($@);
			unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
		    } else {
			$urpm->{log}(N("built hdlist synthesis file for medium \"%s\"", $medium->{name}));
		    }
		}
		#- keep in mind we have modified database, sure at this point.
		$urpm->{modified} = 1;
	    }
	}
	$options{callback} && $options{callback}('done', $medium->{name});
    }

    #- clean headers cache directory to remove everything that is no longer
    #- useful according to the depslist.
    if ($urpm->{modified}) {
	if ($options{noclean}) {
	    local $_;
	    my %headers;
	    my $dh = $urpm->opendir_safe("$urpm->{cachedir}/headers");
	    if ($dh) {
		while (defined($_ = readdir $dh)) {
		    m|^([^/]*-[^-]*-[^-]*\.[^\.]*)(?::\S*)?$| and $headers{$1} = $_;
		}
		closedir $dh;
	    }
	    $urpm->{log}(N("found %d headers in cache", scalar(keys %headers)));
	    foreach (@{$urpm->{depslist}}) {
		delete $headers{$_->fullname};
	    }
	    $urpm->{log}(N("removing %d obsolete headers in cache", scalar(keys %headers)));
	    foreach (values %headers) {
		unlink "$urpm->{cachedir}/headers/$_";
	    }
	}

	#- write config files in any case
	$urpm->write_config;
	dump_proxy_config();
    }

    #- make sure names files are regenerated.
    foreach (@{$urpm->{media}}) {
	unlink "$urpm->{statedir}/names.$_->{name}";
	if (defined $_->{start} && defined $_->{end}) {
	    my $fh = $urpm->open_safe(">", "$urpm->{statedir}/names.$_->{name}");
	    if ($fh) {
		foreach ($_->{start} .. $_->{end}) {
		    if (defined $urpm->{depslist}[$_]) {
			print $fh $urpm->{depslist}[$_]->name . "\n";
		    } else {
			$urpm->{error}(N("Error generating names file: dependency %d not found", $_));
		    }
		}
		close $fh;
	    } else {
		$urpm->{error}(N("Error generating names file: Can't write to file (%s)", $!));
	    }
	}
    }

    $options{nolock} or $urpm->unlock_urpmi_db;
    $nopubkey or $urpm->unlock_rpm_db;
}

#- clean params and depslist computation zone.
sub clean {
    my ($urpm) = @_;

    $urpm->{depslist} = [];
    $urpm->{provides} = {};

    foreach (@{$urpm->{media} || []}) {
	delete $_->{start};
	delete $_->{end};
    }
}

sub try_mounting {
    my ($urpm, $dir, $removable) = @_;
    my %infos;

    my $is_iso = is_iso($removable);
    my @mntpoints = $is_iso
	#- note: for isos, we don't parse the fstab because it might not be declared in it.
	#- so we try to remove suffixes from the dir name until the dir exists
	? ($dir = urpm::sys::trim_until_d($dir))
	: urpm::sys::find_mntpoints($dir = reduce_pathname($dir), \%infos);
    foreach (grep {
	    ! $infos{$_}{mounted} && $infos{$_}{fs} ne 'supermount';
	} @mntpoints)
    {
	$urpm->{log}(N("mounting %s", $_));
	if ($is_iso) {
	    #- to mount an iso image, grab the first loop device
	    my $loopdev = urpm::sys::first_free_loopdev();
	    sys_log("mount iso $_ on $removable");
	    $loopdev and system("mount '$removable' '$_' -t iso9660 -o loop=$loopdev");
	} else {
	    sys_log("mount $_");
	    system("mount '$_' 2>/dev/null");
	}
	$removable && $infos{$_}{fs} ne 'supermount' and $urpm->{removable_mounted}{$_} = undef;
    }
    -e $dir;
}

sub try_umounting {
    my ($urpm, $dir) = @_;
    my %infos;

    $dir = reduce_pathname($dir);
    foreach (reverse grep {
	    $infos{$_}{mounted} && $infos{$_}{fs} ne 'supermount';
	} urpm::sys::find_mntpoints($dir, \%infos))
    {
	$urpm->{log}(N("unmounting %s", $_));
	sys_log("umount $_");
	system("umount '$_' 2>/dev/null");
	delete $urpm->{removable_mounted}{$_};
    }
    ! -e $dir;
}

sub try_umounting_removables {
    my ($urpm) = @_;
    foreach (keys %{$urpm->{removable_mounted}}) {
	$urpm->try_umounting($_);
    }
    delete $urpm->{removable_mounted};
}

#- register local packages for being installed, keep track of source.
sub register_rpms {
    my ($urpm, @files) = @_;
    my ($start, $id, $error, %requested);

    #- examine each rpm and build the depslist for them using current
    #- depslist and provides environment.
    $start = @{$urpm->{depslist}};
    foreach (@files) {
	/\.(?:rpm|spec)$/ or $error = 1, $urpm->{error}(N("invalid rpm file name [%s]", $_)), next;

	#- if that's an URL, download.
	if (my ($basename) = m{^[^:]*:/.*/([^/]*\.(?:rpm|spec))\z}) {
	    unlink "$urpm->{cachedir}/partial/$basename";
	    eval {
		$urpm->{log}(N("retrieving rpm file [%s] ...", $_));
		$urpm->{sync}(
		    {
			dir => "$urpm->{cachedir}/partial",
			quiet => 1,
			proxy => get_proxy(),
		    },
		    $_,
		);
		$urpm->{log}(N("...retrieving done"));
		$_ = "$urpm->{cachedir}/partial/$basename";
	    };
	    if ($@) {
		$urpm->{error}(N("...retrieving failed: %s", $@));
		unlink "$urpm->{cachedir}/partial/$basename";
		next;
	    }
	} else {
	    -r $_ or $error = 1, $urpm->{error}(N("unable to access rpm file [%s]", $_)), next;
	}

	if (/\.spec$/) {
	    my $pkg = URPM::spec2srcheader($_)
		or $error = 1, $urpm->{error}(N("unable to parse spec file %s [%s]", $_, $!)), next;
	    $id = @{$urpm->{depslist}};
	    $urpm->{depslist}[$id] = $pkg;
	    #- It happens that URPM sets an internal id to the depslist id.
	    #- We need to set it by hand here.
	    $pkg->set_id($id);
	    $urpm->{source}{$id} = $_;
	} else {
	    ($id) = $urpm->parse_rpm($_);
	    my $pkg = defined $id && $urpm->{depslist}[$id];
	    $pkg or $error = 1, $urpm->{error}(N("unable to register rpm file")), next;
	    $pkg->arch eq 'src' || $pkg->is_arch_compat()
		or $error = 1, $urpm->{error}(N("Incompatible architecture for rpm [%s]", $_)), next;
	    $urpm->{source}{$id} = $_;
	}
    }
    $error and $urpm->{fatal}(2, N("error registering local packages"));
    defined $id && $start <= $id and @requested{($start .. $id)} = (1) x ($id-$start+1);

    #- distribute local packages to distant nodes directly in cache of each machine.
    @files && $urpm->{parallel_handler} and $urpm->{parallel_handler}->parallel_register_rpms(@_);

    %requested;
}

sub _findindeps {
    my ($urpm, $found, $v, %options) = @_;
    my @list = grep { defined $_ } map {
	my $pkg = $urpm->{depslist}[$_];
	$pkg
	&& ($options{src} ? $pkg->arch eq 'src' : $pkg->arch ne 'src')
	? $pkg->id : undef;
    } keys %{$urpm->{provides}{$_} || {}};
    @list > 0 and push @{$found->{$v}}, join '|', @list;
}

#- search packages registered by their names by storing their ids into the $packages hash.
sub search_packages {
    my ($urpm, $packages, $names, %options) = @_;
    my (%exact, %exact_a, %exact_ra, %found, %foundi);
    foreach my $v (@$names) {
	my $qv = quotemeta $v;
	$qv = '(?i)' . $qv if $options{caseinsensitive};

	unless ($options{fuzzy}) {
	    #- try to search through provides.
	    if (my @l = map {
		    $_
		    && ($options{src} ? $_->arch eq 'src' : $_->is_arch_compat)
		    && ($options{use_provides} || $_->name eq $v)
		    && defined($_->id)
		    && (!defined $urpm->{searchmedia} || (
			    $urpm->{searchmedia}{start} <= $_->id
		    	    && $urpm->{searchmedia}{end} >= $_->id))
		    ? $_ : @{[]};
		} map {
		    $urpm->{depslist}[$_];
		} keys %{$urpm->{provides}{$v} || {}})
	    {
		#- we assume that if there is at least one package providing
		#- the resource exactly, this should be the best one; but we
		#- first check if one of the packages has the same name as searched.
		if ((my @l2) = grep { $_->name eq $v } @l) {
		    $exact{$v} = join '|', map { $_->id } @l2;
		} else {
		    $exact{$v} = join '|', map { $_->id } @l;
		}
		next;
	    }
	}

	if ($options{use_provides} && $options{fuzzy}) {
	    foreach (keys %{$urpm->{provides}}) {
		#- search through provides to find if a provide matches this one;
		#- but manage choices correctly (as a provides may be virtual or
		#- defined several times).
		if (/$qv/ || (!$options{caseinsensitive} && /$qv/i)) {
		    $urpm->_findindeps(\%found, $v, %options);
		}
	    }
	}

	foreach my $id (defined $urpm->{searchmedia} ?
	    ($urpm->{searchmedia}{start} .. $urpm->{searchmedia}{end}) :
	    (0 .. $#{$urpm->{depslist}})
	) {
	    my $pkg = $urpm->{depslist}[$id];
	    ($options{src} ? $pkg->arch eq 'src' : $pkg->is_arch_compat) or next;
	    my $pack_name = $pkg->name;
	    my $pack_ra = $pack_name . '-' . $pkg->version;
	    my $pack_a = "$pack_ra-" . $pkg->release;
	    my $pack = "$pack_a." . $pkg->arch;
	    unless ($options{fuzzy}) {
		if ($pack eq $v) {
		    $exact{$v} = $id;
		    next;
		} elsif ($pack_a eq $v) {
		    push @{$exact_a{$v}}, $id;
		    next;
		} elsif ($pack_ra eq $v || $options{src} && $pack_name eq $v) {
		    push @{$exact_ra{$v}}, $id;
		    next;
		}
	    }
	    $pack =~ /$qv/ and push @{$found{$v}}, $id;
	    $pack =~ /$qv/i and push @{$foundi{$v}}, $id unless $options{caseinsensitive};
	}
    }

    my $result = 1;
    foreach (@$names) {
	if (defined $exact{$_}) {
	    $packages->{$exact{$_}} = 1;
	    foreach (split /\|/, $exact{$_}) {
		my $pkg = $urpm->{depslist}[$_] or next;
		$pkg->set_flag_skip(0); #- reset skip flag as manually selected.
	    }
	} else {
	    #- at this level, we need to search the best package given for a given name,
	    #- always prefer already found package.
	    my %l;
	    foreach (@{$exact_a{$_} || $exact_ra{$_} || $found{$_} || $foundi{$_} || []}) {
		my $pkg = $urpm->{depslist}[$_];
		push @{$l{$pkg->name}}, $pkg;
	    }
	    if (values(%l) == 0 || values(%l) > 1 && !$options{all}) {
		$urpm->{error}(N("no package named %s", $_));
		values(%l) != 0 and $urpm->{error}(
		    N("The following packages contain %s: %s",
			$_, "\n" . join("\n", sort { $a cmp $b } keys %l))
		);
		$result = 0;
	    } else {
		foreach (values %l) {
		    my $best;
		    foreach (@$_) {
			if ($best && $best != $_) {
			    $_->compare_pkg($best) > 0 and $best = $_;
			} else {
			    $best = $_;
			}
		    }
		    $packages->{$best->id} = 1;
		    $best->set_flag_skip(0); #- reset skip flag as manually selected.
		}
	    }
	}
    }

    #- return true if no error has been encountered, else false.
    $result;
}

#- Resolves dependencies between requested packages (and auto selection if any).
#- handles parallel option if any.
#- The return value is true if program should be restarted (in order to take
#- care of important packages being upgraded (priority upgrades)
#- %options :
#-	rpmdb
#-	auto_select
#-	callback_choices
#-	install_src
#-	keep
#-	nodeps
#-	priority_upgrade
sub resolve_dependencies {
    #- $state->{selected} will contain the selection of packages to be
    #- installed or upgraded
    my ($urpm, $state, $requested, %options) = @_;
    my $need_restart;

    if ($options{install_src}) {
	#- only src will be installed, so only update $state->{selected} according
	#- to src status of files.
	foreach (keys %$requested) {
	    my $pkg = $urpm->{depslist}[$_] or next;
	    $pkg->arch eq 'src' or next;
	    $state->{selected}{$_} = undef;
	}
    }
    if ($urpm->{parallel_handler}) {
	#- build the global synthesis file first.
	my $file = "$urpm->{cachedir}/partial/parallel.cz";
	unlink $file;
	foreach (@{$urpm->{media}}) {
	    defined $_->{start} && defined $_->{end} or next;
	    system "cat '$urpm->{statedir}/synthesis.$_->{hdlist}' >> '$file'";
	}
	#- let each node determine what is requested, according to handler given.
	$urpm->{parallel_handler}->parallel_resolve_dependencies($file, @_);
    } else {
	my $db;

	if ($options{rpmdb}) {
	    $db = new URPM;
	    $db->parse_synthesis($options{rpmdb});
	} else {
	    $db = URPM::DB::open($urpm->{root});
	    $db or $urpm->{fatal}(9, N("unable to open rpmdb"));
	}

	my $sig_handler = sub { undef $db; exit 3 };
	local $SIG{INT} = $sig_handler;
	local $SIG{QUIT} = $sig_handler;

	#- auto select package for upgrading the distribution.
	if ($options{auto_select}) {
	    $urpm->request_packages_to_upgrade($db, $state, $requested, requested => undef,
    		start => $urpm->{searchmedia}{start}, end => $urpm->{searchmedia}{end});
	}

	#- resolve dependencies which will be examined for packages that need to
	#- have urpmi restarted when they're updated.
	$urpm->resolve_requested($db, $state, $requested, %options);

	if ($options{priority_upgrade} && !$options{rpmdb}) {
	    my (%priority_upgrade, %priority_requested);
	    @priority_upgrade{split /,/, $options{priority_upgrade}} = ();

	    #- check if a priority upgrade should be tried
	    foreach (keys %{$state->{selected}}) {
		my $pkg = $urpm->{depslist}[$_] or next;
		exists $priority_upgrade{$pkg->name} or next;
		$priority_requested{$pkg->id} = undef;
	    }

	    if (%priority_requested) {
		my %priority_state;

		$urpm->resolve_requested($db, \%priority_state, \%priority_requested, %options);
		if (grep { ! exists $priority_state{selected}{$_} } keys %priority_requested) {
		    #- some packages which were selected previously have not been selected, strange!
		    $need_restart = 0;
		} elsif (grep { ! exists $priority_state{selected}{$_} } keys %{$state->{selected}}) {
		    #- there are other packages to install after this priority transaction.
		    %$state = %priority_state;
		    $need_restart = 1;
		}
	    }
	}
    }
    $need_restart;
}

sub create_transaction {
    my ($urpm, $state, %options) = @_;

    if ($urpm->{parallel_handler} || !$options{split_length} ||
	keys %{$state->{selected}} < $options{split_level}) {
	#- build simplest transaction (no split).
	$urpm->build_transaction_set(undef, $state, split_length => 0);
    } else {
	my $db;

	if ($options{rpmdb}) {
	    $db = new URPM;
	    $db->parse_synthesis($options{rpmdb});
	} else {
	    $db = URPM::DB::open($urpm->{root});
	    $db or $urpm->{fatal}(9, N("unable to open rpmdb"));
	}

	my $sig_handler = sub { undef $db; exit 3 };
	local $SIG{INT} = $sig_handler;
	local $SIG{QUIT} = $sig_handler;

	#- build transaction set...
	$urpm->build_transaction_set($db, $state, split_length => $options{split_length});
    }
}

#- get the list of packages that should not be upgraded or installed,
#- typically from the inst.list or skip.list files.
sub get_packages_list {
    my ($file, $extra) = @_;
    my $val = [];
    open my $f, $file or return [];
    foreach (<$f>, split /,/, $extra || '') {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	next if $_ eq '';
	push @$val, $_;
    }
    close $f;
    $val;
}

#- select sources for selected packages,
#- according to keys of the packages hash.
#- returns a list of lists containing the source description for each rpm,
#- matching the exact number of registered media; ignored media being
#- associated to a null list.
sub get_source_packages {
    my ($urpm, $packages, %options) = @_;
    my ($id, $error, @list_error, %protected_files, %local_sources, @list, %fullname2id, %file2fullnames, %examined);
    local $_;

    #- build association hash to retrieve id and examine all list files.
    foreach (keys %$packages) {
	foreach (split /\|/, $_) {
	    if ($urpm->{source}{$_}) {
		$protected_files{$local_sources{$_} = $urpm->{source}{$_}} = undef;
	    } else {
		$fullname2id{$urpm->{depslist}[$_]->fullname} = $_ . '';
	    }
	}
    }

    #- examine each medium to search for packages.
    #- now get rpm file name in hdlist to match list file.
    foreach my $pkg (@{$urpm->{depslist} || []}) {
	$file2fullnames{$pkg->filename}{$pkg->fullname} = undef;
    }

    #- examine the local repository, which is trusted (no gpg or pgp signature check but md5 is now done).
    my $dh = $urpm->opendir_safe("$urpm->{cachedir}/rpms");
    if ($dh) {
	while (defined(my $filename = readdir $dh)) {
	    my $filepath = "$urpm->{cachedir}/rpms/$filename";
	    next if -d $filepath;
	    if (!$options{clean_all} && -s _) {
		if (keys(%{$file2fullnames{$filename} || {}}) > 1) {
		    $urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\"", $filename));
		    next;
		} elsif (keys(%{$file2fullnames{$filename} || {}}) == 1) {
		    my ($fullname) = keys(%{$file2fullnames{$filename} || {}});
		    if (defined($id = delete $fullname2id{$fullname})) {
			$local_sources{$id} = $filepath;
		    } else {
			$options{clean_other} && ! exists $protected_files{$filepath} and unlink $filepath;
		    }
		} else {
		    $options{clean_other} && ! exists $protected_files{$filepath} and unlink $filepath;
		}
	    } else {
		unlink $filepath; #- this file should be removed or is already empty.
	    }
	}
	closedir $dh;
    }

    #- clean download directory, do it here even if this is not the best moment.
    if ($options{clean_all}) {
	require File::Path;
	File::Path::rmtree(["$urpm->{cachedir}/partial"]);
	mkdir "$urpm->{cachedir}/partial", 0755;
    }

    foreach my $medium (@{$urpm->{media} || []}) {
	my (%sources, %list_examined, $list_warning);

	if (defined $medium->{start} && defined $medium->{end} && !$medium->{ignore}) {
	    #- always prefer a list file if available.
	    my $listfile = $medium->{list} ? "$urpm->{statedir}/$medium->{list}" : '';
	    if (!$listfile && $medium->{virtual}) {
		my ($dir) = $medium->{url} =~ m!^(?:removable[^:]*:/|file:/)?(/.*)!;
		my $with_hdlist_dir = reduce_pathname($dir . ($medium->{with_hdlist} ? "/$medium->{with_hdlist}" : "/.."));
		my $local_list = $medium->{with_hdlist} =~ /hd(list.*)\.cz2?$/ ? $1 : 'list';
		$listfile = reduce_pathname("$with_hdlist_dir/../$local_list");
		-s $listfile or $listfile = "$dir/list";
	    }
	    if ($listfile && -r $listfile) {
		my $fh = $urpm->open_safe('<', $listfile);
		if ($fh) {
		    while (<$fh>) {
			chomp;
			if (my ($filename) = m|/([^/]*\.rpm)$|) {
			    if (keys(%{$file2fullnames{$filename} || {}}) > 1) {
				$urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\"", $filename));
				next;
			    } elsif (keys(%{$file2fullnames{$filename} || {}}) == 1) {
				my ($fullname) = keys(%{$file2fullnames{$filename} || {}});
				if (defined($id = $fullname2id{$fullname})) {
				    if (!/\.delta\.rpm$/ || $urpm->is_delta_installable($urpm->{depslist}[$id], $options{root})) {
					$sources{$id} = $medium->{virtual} ? "$medium->{url}/$_" : $_;
				    }
				}
				$list_examined{$fullname} = $examined{$fullname} = undef;
			    }
			} else {
			    chomp;
			    $error = 1;
			    $urpm->{error}(N("unable to correctly parse [%s] on value \"%s\"", $listfile, $_));
			    last;
			}
		    }
		    close $fh;
		}
	    } elsif ($listfile && -e $listfile) {
		# list file exists but isn't readable
		# report error only if no result found, list files are only readable by root
		push @list_error, N("unable to access list file of \"%s\", medium ignored", $medium->{name});
		$< and push @list_error, "    " . N("(retry as root?)");
		next;
	    }
	    if (defined $medium->{url}) {
		foreach ($medium->{start} .. $medium->{end}) {
		    my $pkg = $urpm->{depslist}[$_];
		    my $fi = $pkg->filename;
		    if (keys(%{$file2fullnames{$fi} || {}}) > 1) {
			$urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\"", $fi));
			next;
		    } elsif (keys(%{$file2fullnames{$fi} || {}}) == 1) {
			my ($fullname) = keys(%{$file2fullnames{$fi} || {}});
			unless (exists($list_examined{$fullname})) {
			    ++$list_warning;
			    if (defined($id = $fullname2id{$fullname})) {
				if ($fi !~ /\.delta\.rpm$/ || $urpm->is_delta_installable($urpm->{depslist}[$id], $options{root})) {
				    $sources{$id} = "$medium->{url}/" . $fi;
				}
			    }
			    $examined{$fullname} = undef;
			}
		    }
		}
		$list_warning && $medium->{list} && -r "$urpm->{statedir}/$medium->{list}" && -f _
		    and $urpm->{error}(N("medium \"%s\" uses an invalid list file:
  mirror is probably not up-to-date, trying to use alternate method", $medium->{name}));
	    } elsif (!%list_examined) {
		$error = 1;
		$urpm->{error}(N("medium \"%s\" does not define any location for rpm files", $medium->{name}));
	    }
	}
	push @list, \%sources;
    }

    #- examine package list to see if a package has not been found.
    foreach (grep { ! exists($examined{$_}) } keys %fullname2id) {
	# print list errors only once if any
	@list_error and map { $urpm->{error}($_) } @list_error;
	@list_error = ();
	$error = 1;
	$urpm->{error}(N("package %s is not found.", $_));
    }

    $error ? @{[]} : (\%local_sources, \@list);
}

#- checks whether the delta RPM represented by $pkg is installable wrt the
#- RPM DB on $root. For this, it extracts the rpm version to which the
#- delta applies from the delta rpm filename itself. So naming conventions
#- do matter :)
sub is_delta_installable {
    my ($urpm, $pkg, $root) = @_;
    $pkg->flag_installed or return 0;
    my $f = $pkg->filename;
    my $n = $pkg->name;
    my ($v_match) = $f =~ /^\Q$n\E-(.*)_.+\.delta\.rpm$/;
    my $db = URPM::DB::open($root)
	or $urpm->{fatal}(9, N("unable to open rpmdb"));
    my $v_installed;
    $db->traverse(sub {
	my ($p) = @_;
	$p->name eq $n and $v_installed = $p->version . '-' . $p->release;
    });
    $v_match eq $v_installed;
}

#- Obsolescent method.
sub download_source_packages {
    my ($urpm, $local_sources, $list, %options) = @_;
    my %sources = %$local_sources;
    my %error_sources;

    $urpm->exlock_urpmi_db unless $options{nolock};
    $urpm->copy_packages_of_removable_media($list, \%sources, %options) or return;
    $urpm->download_packages_of_distant_media($list, \%sources, \%error_sources, %options);
    $urpm->unlock_urpmi_db unless $options{nolock};

    %sources, %error_sources;
}

#- lock policy concerning chroot :
#  - lock rpm db in chroot
#  - lock urpmi db in /

#- safety rpm db locking mechanism
sub exlock_rpm_db {
    my ($urpm) = @_;
    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my ($LOCK_EX, $LOCK_NB) = (2, 4);
    #- lock urpmi database, but keep lock to wait for an urpmi.update to finish.
    open RPMLOCK_FILE, ">$urpm->{root}/$urpm->{statedir}/.RPMLOCK";
    flock RPMLOCK_FILE, $LOCK_EX|$LOCK_NB or $urpm->{fatal}(7, N("urpmi database locked"));
}

sub shlock_rpm_db {
    my ($urpm) = @_;
    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my ($LOCK_SH, $LOCK_NB) = (1, 4);
    #- create the .LOCK file if needed (and if possible)
    unless (-e "$urpm->{root}/$urpm->{statedir}/.RPMLOCK") {
	open RPMLOCK_FILE, ">$urpm->{root}/$urpm->{statedir}/.RPMLOCK";
	close RPMLOCK_FILE;
    }
    #- lock urpmi database, if the LOCK file doesn't exists no share lock.
    open RPMLOCK_FILE, "$urpm->{root}/$urpm->{statedir}/.RPMLOCK" or return;
    flock RPMLOCK_FILE, $LOCK_SH|$LOCK_NB or $urpm->{fatal}(7, N("urpmi database locked"));
}

sub unlock_rpm_db {
    my ($urpm) = @_;
    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my $LOCK_UN = 8;
    #- now everything is finished.
    system("sync");
    #- release lock on database.
    flock RPMLOCK_FILE, $LOCK_UN;
    close RPMLOCK_FILE;
}

sub exlock_urpmi_db {
    my ($urpm) = @_;
    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my ($LOCK_EX, $LOCK_NB) = (2, 4);
    #- lock urpmi database, but keep lock to wait for an urpmi.update to finish.
    open LOCK_FILE, ">$urpm->{statedir}/.LOCK";
    flock LOCK_FILE, $LOCK_EX|$LOCK_NB or $urpm->{fatal}(7, N("urpmi database locked"));
}

sub shlock_urpmi_db {
    my ($urpm) = @_;
    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my ($LOCK_SH, $LOCK_NB) = (1, 4);
    #- create the .LOCK file if needed (and if possible)
    unless (-e "$urpm->{statedir}/.LOCK") {
	open LOCK_FILE, ">$urpm->{statedir}/.LOCK";
	close LOCK_FILE;
    }
    #- lock urpmi database, if the LOCK file doesn't exists no share lock.
    open LOCK_FILE, "$urpm->{statedir}/.LOCK" or return;
    flock LOCK_FILE, $LOCK_SH|$LOCK_NB or $urpm->{fatal}(7, N("urpmi database locked"));
}

sub unlock_urpmi_db {
    my ($urpm) = @_;
    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my $LOCK_UN = 8;
    #- now everything is finished.
    system("sync");
    #- release lock on database.
    flock LOCK_FILE, $LOCK_UN;
    close LOCK_FILE;
}

sub copy_packages_of_removable_media {
    my ($urpm, $list, $sources, %options) = @_;
    my %removables;

    #- make sure everything is correct on input...
    $urpm->{media} or return;
    @{$urpm->{media}} == @$list or return;

    #- examine if given medium is already inside a removable device.
    my $check_notfound = sub {
	my ($id, $dir, $removable) = @_;
	$dir and $urpm->try_mounting($dir, $removable);
	if (!$dir || -e $dir) {
	    foreach (values %{$list->[$id]}) {
		chomp;
		m!^(removable[^:]*:/|file:/)?(/.*/([^/]*)$)! or next;
		unless ($dir) {
		    $dir = $2;
		    $urpm->try_mounting($dir, $removable);
		}
		-r $2 or return 1;
	    }
	} else {
	    return 2;
	}
	return 0;
    };
    #- removable media have to be examined to keep mounted the one that has
    #- more packages than others.
    my $examine_removable_medium = sub {
	my ($id, $device) = @_;
	my $medium = $urpm->{media}[$id];
	if (my ($dir) = $medium->{url} =~ m!^(?:(?:removable[^:]*|file):/)?(/.*)!) {
	    #- the directory given does not exist and may be accessible
	    #- by mounting some other directory. Try to figure it out and mount
	    #- everything that might be necessary.
	    while ($check_notfound->($id, $dir, is_iso($medium->{removable}) || 'removable')) {
		is_iso($medium->{removable}) || $options{ask_for_medium}
		    or $urpm->{fatal}(4, N("medium \"%s\" is not selected", $medium->{name}));
		$urpm->try_umounting($dir);
		system("/usr/bin/eject '$device' 2>/dev/null");
		is_iso($medium->{removable})
		    || $options{ask_for_medium}(remove_internal_name($medium->{name}), $medium->{removable})
		    or $urpm->{fatal}(4, N("medium \"%s\" is not selected", $medium->{name}));
	    }
	    if (-e $dir) {
		while (my ($i, $url) = each %{$list->[$id]}) {
		    chomp $url;
		    my ($filepath, $filename) = $url =~ m!^(?:removable[^:]*:/|file:/)?(/.*/([^/]*))! or next;
		    if (-r $filepath) {
			#- we should assume a possibly buggy removable device...
			#- First, copy in partial cache, and if the package is still good,
			#- transfer it to the rpms cache.
			unlink "$urpm->{cachedir}/partial/$filename";
			if (urpm::util::copy($filepath, "$urpm->{cachedir}/partial") &&
			    URPM::verify_rpm("$urpm->{cachedir}/partial/$filename", nosignatures => 1))
			{
			    #- now we can consider the file to be fine.
			    unlink "$urpm->{cachedir}/rpms/$filename";
			    urpm::util::move("$urpm->{cachedir}/partial/$filename", "$urpm->{cachedir}/rpms/$filename");
			    -r "$urpm->{cachedir}/rpms/$filename" and $sources->{$i} = "$urpm->{cachedir}/rpms/$filename";
			}
		    }
		    unless ($sources->{$i}) {
			#- fallback to use other method for retrieving the file later.
			$urpm->{error}(N("unable to read rpm file [%s] from medium \"%s\"", $filepath, $medium->{name}));
		    }
		}
	    } else {
		$urpm->{error}(N("medium \"%s\" is not selected", $medium->{name}));
	    }
	} else {
	    #- we have a removable device that is not removable, well...
	    $urpm->{error}(N("inconsistent medium \"%s\" marked removable but not really", $medium->{name}));
	}
    };

    foreach (0..$#$list) {
	values %{$list->[$_]} or next;
	my $medium = $urpm->{media}[$_];
	#- examine non removable device but that may be mounted.
	if ($medium->{removable}) {
	    push @{$removables{$medium->{removable}} ||= []}, $_;
	} elsif (my ($dir) = $medium->{url} =~ m!^(?:removable[^:]*:/|file:/)?(/.*)!) {
	    -e $dir || $urpm->try_mounting($dir) or
	      $urpm->{error}(N("unable to access medium \"%s\"", $medium->{name})), next;
	}
    }
    foreach my $device (keys %removables) {
	next if $device =~ m![^a-zA-Z0-9_./-]!; #- bad path
	#- Here we have only removable devices.
	#- If more than one media uses this device, we have to sort
	#- needed packages to copy the needed rpm files.
	if (@{$removables{$device}} > 1) {
	    my @sorted_media = sort { values %{$list->[$a]} <=> values %{$list->[$b]} } @{$removables{$device}};

	    #- check if a removable device is already mounted (and files present).
	    if (my ($already_mounted_medium) = grep { !$check_notfound->($_) } @sorted_media) {
		@sorted_media = grep { $_ ne $already_mounted_medium } @sorted_media;
		unshift @sorted_media, $already_mounted_medium;
	    }

	    #- mount all except the biggest one.
	    foreach (@sorted_media[0 .. $#sorted_media-1]) {
		$examine_removable_medium->($_, $device);
	    }
	    #- now mount the last one...
	    $removables{$device} = [ $sorted_media[-1] ];
	}

	$examine_removable_medium->($removables{$device}[0], $device);
    }

    1;
}

# TODO verify that files are downloaded from the right corresponding media
sub download_packages_of_distant_media {
    my ($urpm, $list, $sources, $error_sources, %options) = @_;

    #- get back all ftp and http accessible rpm files into the local cache
    foreach my $n (0..$#$list) {
	my %distant_sources;

	#- ignore media that contain nothing for the current set of files
	values %{$list->[$n]} or next;

	#- examine all files to know what can be indexed on multiple media.
	while (my ($i, $url) = each %{$list->[$n]}) {
	    #- the given URL is trusted, so the file can safely be ignored.
	    defined $sources->{$i} and next;
	    if ($url =~ m!^(removable[^:]*:/|file:/)?(/.*\.rpm)\Z!) {
		if (-r $2) {
		    $sources->{$i} = $2;
		} else {
		    $error_sources->{$i} = $2;
		}
	    } elsif ($url =~ m!^([^:]*):/(.*/([^/]*\.rpm))\Z!) {
		$distant_sources{$i} = "$1:/$2"; #- will download now
	    } else {
		$urpm->{error}(N("malformed URL: [%s]", $url));
	    }
	}

	#- download files from the current medium.
	if (%distant_sources) {
	    eval {
		$urpm->{log}(N("retrieving rpm files from medium \"%s\"...", $urpm->{media}[$n]{name}));
		$urpm->{sync}(
		    {
			dir => "$urpm->{cachedir}/partial",
			quiet => $options{quiet},
			limit_rate => $options{limit_rate},
			resume => $options{resume},
			compress => $options{compress},
			callback => $options{callback},
			proxy => get_proxy($urpm->{media}[$n]{name}),
			media => $urpm->{media}[$n]{name},
			retry => $urpm->{options}{retry},
		    },
		    values %distant_sources,
		);
		$urpm->{log}(N("...retrieving done"));
	    };
	    $@ and $urpm->{error}(N("...retrieving failed: %s", $@));
	    #- clean files that have not been downloaded, but keep in mind
	    #- there have been problems downloading them at least once, this
	    #- is necessary to keep track of failing downloads in order to
	    #- present the error to the user.
	    foreach my $i (keys %distant_sources) {
		my ($filename) = $distant_sources{$i} =~ m|/([^/]*\.rpm)$|;
		if ($filename && -s "$urpm->{cachedir}/partial/$filename" &&
		    URPM::verify_rpm("$urpm->{cachedir}/partial/$filename", nosignatures => 1))
		{
		    #- it seems the the file has been downloaded correctly and has been checked to be valid.
		    unlink "$urpm->{cachedir}/rpms/$filename";
		    urpm::util::move("$urpm->{cachedir}/partial/$filename", "$urpm->{cachedir}/rpms/$filename");
		    -r "$urpm->{cachedir}/rpms/$filename" and $sources->{$i} = "$urpm->{cachedir}/rpms/$filename";
		}
		unless ($sources->{$i}) {
		    $error_sources->{$i} = $distant_sources{$i};
		}
	    }
	}
    }

    #- clean failed download which have succeeded.
    delete @$error_sources{keys %$sources};

    1;
}

#- prepare transaction.
sub prepare_transaction {
    my ($urpm, $set, $list, $sources, $transaction_list, $transaction_sources) = @_;

    foreach my $id (@{$set->{upgrade}}) {
	my $pkg = $urpm->{depslist}[$id];
	foreach (0..$#$list) {
	    exists $list->[$_]{$id} and $transaction_list->[$_]{$id} = $list->[$_]{$id};
	}
	exists $sources->{$id} and $transaction_sources->{$id} = $sources->{$id};
    }
}

#- extract package that should be installed instead of upgraded,
#- sources is a hash of id -> source rpm filename.
sub extract_packages_to_install {
    my ($urpm, $sources, $state) = @_;
    my %inst;
    my $rej = ref $state ? $state->{rejected} || {} : {};

    foreach (keys %$sources) {
	my $pkg = $urpm->{depslist}[$_] or next;
	$pkg->flag_disable_obsolete || !$pkg->flag_installed
	    and !grep { exists $rej->{$_}{closure}{$pkg->fullname} } keys %$rej
	    and $inst{$pkg->id} = delete $sources->{$pkg->id};
    }

    \%inst;
}

my $progress_size = 45;
eval {
    require Term::ReadKey;
    ($progress_size) = Term::ReadKey::GetTerminalSize();
    $progress_size -= 35;
    $progress_size < 5 and $progress_size = 5;
};

#- install logger (a la rpm)
sub install_logger {
    my ($urpm, $type, $id, $subtype, $amount, $total) = @_;
    my $pkg = defined $id && $urpm->{depslist}[$id];
    my $total_pkg = $urpm->{nb_install};

    if ($subtype eq 'start') {
	$urpm->{logger_progress} = 0;
	if ($type eq 'trans') {
	    $urpm->{logger_id} ||= 0;
	    $urpm->{logger_count} ||= 0;
	    printf("%-33s", N("Preparing..."));
	} else {
	    ++$urpm->{logger_id};
	    my $pname = $pkg ? $pkg->name : '';
	    ++$urpm->{logger_count} if $pname;
	    $pname ||= N("[repackaging]");
	    printf "%9s: %-22s", $urpm->{logger_count} . "/" . $total_pkg, $pname;
	}
    } elsif ($subtype eq 'stop') {
	if ($urpm->{logger_progress} < $progress_size) {
	    print '#' x ($progress_size - $urpm->{logger_progress});
	    print "\n";
	}
    } elsif ($subtype eq 'progress') {
	my $new_progress = $total > 0 ? int($progress_size * $amount / $total) : $progress_size;
	if ($new_progress > $urpm->{logger_progress}) {
	    print '#' x ($new_progress - $urpm->{logger_progress});
	    $urpm->{logger_progress} = $new_progress;
	    $urpm->{logger_progress} == $progress_size and print "\n";
	}
    }
}

#- install packages according to each hash (remove, install or upgrade).
sub install {
    my ($urpm, $remove, $install, $upgrade, %options) = @_;
    my %readmes;

    #- allow process to be forked now.
    my $pid;
    local (*CHILD_RETURNS, *ERROR_OUTPUT, $_);
    if ($options{fork}) {
	pipe(CHILD_RETURNS, ERROR_OUTPUT);
	defined($pid = fork()) or die "Can't fork: $!\n";
	if ($pid) {
	    # parent process
	    close ERROR_OUTPUT;

	    $urpm->{log}(N("using process %d for executing transaction", $pid));
	    #- now get all errors from the child and return them directly.
	    my @l;
	    while (<CHILD_RETURNS>) {
		chomp;
		if (/^::logger_id:(\d+)(?::(\d+))?/) {
		    $urpm->{logger_id} = $1;
		    $2 and $urpm->{logger_count} = $2;
		} else {
		    push @l, $_;
		}
	    }

	    close CHILD_RETURNS;
	    waitpid($pid, 0);
	    #- take care of return code from transaction, an error should be returned directly.
	    $? >> 8 and exit $? >> 8;

	    return @l;
	} else {
	    # child process
	    close CHILD_RETURNS;
	}
    }
    #- beware this can be a child process or the main process now...

    my $db = URPM::DB::open($urpm->{root}, !$options{test}); #- open in read/write mode unless testing installation.

    $db or $urpm->{fatal}(9, N("unable to open rpmdb"));

    my $trans = $db->create_transaction($urpm->{root});
    if ($trans) {
	sys_log("transaction on %s (remove=%d, install=%d, upgrade=%d)", $urpm->{root} || '/', scalar(@{$remove || []}), scalar(values %$install), scalar(values %$upgrade));
	$urpm->{log}(N("created transaction for installing on %s (remove=%d, install=%d, upgrade=%d)", $urpm->{root} || '/',
		       scalar(@{$remove || []}), scalar(values %$install), scalar(values %$upgrade)));
    } else {
	return N("unable to create transaction");
    }

    my ($update, @l) = 0;
    my @produced_deltas;

    foreach (@$remove) {
	if ($trans->remove($_)) {
	    $urpm->{log}(N("removing package %s", $_));
	} else {
	    $urpm->{error}(N("unable to remove package %s", $_));
	}
    }
    foreach my $mode ($install, $upgrade) {
	foreach (keys %$mode) {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg->update_header($mode->{$_});
	    if ($pkg->payload_format eq 'drpm') { #- handle deltarpms
		my $true_rpm = urpm::sys::apply_delta_rpm($mode->{$_}, "$urpm->{cachedir}/rpms", $pkg);
		if ($true_rpm) {
		    push @produced_deltas, ($mode->{$_} = $true_rpm); #- fix path
		} else {
		    $urpm->{error}(N("unable to extract rpm from delta-rpm package %s", $mode->{$_}));
		}
	    }
	    if ($trans->add($pkg, update => $update,
		    $options{excludepath} ? (excludepath => [ split /,/, $options{excludepath} ]) : ()
	    )) {
		$urpm->{log}(N("adding package %s (id=%d, eid=%d, update=%d, file=%s)", scalar($pkg->fullname),
			       $_, $pkg->id, $update, $mode->{$_}));
	    } else {
		$urpm->{error}(N("unable to install package %s", $mode->{$_}));
	    }
	}
	++$update;
    }
    if (($options{nodeps} || !(@l = $trans->check(%options))) && ($options{noorder} || !(@l = $trans->order))) {
	my $fh;
	#- assume default value for some parameter.
	$options{delta} ||= 1000;
	$options{callback_open} ||= sub {
	    my ($data, $type, $id) = @_;
	    $fh = $urpm->open_safe('<', $install->{$id} || $upgrade->{$id});
	    return defined $fh ? fileno $fh : undef;
	};
	$options{callback_close} ||= sub {
	    my ($urpm, undef, $pkgid) = @_;
	    return unless defined $pkgid;
	    my $pkg = $urpm->{depslist}[$pkgid];
	    my $fullname = $pkg->fullname;
	    my $trtype = (grep { /\Q$fullname\E/ } values %$install) ? 'install' : '(upgrade|update)';
	    for ($pkg->files) { /\bREADME(\.$trtype)?\.urpmi$/ and $readmes{$_} = $fullname }
	    close $fh if defined $fh;
	};
	if ($::verbose >= 0 && (scalar keys %$install || scalar keys %$upgrade)) {
	    $options{callback_inst}  ||= \&install_logger;
	    $options{callback_trans} ||= \&install_logger;
	}
	@l = $trans->run($urpm, %options);

	#- don't clear cache if transaction failed. We might want to retry.
	if (@l == 0 && !$options{test} && $options{post_clean_cache}) {
	    #- examine the local cache to delete packages which were part of this transaction
	    foreach (keys %$install, keys %$upgrade) {
		my $pkg = $urpm->{depslist}[$_];
		unlink "$urpm->{cachedir}/rpms/" . $pkg->filename;
	    }
	}
    }
    unlink @produced_deltas;

    #- now exit or return according to current status.
    if (defined $pid && !$pid) { #- child process
	print ERROR_OUTPUT "::logger_id:$urpm->{logger_id}:$urpm->{logger_count}\n"; #- allow main urpmi to know transaction numbering...
	print ERROR_OUTPUT "$_\n" foreach @l;
	close ERROR_OUTPUT;
	#- keep safe exit now (with destructor call).
	exit 0;
    } else { #- parent process
	if (keys %readmes) {
	    foreach (keys %readmes) {
		print "-" x 70, "\n", N("More information on package %s", $readmes{$_}), "\n";
		my $fh; open $fh, '<', $_ and do {
		    print while <$fh>;
		    close $fh;
		};
		print "-" x 70, "\n";
	    }
	}
	return @l;
    }
}

#- install all files to node as remembered according to resolving done.
sub parallel_install {
    my ($urpm, $remove, $install, $upgrade, %options) = @_;
    $urpm->{parallel_handler}->parallel_install(@_);
}

#- find packages to remove.
#- options:
#-	bundle
#-	callback_base
#-	callback_fuzzy
#-	callback_notfound
#-	force
#-	matches
#-	root
#-	test
sub find_packages_to_remove {
    my ($urpm, $state, $l, %options) = @_;

    if ($urpm->{parallel_handler}) {
	#- invoke parallel finder.
	$urpm->{parallel_handler}->parallel_find_remove($urpm, $state, $l, %options, find_packages_to_remove => 1);
    } else {
	my $db = URPM::DB::open($options{root});
	my (@m, @notfound);

	$db or $urpm->{fatal}(9, N("unable to open rpmdb"));

	if (!$options{matches}) {
	    foreach (@$l) {
		my ($n, $found);

		#- check if name-version-release-architecture was given.
		if (($n) = /^(.*)-[^\-]*-[^\-]*\.[^\.\-]*$/) {
		    $db->traverse_tag('name', [ $n ], sub {
			    my ($p) = @_;
			    $p->fullname eq $_ or return;
			    $urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
			    push @m, scalar $p->fullname;
			    $found = 1;
			});
		    $found and next;
		}

		#- check if name-version-release was given.
		if (($n) = /^(.*)-[^\-]*-[^\-]*$/) {
		    $db->traverse_tag('name', [ $n ], sub {
			    my ($p) = @_;
			    join('-', ($p->fullname)[0..2]) eq $_ or return;
			    $urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
			    push @m, scalar $p->fullname;
			    $found = 1;
			});
		    $found and next;
		}

		#- check if name-version was given.
		if (($n) = /^(.*)-[^\-]*$/) {
		    $db->traverse_tag('name', [ $n ], sub {
			    my ($p) = @_;
			    join('-', ($p->fullname)[0..1]) eq $_ or return;
			    $urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
			    push @m, scalar $p->fullname;
			    $found = 1;
			});
		    $found and next;
		}

		#- check if only name was given.
		$db->traverse_tag('name', [ $_ ], sub {
			my ($p) = @_;
			$p->name eq $_ or return;
			$urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
			push @m, scalar $p->fullname;
			$found = 1;
		    });
		$found and next;

		push @notfound, $_;
	    }
	    if (!$options{force} && @notfound && @$l > 1) {
		$options{callback_notfound} and $options{callback_notfound}->($urpm, @notfound)
		  or return ();
	    }
	}
	if ($options{matches} || @notfound) {
	    my $match = join "|", map { quotemeta } @$l;
	    my $qmatch = qr/$match/;

	    #- reset what has been already found.
	    %$state = ();
	    @m = ();

	    #- search for packages that match, and perform closure again.
	    $db->traverse(sub {
		    my ($p) = @_;
		    my $f = scalar $p->fullname;
		    $f =~ $qmatch or return;
		    $urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
		    push @m, $f;
		});

	    if (!$options{force} && @notfound) {
		if (@m) {
		    $options{callback_fuzzy} and $options{callback_fuzzy}->($urpm, @$l > 1 ? $match : $l->[0], @m)
		      or return ();
		} else {
		    $options{callback_notfound} and $options{callback_notfound}->($urpm, @notfound)
		      or return ();
		}
	    }
	}

	#- check if something needs to be removed.
	find_removed_from_basesystem($urpm, $db, $state, $options{callback_base})
	    or return ();
    }
    grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}};
}

sub find_removed_from_basesystem {
    my ($urpm, $db, $state, $callback_base) = @_;
    if ($callback_base && %{$state->{rejected} || {}}) {
	my %basepackages;
	my @dont_remove = ('basesystem', split /,\s*/, $urpm->{global_config}{'prohibit-remove'});
	#- check if a package to be removed is a part of basesystem requires.
	$db->traverse_tag('whatprovides', \@dont_remove, sub {
	    my ($p) = @_;
	    $basepackages{$p->fullname} = 0;
	});
	foreach (grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}}) {
	    exists $basepackages{$_} or next;
	    ++$basepackages{$_};
	}
	if (grep { $_ } values %basepackages) {
	    return $callback_base->($urpm, grep { $basepackages{$_} } keys %basepackages);
	}
    }
    return 1;
}

#- remove packages from node as remembered according to resolving done.
sub parallel_remove {
    my ($urpm, $remove, %options) = @_;
    my $state = {};
    my $callback = sub { $urpm->{fatal}(1, "internal distributed remove fatal error") };
    $urpm->{parallel_handler}->parallel_find_remove($urpm, $state, $remove, %options,
						    callback_notfound => undef,
						    callback_fuzzy => $callback,
						    callback_base => $callback,
						   );
}

#- misc functions to help finding ask_unselect and ask_remove elements with their reasons translated.
sub unselected_packages {
    my (undef, $state) = @_;
    grep { $state->{rejected}{$_}{backtrack} } keys %{$state->{rejected} || {}};
}

sub uniq { my %l; $l{$_} = 1 foreach @_; grep { delete $l{$_} } @_ }

sub translate_why_unselected {
    my ($urpm, $state, @l) = @_;

    map {
	my $rb = $state->{rejected}{$_}{backtrack};
	my @froms = keys %{$rb->{closure} || {}};
	my @unsatisfied = @{$rb->{unsatisfied} || []};
	my $s = join ", ", (
	    (map { N("due to missing %s", $_) } @froms),
	    (map { N("due to unsatisfied %s", $_) } uniq map {
		    #- XXX in theory we shouldn't need this, dependencies (and not ids) should
		    #- already be present in @unsatisfied. But with biarch packages this is
		    #- not always the case.
		    /\D/ ? $_ : scalar($urpm->{depslist}[$_]->fullname)
		} @unsatisfied),
	    $rb->{promote} && !$rb->{keep} ? N("trying to promote %s", join(", ", @{$rb->{promote}})) : @{[]},
	    $rb->{keep} ? N("in order to keep %s", join(", ", @{$rb->{keep}})) : @{[]},
	);
	$_ . ($s ? " ($s)" : '');
    } @l;
}

sub removed_packages {
    my (undef, $state) = @_;
    grep {
	$state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted};
    } keys %{$state->{rejected} || {}};
}

sub translate_why_removed {
    my ($urpm, $state, @l) = @_;
    map {
	my ($from) = keys %{$state->{rejected}{$_}{closure}};
	my ($whyk) = keys %{$state->{rejected}{$_}{closure}{$from}};
	my ($whyv) = $state->{rejected}{$_}{closure}{$from}{$whyk};
	my $frompkg = $urpm->search($from, strict_fullname => 1);
	my $s;
	for ($whyk) {
	    /old_requested/
		and $s .= N("in order to install %s", $frompkg ? scalar $frompkg->fullname : $from);
	    /unsatisfied/ and do {
		foreach (@$whyv) {
		    $s and $s .= ",\n  ";
		    if (/([^\[\s]*)(?:\[\*\])?(?:\[|\s+)([^\]]*)\]?$/ && $2 ne '*') {
			$s .= N("due to unsatisfied %s", "$1 $2");
		    } else {
			$s .= N("due to missing %s", $_);
		    }
		}
	    };
	    /conflicts/ and $s .= N("due to conflicts with %s", $whyv);
	    /unrequested/ and $s .= N("unrequested");
	}
	#- now insert the reason if available.
	$_ . ($s ? "\n ($s)" : '');
    } @l;
}

sub check_sources_signatures {
    my ($urpm, $sources_install, $sources, %options) = @_;
    my ($medium, %invalid_sources);
    my $s = $sources_install;

    foreach my $id (keys %$sources_install, -1, keys %$sources) {
	if ($id == -1) { $s = $sources; next }
	my $filepath = $s->{$id};
	my $verif = URPM::verify_signature($filepath);

	if ($verif =~ /NOT OK/) {
	    $verif =~ s/\n//g;
	    $invalid_sources{$filepath} = N("Invalid signature (%s)", $verif);
	} else {
	    unless ($medium &&
		defined $medium->{start} && $medium->{start} <= $id &&
		defined $medium->{end} && $id <= $medium->{end})
	    {
		$medium = undef;
		foreach (@{$urpm->{media}}) {
		    defined $_->{start} && $_->{start} <= $id
			&& defined $_->{end} && $id <= $_->{end}
			and $medium = $_, last;
		}
	    }
	    #- no medium found for this rpm ?
	    next if !$medium;
	    #- check whether verify-rpm is specifically disabled for this medium
	    next if defined $medium->{'verify-rpm'} && !$medium->{'verify-rpm'};

	    my $key_ids = $medium->{'key-ids'} || $urpm->{options}{'key-ids'};
	    #- check that the key ids of the medium match the key ids of the package.
	    if ($key_ids) {
		my $valid_ids = 0;
		my $invalid_ids = 0;

		foreach my $key_id ($verif =~ /(?:key id \w{8}|#)(\w+)/gi) {
		    if (grep { hex($_) == hex($key_id) } split /[,\s]+/, $key_ids) {
			++$valid_ids;
		    } else {
			++$invalid_ids;
		    }
		}

		if ($invalid_ids) {
		    $invalid_sources{$filepath} = N("Invalid Key ID (%s)", $verif);
		} elsif (!$valid_ids) {
		    $invalid_sources{$filepath} = N("Missing signature (%s)", $verif);
		}
	    }
	    #- invoke check signature callback.
	    $options{callback} and $options{callback}->(
		$urpm, $filepath, %options,
		id => $id,
		verif => $verif,
		why => $invalid_sources{$filepath},
	    );
	}
    }

    map { ($options{basename} ? urpm::download::basename($_) : $_) . ($options{translate} ? ": $invalid_sources{$_}" : "") }
      sort keys %invalid_sources;
}

sub dump_description_file {
    my ($urpm, $media_name) = @_;
    open my $fh, '<', "$urpm->{statedir}/descriptions.$media_name"
	or return ();
    my @slurp = <$fh>;
    close $fh;
    return @slurp;
}

#- get reason of update for packages to be updated
#- use all update medias if none given
sub get_updates_description {
    my ($urpm, @update_medias) = @_;
    my %update_descr;
    my ($cur, $section);

    @update_medias or @update_medias = grep { !$_->{ignore} && $_->{update} } @{$urpm->{media}};

    foreach (map { $urpm->dump_description_file($_->{name}), '%package dummy' } @update_medias) {
	/^%package (.+)/ and do {
	    if (exists $cur->{importance} && $cur->{importance} ne "security" && $cur->{importance} ne "bugfix") {
		$cur->{importance} = 'normal';
	    }
	    $update_descr{$_} = $cur foreach @{$cur->{pkgs}};
	    $cur = {};
	    $cur->{pkgs} = [ split /\s/, $1 ];
	    $section = 'pkg';
	    next;
	};
	/^Updated: (.+)/ && $section eq 'pkg' and $cur->{updated} = $1;
	/^Importance: (.+)/ && $section eq 'pkg' and $cur->{importance} = $1;
	/^%pre/ and do { $section = 'pre'; next };
	/^%description/ and do { $section = 'description'; next };
	$section eq 'pre' and $cur->{pre} .= $_;
	$section eq 'description' and $cur->{description} .= $_;
    }
    \%update_descr;
}

#- parse an MD5SUM file from a mirror
sub parse_md5sum {
    my ($urpm, $path, $basename) = @_;
    $urpm->{log}(N("examining MD5SUM file"));
    my $fh = $urpm->open_safe('<', $path) or return undef;
    my $retrieved_md5sum;
    local $_;
    while (<$fh>) {
	my ($md5sum, $file) = m|(\S+)\s+(?:\./)?(\S+)| or next;
	$file eq $basename and $retrieved_md5sum = $md5sum;
    }
    close $fh;
    defined $retrieved_md5sum
	or $urpm->{log}(N("warning: md5sum for %s unavailable in MD5SUM file", $basename));
    return $retrieved_md5sum;
}

sub recompute_local_md5sum {
    my ($urpm, $medium, $force) = @_;
    if ($force) {
	#- force downloading the file again, else why a force option has been defined ?
	delete $medium->{md5sum};
    } else {
	unless ($medium->{md5sum}) {
	    $urpm->{log}(N("computing md5sum of existing source hdlist (or synthesis)"));
	    if ($medium->{synthesis}) {
		-e "$urpm->{statedir}/synthesis.$medium->{hdlist}" and
		$medium->{md5sum} = md5sum("$urpm->{statedir}/synthesis.$medium->{hdlist}");
	    } else {
		-e "$urpm->{statedir}/$medium->{hdlist}" and
		$medium->{md5sum} = md5sum("$urpm->{statedir}/$medium->{hdlist}");
	    }
	}
    }
}

sub syserror { my ($urpm, $msg, $info) = @_; $urpm->{error}("$msg [$info] [$!]") }

sub open_safe {
    my ($urpm, $sense, $filename) = @_;
    open my $f, $sense, $filename
	or $urpm->syserror($sense eq '>' ? "Can't write file" : "Can't open file", $filename), return undef;
    return $f;
}

sub opendir_safe {
    my ($urpm, $dirname) = @_;
    opendir my $d, $dirname
	or $urpm->syserror("Can't open directory", $dirname), return undef;
    return $d;
}

sub error_restricted ($) {
    my ($urpm) = @_;
    $urpm->{fatal}(2, N("This operation is forbidden while running in restricted mode"));
}

sub DESTROY {}

1;

__END__

=head1 NAME

urpm - Mandriva perl tools to handle the urpmi database

=head1 DESCRIPTION

C<urpm> is used by urpmi executables to manipulate packages and media
on a Mandriva Linux distribution.

=head1 SEE ALSO

The C<URPM> package is used to manipulate at a lower level hdlist and rpm
files.

=head1 COPYRIGHT

Copyright (C) 2000, 2001, 2002, 2003, 2004, 2005 MandrakeSoft SA

Copyright (C) 2005, 2006 Mandriva SA

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2, or (at your option)
any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut
