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
use MDV::Distribconf;

our $VERSION = '4.8.29';
our @ISA = qw(URPM);

use URPM;
use URPM::Resolve;

my $RPMLOCK_FILE;
my $LOCK_FILE;

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
	private_netrc => "/etc/urpmi/netrc",
	statedir   => "/var/lib/urpmi",
	cachedir   => "/var/cache/urpmi",
	media      => undef,
	options    => {},

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

sub requested_ftp_http_downloader {
    my ($urpm, $media_name) = @_;

    $urpm->{options}{downloader} || #- cmd-line switch
      $media_name && do {
	  #- per-media config
	  my $m = name2medium($urpm, $media_name);
	  $m && $m->{downloader};
      } || $urpm->{global_config}{downloader};
}

#- $medium can be undef
#- known options: quiet, resume, callback
sub sync_webfetch {
    my ($urpm, $medium, $files, %options) = @_;

    my %all_options = ( 
	dir => "$urpm->{cachedir}/partial",
	proxy => get_proxy($medium),
	$medium ? (media => $medium->{name}) : (),
	%options,
    );
    foreach my $cpt (qw(compress limit_rate retry wget-options curl-options rsync-options prozilla-options)) {
	$all_options{$cpt} = $urpm->{options}{$cpt} if defined $urpm->{options}{$cpt};
    }

    eval { _sync_webfetch_raw($urpm, $files, \%all_options); 1 };
}

