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
use urpm::md5sum;
use MDV::Distribconf;

our $VERSION = '4.8.29';
our @ISA = qw(URPM Exporter);
our @EXPORT_OK = 'file_from_local_url';

use URPM;
use URPM::Resolve;

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

sub db_open_or_die {
    my ($urpm, $root, $b_force) = @_;

    my $db = URPM::DB::open($root, $b_force)
      or $urpm->{fatal}(9, N("unable to open rpmdb"));

    $db;
}

sub remove_obsolete_headers_in_cache {
    my ($urpm) = @_;
    my %headers;
    if (my $dh = urpm::sys::opendir_safe($urpm, "$urpm->{cachedir}/headers")) {
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
	    if (urpm::download::sync($urpm, undef, [$_], quiet => 1)) {
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
	urpm::parallel::resolve_dependencies($urpm, $state, $requested, %options);
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
    my $dh = urpm::sys::opendir_safe($urpm, "$urpm->{cachedir}/rpms");
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
	urpm::sys::clean_dir("$urpm->{cachedir}/partial");
    }

    my ($error, @list_error, @list, %examined);

    foreach my $medium (@{$urpm->{media} || []}) {
	my (%sources, %list_examined, $list_warning);

	if (urpm::media::is_valid_medium($medium) && !$medium->{ignore}) {
	    #- always prefer a list file if available.
	    if ($medium->{list}) {
		if (-r urpm::media::statedir_list($urpm, $medium)) {
		    foreach (cat_(urpm::media::statedir_list($urpm, $medium))) {
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
			    $urpm->{error}(N("unable to correctly parse [%s] on value \"%s\"", urpm::media::statedir_list($urpm, $medium), $_));
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
		$list_warning && $medium->{list} && -r urpm::media::statedir_list($urpm, $medium) && -f _
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

    urpm::sys::lock_urpmi_db($urpm, 'exclusive') if !$options{nolock};
    $urpm->copy_packages_of_removable_media($list, \%sources, $options{ask_for_medium}) or return;
    $urpm->download_packages_of_distant_media($list, \%sources, \%error_sources, %options);
    urpm::sys::unlock_urpmi_db($urpm) unless $options{nolock};

    %sources, %error_sources;
}

#- deprecated
sub exlock_urpmi_db {
    my ($urpm) = @_;
    urpm::sys::lock_urpmi_db($urpm, 'exclusive');
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
	    if (urpm::download::sync($urpm, $urpm->{media}[$n], [ values %distant_sources ],
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

#- deprecated
sub install { require urpm::install; &urpm::install::install }

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

#- deprecated
sub parallel_remove { &urpm::parallel::remove }

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
	    unless ($medium && urpm::media::is_valid_medium($medium) &&
		    $medium->{start} <= $id && $id <= $medium->{end})
	    {
		$medium = undef;
		foreach (@{$urpm->{media}}) {
		    urpm::media::is_valid_medium($_) && $_->{start} <= $id && $id <= $_->{end}
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

    foreach (map { cat_(urpm::media::statedir_descriptions($urpm, $_)), '%package dummy' } @update_medias) {
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