#- syncing algorithms.
sub _sync_webfetch_raw {    
    my ($urpm, $files, $options) = @_;

    my %files;
    #- currently ftp and http protocols are managed by curl or wget,
    #- ssh and rsync protocols are managed by rsync *AND* ssh.
    foreach (@$files) {
	my $proto = protocol_from_url($_) or die N("unknown protocol defined for %s", $_);
	push @{$files{$proto}}, $_;
    }
    if ($files{removable} || $files{file}) {
	my @l = map { file_from_local_url($_) } @{$files{removable} || []}, @{$files{file} || []};
	eval { sync_file($options, @l) };
	$urpm->{fatal}(10, $@) if $@;
	delete @files{qw(removable file)};
    }
    if ($files{ftp} || $files{http} || $files{https}) {
	my @available = urpm::download::available_ftp_http_downloaders();

	#- use user default downloader if provided and available
	my $requested_downloader = requested_ftp_http_downloader($urpm, $options->{media});
	my ($preferred) = grep { $_ eq $requested_downloader } @available;
	if (!$preferred) {
	    #- else first downloader of @available is the default one
	    $preferred = $available[0];
	    if ($requested_downloader && !our $webfetch_not_available) {
		$urpm->{log}(N("%s is not available, falling back on %s", $requested_downloader, $preferred));
		$webfetch_not_available = 1;
	    }
	}
	my $sync = $urpm::download::{"sync_$preferred"} or die N("no webfetch found, supported webfetch are: %s\n", join(", ", urpm::download::ftp_http_downloaders()));
	$sync->($options, @{$files{ftp} || []}, @{$files{http} || []}, @{$files{https} || []});

	delete @files{qw(ftp http https)};
    }
    if ($files{rsync}) {
	sync_rsync($options, @{$files{rsync}});
	delete $files{rsync};
    }
    if ($files{ssh}) {
	my @ssh_files = map { m!^ssh://([^/]*)(.*)! ? "$1:$2" : () } @{$files{ssh}};
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
    priority-upgrade
    removable
    static
    synthesis
    update
    url
    verify-rpm
    virtual
    with_hdlist
);

sub read_private_netrc {
    my ($urpm) = @_;

    my @words = split(/\s+/, scalar cat_($urpm->{private_netrc}));
    my @l;
    my $e;
    while (@words) {
	my $keyword = shift @words;
	if ($keyword eq 'machine') {
	    push @l, $e = { machine => shift(@words) };
	} elsif ($keyword eq 'default') {
	    push @l, $e = { default => '' };
	} elsif ($keyword eq 'login' || $keyword eq 'password' || $keyword eq 'account') {
	    $e->{$keyword} = shift(@words);
	} else {
	    $urpm->{error}("unknown netrc command $keyword");
	}
    }
    @l;
}

sub parse_url_with_login {
    my ($url) = @_;
    $url =~ m!([^:]*)://([^/:\@]*)(:([^/:\@]*))?\@([^/]*)(.*)! &&
      { proto => $1, login => $2, password => $4, machine => $5, dir => $6 };
}

sub read_config_add_passwords {
    my ($urpm, $config) = @_;

    my @netrc = read_private_netrc($urpm) or return;
    foreach (values %$config) {
	my $u = parse_url_with_login($_->{url}) or next;
	if (my ($e) = grep { ($_->{default} || $_->{machine} eq $u->{machine}) && $_->{login} eq $u->{login} } @netrc) {
	    $_->{url} = sprintf('%s://%s:%s@%s%s', $u->{proto}, $u->{login}, $e->{password}, $u->{machine}, $u->{dir});
	} else {
	    $urpm->{log}("no password found for $u->{login}@$u->{machine}");
	}
    }
}

sub remove_passwords_and_write_private_netrc {
    my ($urpm, $config) = @_;

    my @l;
    foreach (values %$config) {
	my $u = parse_url_with_login($_->{url}) or next;
	#- check whether a password is visible
	$u->{password} or next;

	push @l, $u;
	$_->{url} = sprintf('%s://%s@%s%s', $u->{proto}, $u->{login}, $u->{machine}, $u->{dir});
    }
    {
	my $fh = $urpm->open_safe('>', $urpm->{private_netrc}) or return;
	foreach my $u (@l) {
	    printf $fh "machine %s login %s password %s\n", $u->{machine}, $u->{login}, $u->{password};
	}
    }
    chmod 0600, $urpm->{private_netrc};
}

#- handle deprecated way of saving passwords
sub recover_url_from_list {
    my ($urpm, $medium) = @_;

    #- /./ is end of url marker in list file (typically generated by a
    #- find . -name "*.rpm" > list
    #- for exportable list file.
    if (my @probe = map { m!^(.*)/\./! || m!^(.*)/[^/]*$! } cat_(statedir_list($urpm, $medium))) {
	($medium->{url}) = sort { length($a) <=> length($b) } @probe;
	$urpm->{modified} = 1; #- ensure urpmi.cfg is handled using only partially hidden url + netrc, since file list won't be generated anymore
    }
}

#- Loads /etc/urpmi/urpmi.cfg and performs basic checks.
#- Does not handle old format: <name> <url> [with <path_hdlist>]
#- options :
#-    - nocheck_access : don't check presence of hdlist and other files
sub read_config {
    my ($urpm, $b_nocheck_access) = @_;
    return if $urpm->{media}; #- media already loaded
    $urpm->{media} = [];
    my $config = urpm::cfg::load_config($urpm->{config})
	or $urpm->{fatal}(6, $urpm::cfg::err);

    #- global options
    if (my $global = $config->{''}) {
	foreach my $opt (keys %$global) {
	    if (defined $global->{$opt} && !exists $urpm->{options}{$opt}) {
		$urpm->{options}{$opt} = $global->{$opt};
	    }
	}
    }

    #- per-media options

    read_config_add_passwords($urpm, $config);

    foreach my $m (grep { $_ ne '' } keys %$config) {
	my $medium = { name => $m };
	foreach my $opt (@PER_MEDIA_OPT) {
	    defined $config->{$m}{$opt} and $medium->{$opt} = $config->{$m}{$opt};
	}

	if (!$medium->{url}) {
	    #- recover the url the old deprecated way...
	    #- only useful for migration, new urpmi.cfg will use netrc
	    recover_url_from_list($urpm, $medium);
	    $medium->{url} or $urpm->{error}("unable to find url in list file $medium->{name}, medium ignored");
	}

	$urpm->add_existing_medium($medium, $b_nocheck_access);
    }

    eval { require urpm::ldap; urpm::ldap::load_ldap_media($urpm) };

    #- load default values
    foreach (qw(post-clean verify-rpm)) {
	exists $urpm->{options}{$_} or $urpm->{options}{$_} = 1;
    }

    $urpm->{media} = [ sort { $a->{priority} <=> $b->{priority} } @{$urpm->{media}} ];

    #- read MD5 sums (usually not in urpmi.cfg but in a separate file)
    foreach (@{$urpm->{media}}) {
	if (my $md5sum = get_md5sum("$urpm->{statedir}/MD5SUM", statedir_hdlist_or_synthesis($urpm, $_))) {
	    $_->{md5sum} = $md5sum;
	}
    }

    #- remember global options for write_config
    $urpm->{global_config} = $config->{''};
}

#- if invalid, set {ignore}
sub check_existing_medium {
    my ($urpm, $medium, $b_nocheck_access) = @_;

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
	if ($medium->{hdlist}) {
	    #- is this check really needed? keeping just in case
	    $medium->{hdlist} ne 'list' && $medium->{hdlist} ne 'pubkey' or
	      $medium->{ignore} = 1,
		$urpm->{error}(N("invalid hdlist name"));
	}
	if (!$medium->{ignore} && !$medium->{hdlist}) {
	    $medium->{hdlist} = "hdlist.$medium->{name}.cz";
	    -e statedir_hdlist($urpm, $medium) or
	      $medium->{ignore} = 1,
		$urpm->{error}(N("unable to find hdlist file for \"%s\", medium ignored", $medium->{name}));
	}
	if (!$medium->{ignore} && !$medium->{list}) {
	    unless (defined $medium->{url}) {
		$medium->{list} = "list.$medium->{name}";
		unless (-e statedir_list($urpm, $medium)) {
		    $medium->{ignore} = 1,
		      $urpm->{error}(N("unable to find list file for \"%s\", medium ignored", $medium->{name}));
		}
	    }
	}
    }


    #- check the presence of hdlist and list files if necessary.
    if (!$b_nocheck_access && !$medium->{ignore}) {
	if ($medium->{virtual} && -r hdlist_or_synthesis_for_virtual_medium($medium)) {}
	elsif (-r statedir_hdlist($urpm, $medium)) {}
	elsif ($medium->{synthesis} && -r statedir_synthesis($urpm, $medium)) {}
	else {
	    $medium->{ignore} = 1;
	    $urpm->{error}(N("unable to access hdlist file of \"%s\", medium ignored", $medium->{name}));
	}
	if ($medium->{list} && -r statedir_list($urpm, $medium)) {}
	elsif ($medium->{url}) {}
	else {
	    $medium->{ignore} = 1;
	    $urpm->{error}(N("unable to access list file of \"%s\", medium ignored", $medium->{name}));
	}
    }

    foreach my $field ('hdlist', 'list') {
	$medium->{$field} or next;
	if (grep { $_->{$field} eq $medium->{$field} } @{$urpm->{media}}) {
	    $medium->{ignore} = 1;
	    $urpm->{error}(
		$field eq 'hdlist'
		  ? N("medium \"%s\" trying to use an already used hdlist, medium ignored", $medium->{name})
		  : N("medium \"%s\" trying to use an already used list, medium ignored",   $medium->{name}));
	}
    }
}

#- probe medium to be used, take old medium into account too.
sub add_existing_medium {
    my ($urpm, $medium, $b_nocheck_access) = @_;

    if (name2medium($urpm, $medium->{name})) {
	$urpm->{error}(N("trying to override existing medium \"%s\", skipping", $medium->{name}));
	return;
    }

    check_existing_medium($urpm, $medium, $b_nocheck_access);

    #- probe removable device.
    $urpm->probe_removable_device($medium);

    #- clear URLs for trailing /es.
    $medium->{url} and $medium->{url} =~ s|(.*?)/*$|$1|;

    push @{$urpm->{media}}, $medium;
}

#- returns the removable device name if it corresponds to an iso image, '' otherwise
sub is_iso {
    my ($removable_dev) = @_;
    $removable_dev && $removable_dev =~ /\.iso$/i;
}

sub protocol_from_url {
    my ($url) = @_;
    $url =~ m!^([^:_]*)[^:]*:! && $1;
}
sub file_from_local_url {
    my ($url) = @_;
    $url =~ m!^(?:removable[^:]*:/|file:/)?(/.*)! && $1;
}
sub file_from_file_url {
    my ($url) = @_;
    $url =~ m!^(?:file:/)?(/.*)! && $1;
}

sub _hdlist_dir {
    my ($medium) = @_;
    my $base = file_from_file_url($medium->{url}) || $medium->{url};
    $medium->{with_hdlist} && reduce_pathname("$base/$medium->{with_hdlist}/..");
}
sub _url_with_hdlist {
    my ($medium) = @_;

    my $base = file_from_file_url($medium->{url}) || $medium->{url};
    $medium->{with_hdlist} && reduce_pathname("$base/$medium->{with_hdlist}");
}
sub hdlist_or_synthesis_for_virtual_medium {
    my ($medium) = @_;
    file_from_file_url($medium->{url}) && _url_with_hdlist($medium);
}

sub statedir_hdlist_or_synthesis {
    my ($urpm, $medium) = @_;
    $medium->{hdlist} && "$urpm->{statedir}/" . ($medium->{synthesis} ? 'synthesis.' : '') . $medium->{hdlist};
}
sub statedir_hdlist {
    my ($urpm, $medium) = @_;
    $medium->{hdlist} && "$urpm->{statedir}/$medium->{hdlist}";
}
sub statedir_synthesis {
    my ($urpm, $medium) = @_;
    $medium->{hdlist} && "$urpm->{statedir}/synthesis.$medium->{hdlist}";
}
sub statedir_list {
    my ($urpm, $medium) = @_;
    $medium->{list} && "$urpm->{statedir}/$medium->{list}";
}
sub statedir_descriptions {
    my ($urpm, $medium) = @_;
    $medium->{name} && "$urpm->{statedir}/descriptions.$medium->{name}";
}
sub statedir_names {
    my ($urpm, $medium) = @_;
    $medium->{name} && "$urpm->{statedir}/names.$medium->{name}";
}
sub cachedir_hdlist {
    my ($urpm, $medium) = @_;
    $medium->{hdlist} && "$urpm->{cachedir}/partial/$medium->{hdlist}";
}
sub cachedir_list {
    my ($urpm, $medium) = @_;
    $medium->{list} && "$urpm->{cachedir}/partial/$medium->{list}";
}

sub name2medium {
    my ($urpm, $name) = @_;
    my ($medium) = grep { $_->{name} eq $name } @{$urpm->{media}};
    $medium;
}

#- probe device associated with a removable device.
sub probe_removable_device {
    my ($urpm, $medium) = @_;

    if ($medium->{url} && $medium->{url} =~ /^removable/) {
	#- try to find device name in url scheme, this is deprecated, use medium option "removable" instead
	if ($medium->{url} =~ /^removable_?([^_:]*)/) {
	    $medium->{removable} ||= $1 && "/dev/$1";
	}
    } else {
	delete $medium->{removable};
	return;
    }

    #- try to find device to open/close for removable medium.
    if (my $dir = file_from_local_url($medium->{url})) {
	my %infos;
	my @mntpoints = urpm::sys::find_mntpoints($dir, \%infos);
	if (@mntpoints > 1) {	#- return value is suitable for an hash.
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


sub write_MD5SUM {
    my ($urpm) = @_;

    #- write MD5SUM file
    my $fh = $urpm->open_safe('>', "$urpm->{statedir}/MD5SUM") or return 0;
    foreach my $medium (grep { $_->{md5sum} } @{$urpm->{media}}) {
	my $s = basename(statedir_hdlist_or_synthesis($urpm, $medium));
	print $fh "$medium->{md5sum}  $s\n";
    }

    $urpm->{log}(N("wrote %s", "$urpm->{statedir}/MD5SUM"));

    delete $urpm->{md5sum_modified};
}

#- Writes the urpmi.cfg file.
sub write_urpmi_cfg {
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

	foreach (@PER_MEDIA_OPT) {
	    defined $medium->{$_} and $config->{$medium_name}{$_} = $medium->{$_};
	}
    }
    remove_passwords_and_write_private_netrc($urpm, $config);

    urpm::cfg::dump_config($urpm->{config}, $config)
	or $urpm->{fatal}(6, N("unable to write config file [%s]", $urpm->{config}));

    $urpm->{log}(N("wrote config file [%s]", $urpm->{config}));

    #- everything should be synced now.
    delete $urpm->{modified};
}

sub write_config {
    my ($urpm) = @_;

    write_urpmi_cfg($urpm);
    write_MD5SUM($urpm);
}

sub _configure_parallel {
    my ($urpm, $alias) = @_;
    my @parallel_options;
    #- read parallel configuration
    foreach (cat_("/etc/urpmi/parallel.cfg")) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	/\s*([^:]*):(.*)/ or $urpm->{error}(N("unable to parse \"%s\" in file [%s]", $_, "/etc/urpmi/parallel.cfg")), next;
	$1 eq $alias and push @parallel_options, $2;
    }
    #- if a configuration option has been found, use it; else fatal error.
    my $parallel_handler;
    if (@parallel_options) {
	foreach my $dir (grep { -d $_ } map { "$_/urpm" } @INC) {
	    foreach my $pm (grep { -f $_ } glob("$dir/parallel*.pm")) {
		#- load parallel modules
		$urpm->{log}->(N("examining parallel handler in file [%s]", $pm));
		# perl_checker: require urpm::parallel_ka_run
		# perl_checker: require urpm::parallel_ssh
		eval { require $pm; $parallel_handler = $urpm->handle_parallel_options(join("\n", @parallel_options)) };
		$parallel_handler and last;
	    }
	    $parallel_handler and last;
	}
    }
    if ($parallel_handler) {
	if ($parallel_handler->{nodes}) {
	    $urpm->{log}->(N("found parallel handler for nodes: %s", join(', ', keys %{$parallel_handler->{nodes}})));
	}
	$urpm->{parallel_handler} = $parallel_handler;
    } else {
	$urpm->{fatal}(1, N("unable to use parallel option \"%s\"", $alias));
    }
}

#- read urpmi.cfg file as well as necessary synthesis files
#- options :
#-	root
#-	cmdline_skiplist
#-      nocheck_access (used by read_config)
#-
#-	callback (urpmf)
#-	need_hdlist (for urpmf: to be able to have info not available in synthesis)
#-	nodepslist (for urpmq: we don't need the hdlist/synthesis)
#-	no_skiplist (urpmf)
#-
#-	synthesis (use this synthesis file, and only this synthesis file)
#-
#-	usedistrib (otherwise uses urpmi.cfg)
#-	parallel
#-	  media
#-	  excludemedia
#-	  sortmedia
#-
#-	  update
#-	  searchmedia
sub configure {
    my ($urpm, %options) = @_;

    $urpm->clean;

    $options{parallel} && $options{usedistrib} and $urpm->{fatal}(1, N("Can't use parallel mode with use-distrib mode"));

    if ($options{parallel}) {
	_configure_parallel($urpm, $options{parallel});

	if (!$options{media} && $urpm->{parallel_handler}{media}) {
	    $options{media} = $urpm->{parallel_handler}{media};
	    $urpm->{log}->(N("using associated media for parallel mode: %s", $options{media}));
	}
    } else {
	#- nb: can't have both parallel and root
	$urpm->{root} = $options{root};
    }

    $urpm->{root} && ! -c "$urpm->{root}/dev/null"
	and $urpm->{error}(N("there doesn't seem to be devices in the chroot in \"%s\"", $urpm->{root}));

    if ($options{synthesis}) {
	if ($options{synthesis} ne 'none') {
	    #- synthesis take precedence over media, update options.
	    $options{media} || $options{excludemedia} || $options{sortmedia} || $options{update} || $options{usedistrib} || $options{parallel} and
	      $urpm->{fatal}(1, N("--synthesis cannot be used with --media, --excludemedia, --sortmedia, --update, --use-distrib or --parallel"));
	    $urpm->parse_synthesis($options{synthesis});
	    #- synthesis disables the split of transaction (too risky and not useful).
	    $urpm->{options}{'split-length'} = 0;
	}
    } else {
        if ($options{usedistrib}) {
            $urpm->{media} = [];
            $urpm->add_distrib_media("Virtual", $options{usedistrib}, %options, 'virtual' => 1);
        } else {
	    $urpm->read_config($options{nocheck_access});
	    if (!$options{media} && $urpm->{options}{'default-media'}) {
		$options{media} = $urpm->{options}{'default-media'};
	    }
        }
	if ($options{media}) {
	    delete $_->{modified} foreach @{$urpm->{media} || []};
	    $urpm->select_media(split /,/, $options{media});
	    foreach (grep { !$_->{modified} } @{$urpm->{media} || []}) {
		#- this is only a local ignore that will not be saved.
		$_->{tempignore} = $_->{ignore} = 1;
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
	    foreach (select_media_by_name($urpm, [ split /,/, $options{excludemedia} ])) {
		$_->{modified} = 1;
		#- this is only a local ignore that will not be saved.
		$_->{tempignore} = $_->{ignore} = 1;
	    }
	}
	if ($options{sortmedia}) {
	    my @sorted_media = map { select_media_by_name($urpm, [$_]) } split(/,/, $options{sortmedia});
	    my @remaining = difference2($urpm->{media}, \@sorted_media);
	    $urpm->{media} = [ @sorted_media, @remaining ];
	}
	unless ($options{nodepslist}) {
	    my $second_pass;
	    do {
		foreach (grep { !$_->{ignore} && (!$options{update} || $_->{update}) } @{$urpm->{media} || []}) {
		    our $currentmedia = $_; #- hack for urpmf
		    delete @$_{qw(start end)};
		    if ($_->{virtual}) {
			if (file_from_file_url($_->{url})) {
			    if ($_->{synthesis}) {
				_parse_synthesis($urpm, $_,
				    hdlist_or_synthesis_for_virtual_medium($_), $options{callback});
			    } else {
				#- we'll need a second pass
				defined $second_pass or $second_pass = 1;
				_parse_hdlist($urpm, $_,
				    hdlist_or_synthesis_for_virtual_medium($_),
				    $second_pass ? undef : $options{callback},
				);
			    }
			} else {
			    $urpm->{error}(N("virtual medium \"%s\" is not local, medium ignored", $_->{name}));
			    $_->{ignore} = 1;
			}
		    } else {
			if ($options{need_hdlist} && file_size(statedir_hdlist($urpm, $_)) > 32) {
			    _parse_hdlist($urpm, $_, statedir_hdlist($urpm, $_), $options{callback});
			} else {
			    if (!_parse_synthesis($urpm, $_,
						  statedir_synthesis($urpm, $_),
						  $options{callback})) {
				_parse_hdlist($urpm, $_, statedir_hdlist($urpm, $_), $options{callback});
			    }
			}
		    }
		    unless ($_->{ignore}) {
			_check_after_reading_hdlist_or_synthesis($urpm, $_);
		    }
		    unless ($_->{ignore}) {
			    if ($_->{searchmedia}) {
			        ($urpm->{searchmedia}{start}, $urpm->{searchmedia}{end}) = ($_->{start}, $_->{end});
				$urpm->{log}(N("Search start: %s end: %s",
					$urpm->{searchmedia}{start}, $urpm->{searchmedia}{end}));
				delete $_->{searchmedia};
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
    unless ($options{nodepslist} || $options{no_skiplist}) {
	my %uniq;
	$urpm->compute_flags(
	    get_packages_list($urpm->{skiplist}, $options{cmdline_skiplist}),
	    skip => 1,
	    callback => sub {
		my ($urpm, $pkg) = @_;
		$pkg->is_arch_compat && ! exists $uniq{$pkg->fullname} or return;
		$uniq{$pkg->fullname} = undef;
		$urpm->{log}(N("skipping package %s", scalar($pkg->fullname)));
	    },
	);
    }
    unless ($options{nodepslist}) {
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
}

#- add a new medium, sync the config file accordingly.
#- returns the new medium's name. (might be different from the requested
#- name if index_name was specified)
#- options: ignore, index_name, nolock, update, virtual
sub add_medium {
    my ($urpm, $name, $url, $with_hdlist, %options) = @_;

    #- make sure configuration has been read.
    $urpm->{media} or die "caller should have used ->read_config or ->configure first";
    $urpm->lock_urpmi_db('exclusive') if !$options{nolock};

    #- if a medium with that name has already been found, we have to exit now
    my $medium;
    if (defined $options{index_name}) {
	my $i = $options{index_name};
	do {
	    ++$i;
	    $medium = name2medium($urpm, $name . $i);
	} while $medium;
	$name .= $i;
    } else {
	$medium = name2medium($urpm, $name);
    }
    $medium and $urpm->{fatal}(5, N("medium \"%s\" already exists", $medium->{name}));

    $url =~ s,/*$,,; #- clear URLs for trailing /es.

    #- creating the medium info.
    $medium = { name => $name, url => $url, update => $options{update}, modified => 1, ignore => $options{ignore} };
    if ($options{virtual}) {
	file_from_file_url($url) or $urpm->{fatal}(1, N("virtual medium needs to be local"));
	$medium->{virtual} = 1;
    } else {
	$medium->{hdlist} = "hdlist.$name.cz";
	$urpm->probe_removable_device($medium);
    }

    #- local media have priority, other are added at the end.
    if (file_from_file_url($url)) {
	$medium->{priority} = 0.5;
    } else {
	$medium->{priority} = 1 + @{$urpm->{media}};
    }

    $with_hdlist and $medium->{with_hdlist} = $with_hdlist;

    #- create an entry in media list.
    push @{$urpm->{media}}, $medium;

    $urpm->{log}(N("added medium %s", $name));
    $urpm->{modified} = 1;

    $options{nolock} or $urpm->unlock_urpmi_db;
    $name;
}

#- add distribution media, according to url given.
#- returns the list of names of added media.
#- options :
#- - initial_number : when adding several numbered media, start with this number
#- - probe_with : if eq 'synthesis', use synthesis instead of hdlists
#- - ask_media : callback to know whether each media should be added
#- other options are passed to add_medium(): ignore, nolock, virtual
sub add_distrib_media {
    my ($urpm, $name, $url, %options) = @_;

    #- make sure configuration has been read.
    $urpm->{media} or die "caller should have used ->read_config or ->configure first";

    my $distribconf;

    if (my $dir = file_from_local_url($url)) {
	$urpm->try_mounting($dir)
	    or $urpm->{error}(N("unable to mount the distribution medium")), return ();
	$distribconf = MDV::Distribconf->new($dir, undef);
	$distribconf->load
	    or $urpm->{error}(N("this location doesn't seem to contain any distribution")), return ();
    } else {
	unlink "$urpm->{cachedir}/partial/media.cfg";

	$distribconf = MDV::Distribconf->new($url, undef);
	$distribconf->settree('mandriva');

	$urpm->{log}(N("retrieving media.cfg file..."));
	if (sync_webfetch($urpm, undef,
			  [ reduce_pathname($distribconf->getfullpath(undef, 'infodir') . '/media.cfg') ],
			  quiet => 1)) {
	    $urpm->{log}(N("...retrieving done"));
	    $distribconf->parse_mediacfg("$urpm->{cachedir}/partial/media.cfg")
		or $urpm->{error}(N("unable to parse media.cfg")), return();
	} else {
	    $urpm->{error}(N("...retrieving failed: %s", $@));
	    $urpm->{error}(N("unable to access the distribution medium (no media.cfg file found)"));
	    return ();
	}
    }

    #- cosmetic update of name if it contains spaces.
    $name =~ /\s/ and $name .= ' ';

    my @newnames;
    #- at this point, we have found a media.cfg file, so parse it
    #- and create all necessary media according to it.
    my $medium = $options{initial_number} || 1;

    foreach my $media ($distribconf->listmedia) {
        my $skip = 0;
	# if one of those values is set, by default, we skip adding the media
	foreach (qw(noauto)) {
	    $distribconf->getvalue($media, $_) and do {
		$skip = 1;
		last;
	    };
	}
        if ($options{ask_media}) {
            if ($options{ask_media}->(
                $distribconf->getvalue($media, 'name'),
                !$skip,
            )) {
                $skip = 0;
            } else {
                $skip = 1;
            }
        }
        $skip and next;

        my $media_name = $distribconf->getvalue($media, 'name') || '';
	my $is_update_media = $distribconf->getvalue($media, 'updates_for');

	push @newnames, $urpm->add_medium(
	    $name ? "$media_name ($name$medium)" : $media_name,
	    reduce_pathname($distribconf->getfullpath($media, 'path')),
	    offset_pathname(
		$url,
		$distribconf->getpath($media, 'path'),
	    ) . '/' . $distribconf->getpath($media, $options{probe_with} eq 'synthesis' ? 'synthesis' : 'hdlist'),
	    index_name => $name ? undef : 0,
	    %options,
	    # the following override %options
	    update => $is_update_media ? 1 : undef,
	);
	++$medium;
    }
    return @newnames;
}

#- deprecated, use select_media_by_name instead
sub select_media {
    my $urpm = shift;
    my $options = {};
    if (ref $_[0]) { $options = shift }
    foreach (select_media_by_name($urpm, [ @_ ], $options->{strict_match})) {
	#- select medium by setting the modified flag, do not check ignore.
	$_->{modified} = 1;
    }
}

sub select_media_by_name {
    my ($urpm, $names, $b_strict_match) = @_;

    my %wanted = map { $_ => 1 } @$names;

    #- first the exact matches
    my @l = grep { delete $wanted{$_->{name}} } @{$urpm->{media}};

    #- check if some arguments don't correspond to the medium name.
    #- in such case, try to find the unique medium (or list candidate
    #- media found).
    foreach (keys %wanted) {
	my $q = quotemeta;
	my (@found, @foundi);
	my $regex  = $b_strict_match ? qr/^$q$/  : qr/$q/;
	my $regexi = $b_strict_match ? qr/^$q$/i : qr/$q/i;
	foreach my $medium (@{$urpm->{media}}) {
	    $medium->{name} =~ $regex  and push @found, $medium;
	    $medium->{name} =~ $regexi and push @foundi, $medium;
	}
	@found = @foundi if !@found;

	if (@found == 0) {
	    $urpm->{error}(N("trying to select nonexistent medium \"%s\"", $_));
	} else {
	    if (@found > 1) {
		$urpm->{log}(N("selecting multiple media: %s", join(", ", map { qq("$_->{name}") } @found)));
	    }
	    #- changed behaviour to select all occurences by default.
	    push @l, @found;
	}
    }
    @l;
}

#- deprecated, use remove_media instead
sub remove_selected_media {
    my ($urpm) = @_;

    remove_media($urpm, [ grep { $_->{modified} } @{$urpm->{media}} ]);
}

sub remove_media {
    my ($urpm, $to_remove) = @_;

    foreach my $medium (@$to_remove) {
	$urpm->{log}(N("removing medium \"%s\"", $medium->{name}));

	#- mark to re-write configuration.
	$urpm->{modified} = 1;

	#- remove files associated with this medium.
	unlink grep { $_ } map { $_->($urpm, $medium) } \&statedir_hdlist, \&statedir_list, \&statedir_synthesis, \&statedir_descriptions, \&statedir_names;

	#- remove proxy settings for this media
	urpm::download::remove_proxy_media($medium->{name});
    }

    $urpm->{media} = [ difference2($urpm->{media}, $to_remove) ];
}

#- return list of synthesis or hdlist reference to probe.
sub _probe_with_try_list {
    my ($probe_with) = @_;

    my @probe_synthesis = (
	"media_info/synthesis.hdlist.cz",
	"synthesis.hdlist.cz",
    );
    my @probe_hdlist = (
	"media_info/hdlist.cz",
	"hdlist.cz",
    );
    $probe_with =~ /synthesis/
      ? (@probe_synthesis, @probe_hdlist)
      : (@probe_hdlist, @probe_synthesis);
}

sub may_reconfig_urpmi {
    my ($urpm, $medium) = @_;

    my $f;
    if (my $dir = file_from_file_url($medium->{url})) {
	$f = reduce_pathname("$dir/reconfig.urpmi");
    } else {
	unlink($f = "$urpm->{cachedir}/partial/reconfig.urpmi");
	sync_webfetch($urpm, $medium, [ reduce_pathname("$medium->{url}/reconfig.urpmi") ], quiet => 1);
    }
    if (-s $f) {
	reconfig_urpmi($urpm, $f, $medium->{name});
    }
    unlink $f if !file_from_file_url($medium->{url});
}

#- read a reconfiguration file for urpmi, and reconfigure media accordingly
#- $rfile is the reconfiguration file (local), $name is the media name
#-
#- the format is similar to the RewriteRule of mod_rewrite, so:
#-    PATTERN REPLACEMENT [FLAG]
#- where FLAG can be L or N
#-
#- example of reconfig.urpmi:
#-    # this is an urpmi reconfiguration file
#-    /cooker /cooker/$ARCH
sub reconfig_urpmi {
    my ($urpm, $rfile, $name) = @_;
    -r $rfile or return;

    $urpm->{log}(N("reconfiguring urpmi for media \"%s\"", $name));

    my ($magic, @lines) = cat_($rfile);
    #- the first line of reconfig.urpmi must be magic, to be sure it's not an error file
    $magic =~ /^# this is an urpmi reconfiguration file/ or return undef;

    my @replacements;
    foreach (@lines) {
	chomp;
	s/^\s*//; s/#.*$//; s/\s*$//;
	$_ or next;
	my ($p, $r, $f) = split /\s+/, $_, 3;
	push @replacements, [ quotemeta $p, $r, $f || 1 ];
    }

    my $reconfigured = 0;
    my @reconfigurable = qw(url with_hdlist);

    my $medium = name2medium($urpm, $name) or return;
    my %orig = %$medium;

  URLS:
    foreach my $k (@reconfigurable) {
	foreach my $r (@replacements) {
	    if ($medium->{$k} =~ s/$r->[0]/$r->[1]/) {
		$reconfigured = 1;
		#- Flags stolen from mod_rewrite: L(ast), N(ext)
		if ($r->[2] =~ /L/) {
		    last;
		} elsif ($r->[2] =~ /N/) { #- dangerous option
		    redo URLS;
		}
	    }
	}
	#- check that the new url exists before committing changes (local mirrors)
	my $file = file_from_local_url($medium->{$k});
	if ($file && !-e $file) {
	    %$medium = %orig;
	    $reconfigured = 0;
	    $urpm->{log}(N("...reconfiguration failed"));
	    return;
	}
    }

    if ($reconfigured) {
	$urpm->{log}(N("reconfiguration done"));
	$urpm->write_config;
    }
    $reconfigured;
}

sub _guess_hdlist_suffix {
    my ($url) = @_;
    $url =~ m!\bmedia/(\w+)/*\Z! && $1;
}

sub _hdlist_suffix {
    my ($medium) = @_;
    $medium->{with_hdlist} =~ /hdlist(.*?)(?:\.src)?\.cz$/ ? $1 : '';
}

sub _update_media__when_not_modified {
    my ($urpm, $medium) = @_;

    delete @$medium{qw(start end)};
    if ($medium->{virtual}) {
	if (file_from_file_url($medium->{url})) {
	    _parse_maybe_hdlist_or_synthesis($urpm, $medium, hdlist_or_synthesis_for_virtual_medium($medium));
	} else {
	    $urpm->{error}(N("virtual medium \"%s\" is not local, medium ignored", $medium->{name}));
	    $medium->{ignore} = 1;
	}
    } else {
	if (!_parse_synthesis($urpm, $medium, statedir_synthesis($urpm, $medium))) {
	    _parse_hdlist($urpm, $medium, statedir_hdlist($urpm, $medium));
	}
    }
    unless ($medium->{ignore}) {
	_check_after_reading_hdlist_or_synthesis($urpm, $medium);
    }
}

sub _parse_hdlist_or_synthesis__virtual {
    my ($urpm, $medium) = @_;

    if (my $hdlist_or = hdlist_or_synthesis_for_virtual_medium($medium)) {
	delete $medium->{modified};
	$urpm->{md5sum_modified} = 1;
	_parse_maybe_hdlist_or_synthesis($urpm, $medium, $hdlist_or);
	_check_after_reading_hdlist_or_synthesis($urpm, $medium);
    } else {
	$urpm->{error}(N("virtual medium \"%s\" should have valid source hdlist or synthesis, medium ignored",
			 $medium->{name}));
	$medium->{ignore} = 1;
    }
}

#- names.<media_name> is used by external progs (namely for bash-completion)
sub generate_media_names {
    my ($urpm) = @_;

    #- make sure names files are regenerated.
    foreach (@{$urpm->{media}}) {
	unlink statedir_names($urpm, $_);
	if (is_valid_medium($_)) {
	    if (my $fh = $urpm->open_safe(">", statedir_names($urpm, $_))) {
		foreach ($_->{start} .. $_->{end}) {
		    if (defined $urpm->{depslist}[$_]) {
			print $fh $urpm->{depslist}[$_]->name . "\n";
		    } else {
			$urpm->{error}(N("Error generating names file: dependency %d not found", $_));
		    }
		}
	    } else {
		$urpm->{error}(N("Error generating names file: Can't write to file (%s)", $!));
	    }
	}
    }
}


sub _read_existing_synthesis_and_hdlist_if_same_time_and_msize {
    my ($urpm, $medium, $basename) = @_;

    same_size_and_mtime("$urpm->{cachedir}/partial/$basename", 
			statedir_hdlist($urpm, $medium)) or return;

    unlink "$urpm->{cachedir}/partial/$basename";

    _read_existing_synthesis_and_hdlist($urpm, $medium);

    1;
}

sub _read_existing_synthesis_and_hdlist_if_same_md5sum {
    my ($urpm, $medium, $retrieved_md5sum) = @_;

    #- if an existing hdlist or synthesis file has the same md5sum, we assume the
    #- files are the same.
    #- if local md5sum is the same as distant md5sum, this means there is no need to
    #- download hdlist or synthesis file again.
    $retrieved_md5sum && $medium->{md5sum} eq $retrieved_md5sum or return;

    unlink "$urpm->{cachedir}/partial/" . basename($medium->{with_hdlist});

    _read_existing_synthesis_and_hdlist($urpm, $medium);

    1;
}

sub _read_existing_synthesis_and_hdlist {
    my ($urpm, $medium) = @_;

    $urpm->{log}(N("medium \"%s\" is up-to-date", $medium->{name}));

    #- the medium is now considered not modified.
    $medium->{modified} = 0;
    #- XXX we could link the new hdlist to the old one.
    #- (However links need to be managed. see bug #12391.)
    #- as previously done, just read synthesis file here, this is enough.
    if (!_parse_synthesis($urpm, $medium, statedir_synthesis($urpm, $medium))) {
	_parse_hdlist($urpm, $medium, statedir_hdlist($urpm, $medium));
	_check_after_reading_hdlist_or_synthesis($urpm, $medium);
    }

    1;
}

sub _parse_hdlist {
    my ($urpm, $medium, $hdlist_file, $o_callback) = @_;

    $urpm->{log}(N("examining hdlist file [%s]", $hdlist_file));
    ($medium->{start}, $medium->{end}) = 
      $urpm->parse_hdlist($hdlist_file, packing => 1, $o_callback ? (callback => $o_callback) : @{[]});
}

sub _parse_synthesis {
    my ($urpm, $medium, $synthesis_file, $o_callback) = @_;

    $urpm->{log}(N("examining synthesis file [%s]", $synthesis_file));
    ($medium->{start}, $medium->{end}) = 
      $urpm->parse_synthesis($synthesis_file, $o_callback ? (callback => $o_callback) : @{[]});
}
sub _parse_maybe_hdlist_or_synthesis {
    my ($urpm, $medium, $hdlist_or) = @_;

    if ($medium->{synthesis}) {
	if (_parse_synthesis($urpm, $medium, $hdlist_or)) {
	    $medium->{synthesis} = 1;
	} elsif (_parse_hdlist($urpm, $medium, $hdlist_or)) {
	    delete $medium->{synthesis};
	} else {
	    return;
	}
    } else {
	if (_parse_hdlist($urpm, $medium, $hdlist_or)) {
	    delete $medium->{synthesis};
	} elsif (_parse_synthesis($urpm, $medium, $hdlist_or)) {
	    $medium->{synthesis} = 1;
	} else {
	    return;
	}
    }
    1;
}

sub _build_hdlist_using_rpm_headers {
    my ($urpm, $medium) = @_;

    $urpm->{log}(N("building hdlist [%s]", statedir_hdlist($urpm, $medium)));
    #- finish building operation of hdlist.
    $urpm->build_hdlist(start  => $medium->{start},
			end    => $medium->{end},
			dir    => "$urpm->{cachedir}/headers",
			hdlist => statedir_hdlist($urpm, $medium),
		    );
}

sub _build_synthesis {
    my ($urpm, $medium) = @_;

    eval { $urpm->build_synthesis(
	start     => $medium->{start},
	end       => $medium->{end},
	synthesis => statedir_synthesis($urpm, $medium),
    ) };
    if ($@) {
	$urpm->{error}(N("Unable to build synthesis file for medium \"%s\". Your hdlist file may be corrupted.", $medium->{name}));
	$urpm->{error}($@);
	unlink statedir_synthesis($urpm, $medium);
    } else {
	$urpm->{log}(N("built hdlist synthesis file for medium \"%s\"", $medium->{name}));
    }
    #- keep in mind we have a modified database, sure at this point.
    $urpm->{md5sum_modified} = 1;
}

sub is_valid_medium {
    my ($medium) = @_;
    defined $medium->{start} && defined $medium->{end};
}

sub _check_after_reading_hdlist_or_synthesis {
    my ($urpm, $medium) = @_;

    if (!is_valid_medium($medium)) {
	$urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $medium->{name}));
	$medium->{ignore} = 1;
    }
}

sub db_open_or_die {
    my ($urpm, $root, $b_force) = @_;

    my $db = URPM::DB::open($root, $b_force)
      or $urpm->{fatal}(9, N("unable to open rpmdb"));

    $db;
}

sub _get_list_or_pubkey__local {
    my ($urpm, $medium, $name) = @_;

    my $path = _hdlist_dir($medium) . "/$name" . _hdlist_suffix($medium);
    -e $path or $path = file_from_local_url($medium->{url}) . "/$name";
    if (-e $path) {
	copy_and_own($path, "$urpm->{cachedir}/partial/$name")
	  or $urpm->{error}(N("...copying failed")), return;
    }
    1;
}

sub _get_list_or_pubkey__remote {
    my ($urpm, $medium, $name) = @_;

    my $found;
    if (_hdlist_suffix($medium)) {
	my $local_name = $name . _hdlist_suffix($medium);

	if (sync_webfetch($urpm, $medium, [_hdlist_dir($medium) . "/$local_name"], 
			  quiet => 1)) {
	    rename("$urpm->{cachedir}/partial/$local_name", "$urpm->{cachedir}/partial/$name");
	    $found = 1;
	}
    }
    if (!$found) {
	sync_webfetch($urpm, $medium, [reduce_pathname("$medium->{url}/$name")], quiet => 1)
	  or unlink "$urpm->{cachedir}/partial/$name";
    }
}

sub clean_dir {
    my ($dir) = @_;

    require File::Path;
    File::Path::rmtree([$dir]);
    mkdir $dir, 0755;
}

sub get_descriptions_local {
    my ($urpm, $medium) = @_;

    unlink statedir_descriptions($urpm, $medium);

    my $dir = file_from_local_url($medium->{url});
    my $description_file = "$dir/media_info/descriptions"; #- new default location
    -e $description_file or $description_file = "$dir/../descriptions";
    -e $description_file or return;

    $urpm->{log}(N("copying description file of \"%s\"...", $medium->{name}));
    if (copy_and_own($description_file, statedir_descriptions($urpm, $medium))) {
	$urpm->{log}(N("...copying done"));
    } else {
	$urpm->{error}(N("...copying failed"));
	$medium->{ignore} = 1;
    }
}
sub get_descriptions_remote {
    my ($urpm, $medium) = @_;

    unlink "$urpm->{cachedir}/partial/descriptions";

    if (-e statedir_descriptions($urpm, $medium)) {
	urpm::util::move(statedir_descriptions($urpm, $medium), "$urpm->{cachedir}/partial/descriptions");
    }
    sync_webfetch($urpm, $medium, [ reduce_pathname("$medium->{url}/media_info/descriptions") ], quiet => 1) 
      or #- try older location
	sync_webfetch($urpm, $medium, [ reduce_pathname("$medium->{url}/../descriptions") ], quiet => 1);

    if (-e "$urpm->{cachedir}/partial/descriptions") {
	urpm::util::move("$urpm->{cachedir}/partial/descriptions", statedir_descriptions($urpm, $medium));
    }
}
sub get_hdlist_or_synthesis__local {
    my ($urpm, $medium, $callback) = @_;

    unlink cachedir_hdlist($urpm, $medium);
    $urpm->{log}(N("copying source hdlist (or synthesis) of \"%s\"...", $medium->{name}));
    $callback and $callback->('copy', $medium->{name});
    if (copy_and_own(_url_with_hdlist($medium), cachedir_hdlist($urpm, $medium))) {
	$callback and $callback->('done', $medium->{name});
	$urpm->{log}(N("...copying done"));
	if (file_size(cachedir_hdlist($urpm, $medium)) <= 32) {
	    $urpm->{error}(N("copy of [%s] failed (file is suspiciously small)", cachedir_hdlist($urpm, $medium)));
	    0;
	} else {
	    1;
	}
    } else {
	$callback and $callback->('failed', $medium->{name});
	#- force error, reported afterwards
	unlink cachedir_hdlist($urpm, $medium);
	0;
    }
}

sub get_hdlist_or_synthesis_and_check_md5sum__local {
    my ($urpm, $medium, $retrieved_md5sum, $callback) = @_;

    get_hdlist_or_synthesis__local($urpm, $medium, $callback) or return;

    #- keep checking md5sum of file just copied ! (especially on nfs or removable device).
    if ($retrieved_md5sum) {
	$urpm->{log}(N("computing md5sum of copied source hdlist (or synthesis)"));
	md5sum(cachedir_hdlist($urpm, $medium)) eq $retrieved_md5sum or
	  $urpm->{error}(N("copy of [%s] failed (md5sum mismatch)", _url_with_hdlist($medium))), return;
    }

    1;
}

sub _read_rpms_from_dir {
    my ($urpm, $medium, $second_pass, $clean_cache) = @_;

    my $dir = file_from_local_url($medium->{url});

    $medium->{rpm_files} = [ glob("$dir/*.rpm") ];

    #- check files contains something good!
    if (!@{$medium->{rpm_files}}) {
	$urpm->{error}(N("no rpm files found from [%s]", $dir));
	$medium->{ignore} = 1;
	return;
    }

    #- we need to rebuild from rpm files the hdlist.

    $urpm->{log}(N("reading rpm files from [%s]", $dir));
    my @unresolved_before = grep {
	! defined $urpm->{provides}{$_};
    } keys %{$urpm->{provides} || {}};
    $medium->{start} = @{$urpm->{depslist}};

    eval {
	$medium->{headers} = [ $urpm->parse_rpms_build_headers(
	    dir   => "$urpm->{cachedir}/headers",
	    rpms  => $medium->{rpm_files},
	    clean => $$clean_cache,
	    packing => 1,
	) ];
    };
    if ($@) {
	$urpm->{error}(N("unable to read rpm files from [%s]: %s", $dir, $@));
	delete $medium->{headers}; #- do not propagate these.
	return;
    }

    $medium->{end} = $#{$urpm->{depslist}};
    if ($medium->{start} > $medium->{end}) {
	#- an error occured (provided there are files in input.)
	delete $medium->{start};
	delete $medium->{end};
	$urpm->{fatal}(9, N("no rpms read"));
    }

    #- make sure the headers will not be removed for another media.
    $$clean_cache = 0;
    my @unresolved = grep {
	! defined $urpm->{provides}{$_};
    } keys %{$urpm->{provides} || {}};
    @unresolved_before == @unresolved or $$second_pass = 1;

    delete $medium->{synthesis}; #- when building hdlist by ourself, drop synthesis property.
    1;
}

#- options: callback, force, force_building_hdlist, nomd5sum, nopubkey, probe_with
sub _update_medium__parse_if_unmodified__local {
    my ($urpm, $medium, $second_pass, $clean_cache, $options) = @_;

    my $dir = file_from_local_url($medium->{url});

    if (!-d $dir) {
	#- the directory given does not exist and may be accessible
	#- by mounting some other directory. Try to figure it out and mount
	#- everything that might be necessary.
	$urpm->try_mounting(
	    !$options->{force_building_hdlist} && $medium->{with_hdlist}
	      ? _hdlist_dir($medium) : $dir,
	    #- in case of an iso image, pass its name
	    is_iso($medium->{removable}) && $medium->{removable},
	) or $urpm->{error}(N("unable to access medium \"%s\",
this could happen if you mounted manually the directory when creating the medium.", $medium->{name})), return 'unmodified';
    }

    #- try to probe for possible with_hdlist parameter, unless
    #- it is already defined (and valid).
    if ($options->{probe_with} && !$medium->{with_hdlist}) {
	foreach (_probe_with_try_list($options->{probe_with})) {
	    -e "$dir/$_" or next;
	    if (file_size("$dir/$_") > 32) {
		$medium->{with_hdlist} = $_;
		last;
	    } else {
		$urpm->{error}(N("invalid hdlist file %s for medium \"%s\"", "$dir/$_", $medium->{name}));
		return;
	    }
	}
    }

    if ($medium->{virtual}) {
	#- syncing a virtual medium is very simple, just try to read the file in order to
	#- determine its type, once a with_hdlist has been found (but is mandatory).
	_parse_hdlist_or_synthesis__virtual($urpm, $medium);
    }

    #- examine if a distant MD5SUM file is available.
    #- this will only be done if $with_hdlist is not empty in order to use
    #- an existing hdlist or synthesis file, and to check if download was good.
    #- if no MD5SUM is available, do it as before...
    #- we can assume at this point a basename is existing, but it needs
    #- to be checked for being valid, nothing can be deduced if no MD5SUM
    #- file is present.

    unless ($medium->{virtual}) {
	if ($medium->{with_hdlist}) {
	    my ($retrieved_md5sum);

	    if (!$options->{nomd5sum} && file_size(_hdlist_dir($medium) . '/MD5SUM') > 32) {
		if (local_md5sum($urpm, $medium, $options->{force})) {
		    $retrieved_md5sum = parse_md5sum($urpm, _hdlist_dir($medium) . '/MD5SUM', basename($medium->{with_hdlist}));
		    _read_existing_synthesis_and_hdlist_if_same_md5sum($urpm, $medium, $retrieved_md5sum)
		      and return 'unmodified';
		}
	    }

	    #- if the source hdlist is present and we are not forcing using rpm files
	    if (!$options->{force_building_hdlist} && -e _url_with_hdlist($medium)) {
		if (get_hdlist_or_synthesis_and_check_md5sum__local($urpm, $medium, $retrieved_md5sum, $options->{callback})) {

		    $medium->{md5sum} = $retrieved_md5sum if $retrieved_md5sum;

		    #- check if the files are equal... and no force copy...
		    if (!$options->{force}) {
			_read_existing_synthesis_and_hdlist_if_same_time_and_msize($urpm, $medium, $medium->{hdlist}) 
			  and return 'unmodified';
		    }
		} else {
		    #- if copying hdlist has failed, try to build it directly.
		    if ($urpm->{options}{'build-hdlist-on-error'}) {
			$options->{force_building_hdlist} = 1;
		    } else {
			$urpm->{error}(N("unable to access hdlist file of \"%s\", medium ignored", $medium->{name}));
			$medium->{ignore} = 1;
			return;
		    }
		}
	    }
	} else {
	    #- no available hdlist/synthesis, try to build it from rpms
	    $options->{force_building_hdlist} = 1;
	}

	if ($options->{force_building_hdlist}) {
	    _read_rpms_from_dir($urpm, $medium, $second_pass, $clean_cache) or return;
	}
    }

    1;
}

#- options: callback, force, nomd5sum, nopubkey, probe_with, quiet
sub _update_medium__parse_if_unmodified__remote {
    my ($urpm, $medium, $options) = @_;
    my ($retrieved_md5sum, $basename);

    #- examine if a distant MD5SUM file is available.
    #- this will only be done if $with_hdlist is not empty in order to use
    #- an existing hdlist or synthesis file, and to check if download was good.
    #- if no MD5SUM is available, do it as before...
    if ($medium->{with_hdlist}) {
	#- we can assume at this point a basename is existing, but it needs
	#- to be checked for being valid, nothing can be deduced if no MD5SUM
	#- file is present.
	$basename = basename($medium->{with_hdlist});

	unlink "$urpm->{cachedir}/partial/MD5SUM";
	if (!$options->{nomd5sum} && 
	      sync_webfetch($urpm, $medium, 
			    [ reduce_pathname(_hdlist_dir($medium) . '/MD5SUM') ],
			    quiet => 1) && file_size("$urpm->{cachedir}/partial/MD5SUM") > 32) {
	    if (local_md5sum($urpm, $medium, $options->{force} >= 2)) {
		$retrieved_md5sum = parse_md5sum($urpm, "$urpm->{cachedir}/partial/MD5SUM", $basename);
		_read_existing_synthesis_and_hdlist_if_same_md5sum($urpm, $medium, $retrieved_md5sum)
		  and return 'unmodified';
	    }
	} else {
	    #- at this point, we don't if a basename exists and is valid, let probe it later.
	    $basename = undef;
	}
    }

    #- try to probe for possible with_hdlist parameter, unless
    #- it is already defined (and valid).
    $urpm->{log}(N("retrieving source hdlist (or synthesis) of \"%s\"...", $medium->{name}));
    $options->{callback} and $options->{callback}('retrieve', $medium->{name});
    if ($options->{probe_with} && !$medium->{with_hdlist}) {
	foreach my $with_hdlist (_probe_with_try_list($options->{probe_with})) {
	    $basename = basename($with_hdlist) or next;
	    $options->{force} and unlink "$urpm->{cachedir}/partial/$basename";
	    if (sync_webfetch($urpm, $medium, [ reduce_pathname("$medium->{url}/$with_hdlist") ],
			      quiet => $options->{quiet}, callback => $options->{callback}) && file_size("$urpm->{cachedir}/partial/$basename") > 32) {
		$urpm->{log}(N("...retrieving done"));
		$medium->{with_hdlist} = $with_hdlist;
		$urpm->{log}(N("found probed hdlist (or synthesis) as %s", $medium->{with_hdlist}));
		last;	    #- found a suitable with_hdlist in the list above.
	    }
	}
    } else {
	$basename = basename($medium->{with_hdlist});

	if ($options->{force}) {
	    unlink "$urpm->{cachedir}/partial/$basename";
	} else {
	    #- try to sync (copy if needed) local copy after restored the previous one.
	    #- this is useful for rsync (?)
	    if (-e statedir_hdlist_or_synthesis($urpm, $medium)) {
		copy_and_own(
		    statedir_hdlist_or_synthesis($urpm, $medium),
		    "$urpm->{cachedir}/partial/$basename",
		) or $urpm->{error}(N("...copying failed")), return;
	    }
	}
	if (sync_webfetch($urpm, $medium, [ _url_with_hdlist($medium) ],
			  quiet => $options->{quiet}, callback => $options->{callback})) {
	    $urpm->{log}(N("...retrieving done"));
	} else {
	    $urpm->{error}(N("...retrieving failed: %s", $@));
	    unlink "$urpm->{cachedir}/partial/$basename";
	}
    }

    #- check downloaded file has right signature.
    if (file_size("$urpm->{cachedir}/partial/$basename") > 32 && $retrieved_md5sum) {
	$urpm->{log}(N("computing md5sum of retrieved source hdlist (or synthesis)"));
	unless (md5sum("$urpm->{cachedir}/partial/$basename") eq $retrieved_md5sum) {
	    $urpm->{error}(N("...retrieving failed: md5sum mismatch"));
	    unlink "$urpm->{cachedir}/partial/$basename";
	}
    }

    if (file_size("$urpm->{cachedir}/partial/$basename") > 32) {
	$options->{callback} and $options->{callback}('done', $medium->{name});

	unless ($options->{force}) {
	    _read_existing_synthesis_and_hdlist_if_same_time_and_msize($urpm, $medium, $basename)
	      and return 'unmodified';
	}

	#- the files are different, update local copy.
	rename("$urpm->{cachedir}/partial/$basename", cachedir_hdlist($urpm, $medium));
    } else {
	$options->{callback} and $options->{callback}('failed', $medium->{name});
	$urpm->{error}(N("retrieval of source hdlist (or synthesis) failed"));
	return;
    }
    $urpm->{md5sum} = $retrieved_md5sum if $retrieved_md5sum;
    1;
}

sub _get_pubkey_and_descriptions {
    my ($urpm, $medium, $nopubkey) = @_;

    my $local = file_from_local_url($medium->{url});

    ($local ? \&get_descriptions_local : \&get_descriptions_remote)->($urpm, $medium);

    #- examine if a pubkey file is available.
    if (!$nopubkey && !$medium->{'key-ids'}) {
	($local ? \&_get_list_or_pubkey__local : \&_get_list_or_pubkey__remote)->($urpm, $medium, 'pubkey');
    }
}

sub _read_cachedir_pubkey {
    my ($urpm, $medium) = @_;
    -s "$urpm->{cachedir}/partial/pubkey" or return;

    $urpm->{log}(N("examining pubkey file of \"%s\"...", $medium->{name}));

    my %key_ids;
    $urpm->import_needed_pubkeys(
	[ $urpm->parse_armored_file("$urpm->{cachedir}/partial/pubkey") ],
	root => $urpm->{root}, 
	callback => sub {
	    my (undef, undef, $_k, $id, $imported) = @_;
	    if ($id) {
		$key_ids{$id} = undef;
		$imported and $urpm->{log}(N("...imported key %s from pubkey file of \"%s\"",
					     $id, $medium->{name}));
	    } else {
		$urpm->{error}(N("unable to import pubkey file of \"%s\"", $medium->{name}));
	    }
	});
    if (keys(%key_ids)) {
	$medium->{'key-ids'} = join(',', keys %key_ids);
    }
}

sub _write_rpm_list {
    my ($urpm, $medium) = @_;

    @{$medium->{rpm_files} || []} or return;

    $medium->{list} ||= "list.$medium->{name}";

    #- write list file.
    $urpm->{log}(N("writing list file for medium \"%s\"", $medium->{name}));
    my $listfh = $urpm->open_safe('>', cachedir_list($urpm, $medium)) or return;
    print $listfh basename($_), "\n" foreach @{$medium->{rpm_files}};
    1;
}

#- options: callback, force, force_building_hdlist, nomd5sum, probe_with, quiet
#- (from _update_medium__parse_if_unmodified__local and _update_medium__parse_if_unmodified__remote)
sub _update_medium_first_pass {
    my ($urpm, $medium, $second_pass, $clean_cache, %options) = @_;

    #- we should create the associated synthesis file if it does not already exist...
    file_size(statedir_synthesis($urpm, $medium)) > 32
      or $medium->{must_build_synthesis} = 1;

    unless ($medium->{modified}) {
	#- the medium is not modified, but to compute dependencies,
	#- we still need to read it and all synthesis will be written if
	#- an unresolved provides is found.
	#- to speed up the process, we only read the synthesis at the beginning.
	_update_media__when_not_modified($urpm, $medium);
	return 1;
    }

    #- always delete a remaining list file or pubkey file in cache.
    foreach (qw(list pubkey)) {
	unlink "$urpm->{cachedir}/partial/$_";
    }

    #- check for a reconfig.urpmi file (if not already reconfigured)
    if (!$medium->{noreconfigure}) {
	may_reconfig_urpmi($urpm, $medium);
    }

    {
	my $rc = 
	  file_from_local_url($medium->{url})
	    ? _update_medium__parse_if_unmodified__local($urpm, $medium, $second_pass, $clean_cache, \%options)
	    : _update_medium__parse_if_unmodified__remote($urpm, $medium, \%options);

	if (!$rc || $rc eq 'unmodified') {
	    return $rc;
	}
    }

    #- build list file according to hdlist.
    if (!$medium->{headers} && !$medium->{virtual} && file_size(cachedir_hdlist($urpm, $medium)) <= 32) {
	$urpm->{error}(N("no hdlist file found for medium \"%s\"", $medium->{name}));
	return;
    }

    if (!$medium->{virtual}) {
	if ($medium->{headers}) {
	    _write_rpm_list($urpm, $medium) or return;
	} else {
	    #- read first pass hdlist or synthesis, try to open as synthesis, if file
	    #- is larger than 1MB, this is probably an hdlist else a synthesis.
	    #- anyway, if one tries fails, try another mode.
	    $options{callback} and $options{callback}('parse', $medium->{name});
	    my @unresolved_before = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};

	    #- if it looks like a hdlist, try to parse as hdlist first
	    delete $medium->{synthesis} if file_size(cachedir_hdlist($urpm, $medium)) > 262144;
	    _parse_maybe_hdlist_or_synthesis($urpm, $medium, cachedir_hdlist($urpm, $medium));

	    if (is_valid_medium($medium)) {
		$options{callback} && $options{callback}('done', $medium->{name});
	    } else {
		$urpm->{error}(N("unable to parse hdlist file of \"%s\"", $medium->{name}));
		$options{callback} and $options{callback}('failed', $medium->{name});
		delete $medium->{md5sum};

		#- we have to read back the current synthesis file unmodified.
		if (!_parse_synthesis($urpm, $medium, statedir_synthesis($urpm, $medium))) {
		    $urpm->{error}(N("problem reading synthesis file of medium \"%s\"", $medium->{name}));
		    $medium->{ignore} = 1;
		}
		return;
	    }
	    delete $medium->{list};

	    {
		my @unresolved_after = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};
		@unresolved_before == @unresolved_after or $$second_pass = 1;
	    }
	}
    }

    unless ($medium->{virtual}) {
	    #- make sure to rebuild base files and clear medium modified state.
	    $medium->{modified} = 0;
	    $urpm->{md5sum_modified} = 1;

	    #- but use newly created file.
	    unlink statedir_hdlist($urpm, $medium);
	    $medium->{synthesis} and unlink statedir_synthesis($urpm, $medium);
	    $medium->{list} and unlink statedir_list($urpm, $medium);
	    unless ($medium->{headers}) {
		unlink statedir_synthesis($urpm, $medium);
		unlink statedir_hdlist($urpm, $medium);
		urpm::util::move(cachedir_hdlist($urpm, $medium),
				 statedir_hdlist_or_synthesis($urpm, $medium));
	    }
	    if ($medium->{list}) {
		urpm::util::move(cachedir_list($urpm, $medium), statedir_list($urpm, $medium));
	    }

	    #- and create synthesis file associated.
	    $medium->{must_build_synthesis} = !$medium->{synthesis};
    }
    1;
}

sub _update_medium_first_pass_failed {
    my ($urpm, $medium) = @_;

    !$medium->{virtual} or return;

    #- an error has occured for updating the medium, we have to remove temporary files.
    unlink(glob("$urpm->{cachedir}/partial/*"));
}

#- take care of modified medium only, or all if all have to be recomputed.
sub _update_medium_second_pass {
    my ($urpm, $medium, $callback) = @_;

    $callback and $callback->('parse', $medium->{name});

    #- a modified medium is an invalid medium, we have to read back the previous hdlist
    #- or synthesis which has not been modified by first pass above.

	if ($medium->{headers} && !$medium->{modified}) {
	    $urpm->{log}(N("reading headers from medium \"%s\"", $medium->{name}));
	    ($medium->{start}, $medium->{end}) = $urpm->parse_headers(dir     => "$urpm->{cachedir}/headers",
								      headers => $medium->{headers},
								  );
	} elsif ($medium->{synthesis}) {
	    if ($medium->{virtual}) {
		if (file_from_file_url($medium->{url})) {
		    _parse_synthesis($urpm, $medium, hdlist_or_synthesis_for_virtual_medium($medium));
		}
	    } else {
		_parse_synthesis($urpm, $medium, statedir_synthesis($urpm, $medium));
	    }
	} else {
	    _parse_hdlist($urpm, $medium, statedir_hdlist($urpm, $medium));
	    $medium->{must_build_synthesis} ||= 1;
	}

    $callback && $callback->('done', $medium->{name});
}

sub _update_medium_build_hdlist_synthesis {
    my ($urpm, $medium) = @_;

    if ($medium->{headers} && !$medium->{modified}) {
	_build_hdlist_using_rpm_headers($urpm, $medium);
	#- synthesis needs to be created, since the medium has been built from rpm files.
	_build_synthesis($urpm,  $medium);
    } elsif ($medium->{synthesis}) {
    } else {
	#- check if the synthesis file can be built.
	if ($medium->{must_build_synthesis} && !$medium->{modified} && !$medium->{virtual}) {
	    _build_synthesis($urpm, $medium);
	}
    }
}

sub remove_obsolete_headers_in_cache {
    my ($urpm) = @_;
    my %headers;
    if (my $dh = $urpm->opendir_safe("$urpm->{cachedir}/headers")) {
	local $_;
	while (defined($_ = readdir $dh)) {
	    m|^([^/]*-[^-]*-[^-]*\.[^\.]*)(?::\S*)?$| and $headers{$1} = $_;
	}
    }
    if (%headers) {
	my $previous_total = scalar(keys %headers);
	foreach (@{$urpm->{depslist}}) {
	    delete $headers{$_->fullname};
	}
	$urpm->{log}(N("found %d rpm headers in cache, removing %d obsolete headers", $previous_total, scalar(keys %headers)));
	foreach (values %headers) {
	    unlink "$urpm->{cachedir}/headers/$_";
	}
    }
}

sub _update_media__handle_some_flags {
    my ($urpm, $forcekey, $all) = @_;

    foreach my $medium (grep { !$_->{ignore} } @{$urpm->{media}}) {
	$forcekey and delete $medium->{'key-ids'};

	if ($medium->{static}) {
	    #- don't ever update static media
	    $medium->{modified} = 0;
	} elsif ($all) {
	    #- if we're rebuilding all media, mark them as modified (except removable ones)
	    $medium->{modified} ||= $medium->{url} !~ m!^removable!;
	}
    }
}

#- Update the urpmi database w.r.t. the current configuration.
#- Takes care of modifications, and tries some tricks to bypass
#- the recomputation of base files.
#- Recognized options :
#-   all         : all medias are being rebuilt
#-   callback    : UI callback
#-   forcekey    : force retrieval of pubkey
#-   force       : try to force rebuilding base files
#-   force_building_hdlist
#-   noclean     : keep old files in the header cache directory
#-   nolock      : don't lock the urpmi database
#-   nomd5sum    : don't verify MD5SUM of retrieved files
#-   nopubkey    : don't use rpm pubkeys
#-   probe_with  : probe synthesis or hdlist (or none)
#-   quiet       : download hdlists quietly
sub update_media {
    my ($urpm, %options) = @_;

    $urpm->{media} or return; # verify that configuration has been read

    $options{nopubkey} ||= $urpm->{options}{nopubkey};
    #- get gpg-pubkey signature.
    if (!$options{nopubkey}) {
	$urpm->lock_rpm_db('exclusive');
	$urpm->{keys} or $urpm->parse_pubkeys(root => $urpm->{root});
    }
    #- lock database if allowed.
    $urpm->lock_urpmi_db('exclusive') if !$options{nolock};

    #- examine each medium to see if one of them needs to be updated.
    #- if this is the case and if not forced, try to use a pre-calculated
    #- hdlist file, else build it from rpm files.
    $urpm->clean;

    _update_media__handle_some_flags($urpm, $options{forcekey}, $options{all});

    my $clean_cache = !$options{noclean};
    my $second_pass;
    foreach my $medium (grep { !$_->{ignore} } @{$urpm->{media}}) {
	_update_medium_first_pass($urpm, $medium, \$second_pass, \$clean_cache, %options)
	  or _update_medium_first_pass_failed($urpm, $medium);
    }

    #- some unresolved provides may force to rebuild all synthesis,
    #- a second pass will be necessary.
    if ($second_pass) {
	$urpm->{log}(N("performing second pass to compute dependencies\n"));
	$urpm->unresolved_provides_clean;
    }

    foreach my $medium (grep { !$_->{ignore} } @{$urpm->{media}}) {
	if ($second_pass) {
	    #- second pass consists in reading again synthesis or hdlists.
	    _update_medium_second_pass($urpm, $medium, $options{callback});
	}
	_update_medium_build_hdlist_synthesis($urpm, $medium);

	_get_pubkey_and_descriptions($urpm, $medium, $options{nopubkey});

	_read_cachedir_pubkey($urpm, $medium);

    }

    if ($urpm->{modified}) {
	if ($options{noclean}) {
	    #- clean headers cache directory to remove everything that is no longer
	    #- useful according to the depslist.
	    remove_obsolete_headers_in_cache($urpm);
	}
	#- write config files in any case
	$urpm->write_config;
	dump_proxy_config();
    } elsif ($urpm->{md5sum_modified}) {
	#- NB: in case of $urpm->{modified}, write_MD5SUM is called in write_config above
	write_MD5SUM($urpm);
    }

    generate_media_names($urpm);

    $options{nolock} or $urpm->unlock_urpmi_db;
    $options{nopubkey} or $urpm->unlock_rpm_db;
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
    my ($urpm, $dir, $o_removable) = @_;
    my %infos;

    my $is_iso = is_iso($o_removable);
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
	    sys_log("mount iso $_ on $o_removable");
	    $loopdev and system('mount', $o_removable, $_, '-t', 'iso9660', '-o', "loop=$loopdev");
	} else {
	    sys_log("mount $_");
	    system("mount '$_' 2>/dev/null");
	}
	$o_removable && $infos{$_}{fs} ne 'supermount' and $urpm->{removable_mounted}{$_} = undef;
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
	if (protocol_from_url($_)) {
	    my $basename = basename($_);
	    unlink "$urpm->{cachedir}/partial/$basename";
	    $urpm->{log}(N("retrieving rpm file [%s] ...", $_));
	    if (sync_webfetch($urpm, undef, [$_], quiet => 1)) {
		$urpm->{log}(N("...retrieving done"));
		$_ = "$urpm->{cachedir}/partial/$basename";
	    } else {
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
	    $pkg->arch eq 'src' || $pkg->is_arch_compat
		or $error = 1, $urpm->{error}(N("Incompatible architecture for rpm [%s]", $_)), next;
	    $urpm->{source}{$id} = $_;
	}
    }
    $error and $urpm->{fatal}(2, N("error registering local packages"));
    defined $id && $start <= $id and @requested{($start .. $id)} = (1) x ($id-$start+1);

    #- distribute local packages to distant nodes directly in cache of each machine.
    @files && $urpm->{parallel_handler} and $urpm->{parallel_handler}->parallel_register_rpms($urpm, @files);

    %requested;
}

sub _findindeps {
    my ($urpm, $found, $qv, $v, $caseinsensitive, $src) = @_;

    foreach (keys %{$urpm->{provides}}) {
	#- search through provides to find if a provide matches this one;
	#- but manage choices correctly (as a provides may be virtual or
	#- defined several times).
	/$qv/ || !$caseinsensitive && /$qv/i or next;

	my @list = grep { defined $_ } map {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg && ($src ? $pkg->arch eq 'src' : $pkg->arch ne 'src')
	      ? $pkg->id : undef;
	} keys %{$urpm->{provides}{$_} || {}};
	@list > 0 and push @{$found->{$v}}, join '|', @list;
    }
}

#- search packages registered by their names by storing their ids into the $packages hash.
#- Recognized options:
#-	all
#-	caseinsensitive
#-	fuzzy
#-	src
#-	use_provides
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
		    && (!defined $urpm->{searchmedia} ||
			    $urpm->{searchmedia}{start} <= $_->id
		    	    && $urpm->{searchmedia}{end} >= $_->id)
		    ? $_ : @{[]};
		} map {
		    $urpm->{depslist}[$_];
		} keys %{$urpm->{provides}{$v} || {}})
	    {
		#- we assume that if there is at least one package providing
		#- the resource exactly, this should be the best one; but we
		#- first check if one of the packages has the same name as searched.
		if (my @l2 = grep { $_->name eq $v } @l) {
		    @l = @l2;
		}
		$exact{$v} = join('|', map { $_->id } @l);
		next;
	    }
	}

	if ($options{use_provides} && $options{fuzzy}) {
	    _findindeps($urpm, \%found, $qv, $v, $options{caseinsensitive}, $options{src});
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
		$urpm->{error}(N("No package named %s", $_));
		values(%l) != 0 and $urpm->{error}(
		    N("The following packages contain %s: %s",
			$_, "\n" . join("\n", sort { $a cmp $b } keys %l))
		);
		$result = 0;
	    } else {
		if (!@{$exact_a{$_} || $exact_ra{$_} || []}) {
		    #- we found a non-exact match
		    $result = 'substring';
		}
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
#-	install_src
#-	priority_upgrade
#- %options passed to ->resolve_requested:
#-	callback_choices
#-	keep
#-	nodeps
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
	    is_valid_medium($_) or next;
	    my $f = statedir_synthesis($urpm, $_);
	    system "cat '$f' >> '$file'";
	}
	#- let each node determine what is requested, according to handler given.
	$urpm->{parallel_handler}->parallel_resolve_dependencies($file, $urpm, $state, $requested, %options);
    } else {
	my $db;

	if ($options{rpmdb}) {
	    $db = new URPM;
	    $db->parse_synthesis($options{rpmdb});
	} else {
	    $db = db_open_or_die($urpm, $urpm->{root});
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
	    $db = db_open_or_die($urpm, $urpm->{root});
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
    my ($file, $o_extra) = @_;
    my $val = [];
    open(my $f, '<', $file) or return [];
    foreach (<$f>, split /,/, $o_extra || '') {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	next if $_ eq '';
	push @$val, $_;
    }
    $val;
}

#- select sources for selected packages,
#- according to keys of the packages hash.
#- returns a list of lists containing the source description for each rpm,
#- matching the exact number of registered media; ignored media being
#- associated to a null list.
sub get_source_packages {
    my ($urpm, $packages, %options) = @_;
    my (%protected_files, %local_sources, %fullname2id);

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
    my %file2fullnames;
    foreach my $pkg (@{$urpm->{depslist} || []}) {
	$file2fullnames{$pkg->filename}{$pkg->fullname} = undef;
    }

    #- examine the local repository, which is trusted (no gpg or pgp signature check but md5 is now done).
    my $dh = $urpm->opendir_safe("$urpm->{cachedir}/rpms");
    if ($dh) {
	while (defined(my $filename = readdir $dh)) {
	    my $filepath = "$urpm->{cachedir}/rpms/$filename";
	    if (-d $filepath) {
	    } elsif ($options{clean_all} || ! -s _) {
		unlink $filepath; #- this file should be removed or is already empty.
	    } else {
		if (keys(%{$file2fullnames{$filename} || {}}) > 1) {
		    $urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\"", $filename));
		} elsif (keys(%{$file2fullnames{$filename} || {}}) == 1) {
		    my ($fullname) = keys(%{$file2fullnames{$filename} || {}});
		    if (defined(my $id = delete $fullname2id{$fullname})) {
			$local_sources{$id} = $filepath;
		    } else {
			$options{clean_other} && ! exists $protected_files{$filepath} and unlink $filepath;
		    }
		} else {
		    $options{clean_other} && ! exists $protected_files{$filepath} and unlink $filepath;
		}
	    }
	}
	closedir $dh;
    }

    if ($options{clean_all}) {
	#- clean download directory, do it here even if this is not the best moment.
	clean_dir("$urpm->{cachedir}/partial");
    }

    my ($error, @list_error, @list, %examined);

    foreach my $medium (@{$urpm->{media} || []}) {
	my (%sources, %list_examined, $list_warning);

	if (is_valid_medium($medium) && !$medium->{ignore}) {
	    #- always prefer a list file if available.
	    if ($medium->{list}) {
		if (-r statedir_list($urpm, $medium)) {
		    foreach (cat_(statedir_list($urpm, $medium))) {
			chomp;
			if (my ($filename) = m!([^/]*\.rpm)$!) {
			    if (keys(%{$file2fullnames{$filename} || {}}) > 1) {
				$urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\"", $filename));
				next;
			    } elsif (keys(%{$file2fullnames{$filename} || {}}) == 1) {
				my ($fullname) = keys(%{$file2fullnames{$filename} || {}});
				if (defined(my $id = $fullname2id{$fullname})) {
				    if (!/\.delta\.rpm$/ || $urpm->is_delta_installable($urpm->{depslist}[$id], $options{root})) {
					$sources{$id} = "$medium->{url}/$filename";
				    }
				}
				$list_examined{$fullname} = $examined{$fullname} = undef;
			    }
			} else {
			    chomp;
			    $error = 1;
			    $urpm->{error}(N("unable to correctly parse [%s] on value \"%s\"", statedir_list($urpm, $medium), $_));
			    last;
			}
		    }
		} else {
		    # list file exists but isn't readable
		    # report error only if no result found, list files are only readable by root
		    push @list_error, N("unable to access list file of \"%s\", medium ignored", $medium->{name});
		    $< and push @list_error, "    " . N("(retry as root?)");
		    next;
		}
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
			    if (defined(my $id = $fullname2id{$fullname})) {
				if ($fi !~ /\.delta\.rpm$/ || $urpm->is_delta_installable($urpm->{depslist}[$id], $options{root})) {
				    $sources{$id} = "$medium->{url}/" . $fi;
				}
			    }
			    $examined{$fullname} = undef;
			}
		    }
		}
		$list_warning && $medium->{list} && -r statedir_list($urpm, $medium) && -f _
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
	$urpm->{error}($_) foreach @list_error;
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
    my $db = db_open_or_die($urpm, $root);
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

    $urpm->lock_urpmi_db('exclusive') if !$options{nolock};
    $urpm->copy_packages_of_removable_media($list, \%sources, $options{ask_for_medium}) or return;
    $urpm->download_packages_of_distant_media($list, \%sources, \%error_sources, %options);
    $urpm->unlock_urpmi_db unless $options{nolock};

    %sources, %error_sources;
}

#- lock policy concerning chroot :
#  - lock rpm db in chroot
#  - lock urpmi db in /
sub _lock {
    my ($urpm, $fh_ref, $file, $b_exclusive) = @_;
    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my ($LOCK_SH, $LOCK_EX, $LOCK_NB) = (1, 2, 4);
    if ($b_exclusive) {
	#- lock urpmi database, but keep lock to wait for an urpmi.update to finish.
    } else {
	#- create the .LOCK file if needed (and if possible)
	-e $file or open(my $_f, ">", $file);

	#- lock urpmi database, if the LOCK file doesn't exists no share lock.
    }
    my ($sense, $mode) = $b_exclusive ? ('>', $LOCK_EX) : ('<', $LOCK_SH);
    open $$fh_ref, $sense, $file or return;
    flock $$fh_ref, $mode|$LOCK_NB or $urpm->{fatal}(7, N("urpmi database locked"));
}

sub lock_rpm_db { 
    my ($urpm, $b_exclusive) = @_;
    _lock($urpm, \$RPMLOCK_FILE, "$urpm->{root}/$urpm->{statedir}/.RPMLOCK", $b_exclusive);
}
sub lock_urpmi_db {
    my ($urpm, $b_exclusive) = @_;
    _lock($urpm, \$LOCK_FILE, "$urpm->{statedir}/.LOCK", $b_exclusive);
}
#- deprecated
sub exlock_urpmi_db {
    my ($urpm) = @_;
    lock_urpmi_db($urpm, 'exclusive');
}

sub _unlock {
    my ($fh_ref) = @_;
    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my $LOCK_UN = 8;
    #- now everything is finished.
    #- release lock on database.
    flock $$fh_ref, $LOCK_UN;
    close $$fh_ref;
}
sub unlock_rpm_db {
    my ($_urpm) = @_;
    _unlock(\$RPMLOCK_FILE);
}
sub unlock_urpmi_db {
    my ($_urpm) = @_;
    _unlock(\$LOCK_FILE);
}

#- $list is a [ { pkg_id1 => url1, ... }, { ... }, ... ]
#- where there is one hash for each medium in {media}
sub copy_packages_of_removable_media {
    my ($urpm, $list, $sources, $o_ask_for_medium) = @_;
    my %removables;

    #- make sure everything is correct on input...
    $urpm->{media} or return;
    @{$urpm->{media}} == @$list or return;

    #- examine if given medium is already inside a removable device.
    my $check_notfound = sub {
	my ($id, $dir, $removable) = @_;
	if ($dir) {
	    $urpm->try_mounting($dir, $removable);
	    -e $dir or return 2;
	}
	foreach (values %{$list->[$id]}) {
	    chomp;
	    my $dir_ = file_from_local_url($_) or next;
	    $dir_ =~ m!/.*/! or next; #- is this really needed??
	    unless ($dir) {
		$dir = $dir_;
		$urpm->try_mounting($dir, $removable);
	    }
	    -r $dir_ or return 1;
	}
	0;
    };
    #- removable media have to be examined to keep mounted the one that has
    #- more packages than others.
    my $examine_removable_medium = sub {
	my ($id, $device) = @_;
	my $medium = $urpm->{media}[$id];
	if (my $dir = file_from_local_url($medium->{url})) {
	    #- the directory given does not exist and may be accessible
	    #- by mounting some other directory. Try to figure it out and mount
	    #- everything that might be necessary.
	    while ($check_notfound->($id, $dir, is_iso($medium->{removable}) ? $medium->{removable} : 'removable')) {
		is_iso($medium->{removable}) || $o_ask_for_medium
		    or $urpm->{fatal}(4, N("medium \"%s\" is not selected", $medium->{name}));
		$urpm->try_umounting($dir);
		system("/usr/bin/eject '$device' 2>/dev/null");
		is_iso($medium->{removable})
		    || $o_ask_for_medium->(remove_internal_name($medium->{name}), $medium->{removable})
		    or $urpm->{fatal}(4, N("medium \"%s\" is not selected", $medium->{name}));
	    }
	    if (-e $dir) {
		while (my ($i, $url) = each %{$list->[$id]}) {
		    chomp $url;
		    my ($filepath, $filename) = do {
			my $f = file_from_local_url($url) or next;
			$f =~ m!/.*/! or next; #- is this really needed??
			dirname($f), basename($f);
		    };
		    if (-r $filepath) {
			#- we should assume a possibly buggy removable device...
			#- First, copy in partial cache, and if the package is still good,
			#- transfer it to the rpms cache.
			unlink "$urpm->{cachedir}/partial/$filename";
			if (copy_and_own($filepath, "$urpm->{cachedir}/partial/$filename") &&
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
	} elsif (my $dir = file_from_local_url($medium->{url})) {
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
	    my @sorted_media = sort { values(%{$list->[$a]}) <=> values(%{$list->[$b]}) } @{$removables{$device}};

	    #- check if a removable device is already mounted (and files present).
	    if (my ($already_mounted_medium) = grep { !$check_notfound->($_) } @sorted_media) {
		@sorted_media = grep { $_ ne $already_mounted_medium } @sorted_media;
		unshift @sorted_media, $already_mounted_medium;
	    }

	    #- mount all except the biggest one.
	    my $biggest = pop @sorted_media;
	    foreach (@sorted_media) {
		$examine_removable_medium->($_, $device);
	    }
	    #- now mount the last one...
	    $removables{$device} = [ $biggest ];
	}

	$examine_removable_medium->($removables{$device}[0], $device);
    }

    1;
}

# TODO verify that files are downloaded from the right corresponding media
#- options: quiet, callback, 
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
	    my $local_file = file_from_local_url($url);
	    if ($local_file && $local_file =~ /\.rpm$/) {
		if (-r $local_file) {
		    $sources->{$i} = $local_file;
		} else {
		    $error_sources->{$i} = $local_file;
		}
	    } elsif ($url =~ m!^([^:]*):/(.*/([^/]*\.rpm))\Z!) {
		$distant_sources{$i} = "$1:/$2"; #- will download now
	    } else {
		$urpm->{error}(N("malformed URL: [%s]", $url));
	    }
	}

	#- download files from the current medium.
	if (%distant_sources) {
	    $urpm->{log}(N("retrieving rpm files from medium \"%s\"...", $urpm->{media}[$n]{name}));
	    if (sync_webfetch($urpm, $urpm->{media}[$n], [ values %distant_sources ],
			      quiet => $options{quiet}, resume => $urpm->{options}{resume}, callback => $options{callback})) {
		$urpm->{log}(N("...retrieving done"));
	    } else {
		$urpm->{error}(N("...retrieving failed: %s", $@));
	    }
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
    my ($_urpm, $set, $list, $sources, $transaction_list, $transaction_sources) = @_;

    foreach my $id (@{$set->{upgrade}}) {
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

# size of the installation progress bar
my $progress_size = 45;
eval {
    require Term::ReadKey;
    ($progress_size) = Term::ReadKey::GetTerminalSize();
    $progress_size -= 35;
    $progress_size < 5 and $progress_size = 5;
};

# install logger callback
sub install_logger {
    my ($urpm, $type, $id, $subtype, $amount, $total) = @_;
    my $pkg = defined $id && $urpm->{depslist}[$id];
    my $total_pkg = $urpm->{nb_install};
    local $| = 1;

    if ($subtype eq 'start') {
	$urpm->{logger_progress} = 0;
	if ($type eq 'trans') {
	    $urpm->{logger_id} ||= 0;
	    $urpm->{logger_count} ||= 0;
	    my $p = N("Preparing...");
	    print $p, " " x (33 - length $p);
	} else {
	    ++$urpm->{logger_id};
	    my $pname = $pkg ? $pkg->name : '';
	    ++$urpm->{logger_count} if $pname;
	    my $cnt = $pname ? $urpm->{logger_count} : '-';
	    $pname ||= N("[repackaging]");
	    printf "%9s: %-22s", $cnt . "/" . $total_pkg, $pname;
	}
    } elsif ($subtype eq 'stop') {
	if ($urpm->{logger_progress} < $progress_size) {
	    print '#' x ($progress_size - $urpm->{logger_progress}), "\n";
	    $urpm->{logger_progress} = 0;
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
#- options: 
#-      test, excludepath, nodeps, noorder (unused), delta, 
#-      callback_open, callback_close, callback_inst, callback_trans, post_clean_cache
#-   (more options for trans->run)
#-      excludedocs, nosize, noscripts, oldpackage, repackage, ignorearch
sub install {
    my ($urpm, $remove, $install, $upgrade, %options) = @_;
    my %readmes;
    $options{translate_message} = 1;

    my $db = db_open_or_die($urpm, $urpm->{root}, !$options{test}); #- open in read/write mode unless testing installation.

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
	    my ($_data, $_type, $id) = @_;
	    $fh = $urpm->open_safe('<', $install->{$id} || $upgrade->{$id});
	    $fh ? fileno $fh : undef;
	};
	$options{callback_close} ||= sub {
	    my ($urpm, undef, $pkgid) = @_;
	    return unless defined $pkgid;
	    my $pkg = $urpm->{depslist}[$pkgid];
	    my $fullname = $pkg->fullname;
	    my $trtype = (grep { /\Q$fullname\E/ } values %$install) ? 'install' : '(upgrade|update)';
	    foreach ($pkg->files) { /\bREADME(\.$trtype)?\.urpmi$/ and $readmes{$_} = $fullname }
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

    if ($::verbose >= 0) {
	foreach (keys %readmes) {
	    print "-" x 70, "\n", N("More information on package %s", $readmes{$_}), "\n";
	    print cat_($_);
	    print "-" x 70, "\n";
	}
    }
    @l;
}

#- install all files to node as remembered according to resolving done.
sub parallel_install {
    my @para = @_;
    my ($urpm, $_remove, $_install, $_upgrade, %_options) = @para;
    $urpm->{parallel_handler}->parallel_install(@para);
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
	my $db = db_open_or_die($urpm, $options{root});
	my (@m, @notfound);

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
			    my ($name, $version, $release) = $p->fullname;
			    "$name-$version-$release" eq $_ or return;
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
			    my ($name, $version) = $p->fullname;
			    "$name-$version" eq $_ or return;
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
		$options{callback_notfound} && $options{callback_notfound}->($urpm, @notfound)
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
		    $options{callback_fuzzy} && $options{callback_fuzzy}->($urpm, @$l > 1 ? $match : $l->[0], @m)
		      or return ();
		} else {
		    $options{callback_notfound} && $options{callback_notfound}->($urpm, @notfound)
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
    my ($urpm, $state, @fullnames) = @_;

    join("\n", map { translate_why_unselected_one($urpm, $state, $_) } sort @fullnames);
}

sub translate_why_unselected_one {
    my ($urpm, $state, $fullname) = @_;

    my $rb = $state->{rejected}{$fullname}{backtrack};
    my @froms = keys %{$rb->{closure} || {}};
    my @unsatisfied = @{$rb->{unsatisfied} || []};
    my $s = join ", ", (
	(map { N("due to missing %s", $_) } @froms),
	(map { N("due to unsatisfied %s", $_) } uniq(map {
	    #- XXX in theory we shouldn't need this, dependencies (and not ids) should
	    #- already be present in @unsatisfied. But with biarch packages this is
	    #- not always the case.
	    /\D/ ? $_ : scalar($urpm->{depslist}[$_]->fullname);
	} @unsatisfied)),
	$rb->{promote} && !$rb->{keep} ? N("trying to promote %s", join(", ", @{$rb->{promote}})) : (),
	$rb->{keep} ? N("in order to keep %s", join(", ", @{$rb->{keep}})) : (),
    );
    $fullname . ($s ? " ($s)" : '');
}

sub removed_packages {
    my (undef, $state) = @_;
    grep {
	$state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted};
    } keys %{$state->{rejected} || {}};
}

sub translate_why_removed {
    my ($urpm, $state, @fullnames) = @_;
    join("\n", map { translate_why_removed_one($urpm, $state, $_) } sort @fullnames);
}
sub translate_why_removed_one {
    my ($urpm, $state, $fullname) = @_;

    my $closure = $state->{rejected}{$fullname}{closure};
    my ($from) = keys %$closure;
    my ($whyk) = keys %{$closure->{$from}};
    my $whyv = $closure->{$from}{$whyk};
    my $frompkg = $urpm->search($from, strict_fullname => 1);
    my $s = do {
	if ($whyk =~ /old_requested/) {
	    N("in order to install %s", $frompkg ? scalar $frompkg->fullname : $from);
	} elsif ($whyk =~ /unsatisfied/) {
	    join(",\n  ", map {
		if (/([^\[\s]*)(?:\[\*\])?(?:\[|\s+)([^\]]*)\]?$/ && $2 ne '*') {
		    N("due to unsatisfied %s", "$1 $2");
		} else {
		    N("due to missing %s", $_);
		}
	    } @$whyv);
	} elsif ($whyk =~ /conflicts/) {
	    N("due to conflicts with %s", $whyv);
	} elsif ($whyk =~ /unrequested/) {
	    N("unrequested");
	} else {
	    undef;
	}
    };
    #- now insert the reason if available.
    $fullname . ($s ? "\n ($s)" : '');
}

#- options: callback, basename
sub check_sources_signatures {
    my ($urpm, $sources_install, $sources, %options) = @_;
    sort(_check_sources_signatures($urpm, $sources_install, %options),
	 _check_sources_signatures($urpm, $sources, %options));
}
sub _check_sources_signatures {
    my ($urpm, $sources, %options) = @_;
    my ($medium, %invalid_sources);

    foreach my $id (keys %$sources) {
	my $filepath = $sources->{$id};
	my $verif = URPM::verify_signature($filepath);

	if ($verif =~ /NOT OK/) {
	    $verif =~ s/\n//g;
	    $invalid_sources{$filepath} = N("Invalid signature (%s)", $verif);
	} else {
	    unless ($medium && is_valid_medium($medium) &&
		    $medium->{start} <= $id && $id <= $medium->{end})
	    {
		$medium = undef;
		foreach (@{$urpm->{media}}) {
		    is_valid_medium($_) && $_->{start} <= $id && $id <= $_->{end}
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
		$urpm, $filepath,
		id => $id,
		verif => $verif,
		why => $invalid_sources{$filepath},
	    );
	}
    }
    map { ($options{basename} ? basename($_) : $_) . ": $invalid_sources{$_}" }
      keys %invalid_sources;
}

#- get reason of update for packages to be updated
#- use all update medias if none given
sub get_updates_description {
    my ($urpm, @update_medias) = @_;
    my %update_descr;
    my ($cur, $section);

    @update_medias or @update_medias = grep { !$_->{ignore} && $_->{update} } @{$urpm->{media}};

    foreach (map { cat_(statedir_descriptions($urpm, $_)), '%package dummy' } @update_medias) {
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
sub get_md5sum {
    my ($md5sum_file, $f) = @_;  
    my $basename = basename($f);

    my ($retrieved_md5sum) = map {
	my ($md5sum, $file) = m|(\S+)\s+(?:\./)?(\S+)|;
	$file && $file eq $basename ? $md5sum : @{[]};
    } cat_($md5sum_file);

    $retrieved_md5sum;
}

sub parse_md5sum {
    my ($urpm, $md5sum_file, $basename) = @_;
    $urpm->{log}(N("examining MD5SUM file"));
    my $retrieved_md5sum = get_md5sum($md5sum_file, $basename) 
      or $urpm->{log}(N("warning: md5sum for %s unavailable in MD5SUM file", $basename));
    return $retrieved_md5sum;
}

sub local_md5sum {
    my ($urpm, $medium, $force) = @_;
    if ($force) {
	#- force downloading the file again, else why a force option has been defined ?
	delete $medium->{md5sum};
    } else {
	$medium->{md5sum} ||= compute_local_md5sum($urpm, $medium);
    }
    $medium->{md5sum};
}

sub compute_local_md5sum {
    my ($urpm, $medium) = @_;

    $urpm->{log}(N("computing md5sum of existing source hdlist (or synthesis)"));
    my $f = statedir_hdlist_or_synthesis($urpm, $medium);
    -e $f && md5sum($f);
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

# ex: set ts=8 sts=4 sw=4 noet:
