package urpm::removable;

# $Id$

use urpm::msg;
use urpm::sys;
use urpm::util;
use urpm::get_pkgs;
use urpm 'file_from_local_url';



#- returns the removable device name if it corresponds to an iso image, '' otherwise
#-
#- side-effects: none
sub is_iso {
    my ($removable_dev) = @_;
    $removable_dev && $removable_dev =~ /\.iso$/i;
}

#- side-effects: $urpm->{removable_mounted}, mount
sub try_mounting {
    my ($urpm, $dir, $o_removable) = @_;
    my %infos;

    my $is_iso = is_iso($o_removable);
    my @mntpoints = $is_iso
	#- note: for isos, we don't parse the fstab because it might not be declared in it.
	#- so we try to remove suffixes from the dir name until the dir exists
	? ($dir = urpm::sys::trim_until_d($dir))
	: urpm::sys::find_mntpoints($dir = reduce_pathname($dir), \%infos);

    foreach (grep { ! $infos{$_}{mounted} } @mntpoints) {
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
	$o_removable and $urpm->{removable_mounted}{$_} = undef;
    }
    -e $dir;
}

#- side-effects: $urpm->{removable_mounted}, umount
sub try_umounting {
    my ($urpm, $dir) = @_;

    $dir = reduce_pathname($dir);
    foreach (reverse _mounted_mntpoints($dir)) {
	$urpm->{log}(N("unmounting %s", $_));
	sys_log("umount $_");
	system("umount '$_' 2>/dev/null");
	delete $urpm->{removable_mounted}{$_};
    }
    ! -e $dir;
}

#- side-effects: none
sub _mounted_mntpoints {
    my ($dir) = @_;
    my %infos;
    grep { $infos{$_}{mounted} } urpm::sys::find_mntpoints($dir, \%infos);
}

#- side-effects: $urpm->{removable_mounted}
#-   + those of try_umounting ($urpm->{removable_mounted}, umount)
sub try_umounting_removables {
    my ($urpm) = @_;
    foreach (keys %{$urpm->{removable_mounted}}) {
	try_umounting($urpm, $_);
    }
    delete $urpm->{removable_mounted};
}

#- examine if given medium is already inside a removable device.
#-
#- side-effects:
#-   + those of try_mounting ($urpm->{removable_mounted}, mount)
sub _check_notfound {
    my ($urpm, $medium_list, $dir, $removable) = @_;
	if ($dir) {
	    try_mounting($urpm, $dir, $removable);
	    -e $dir or return 2;
	}
	foreach (values %$medium_list) {
	    my $dir_ = _filepath($_) or next;
	    if (!$dir) {
		$dir = $dir_;
		try_mounting($urpm, $dir, $removable);
	    }
	    -r $dir_ or return 1;
	}
	0;
}

#- removable media have to be examined to keep mounted the one that has
#- more packages than others.
sub _examine_removable_medium {
    my ($urpm, $blist, $sources, $o_ask_for_medium) = @_;

    my $medium = $blist->{medium};

    if (file_from_local_url($medium->{url})) {
	_examine_removable_medium_($urpm, $medium, $blist->{list}, $sources, $o_ask_for_medium);
    } else {
	#- we have a removable device that is not removable, well...
	$urpm->{error}(N("inconsistent medium \"%s\" marked removable but not really", $medium->{name}));
    }
}

sub _mount_it {
    my ($urpm, $medium, $medium_list, $o_ask_for_medium) = @_;

    my $device = $medium->{removable};
    my $dir = file_from_local_url($medium->{url});

	    #- the directory given does not exist and may be accessible
	    #- by mounting some other directory. Try to figure it out and mount
	    #- everything that might be necessary.
	    while (_check_notfound($urpm, $medium_list, $dir, is_iso($medium->{removable}) ? $medium->{removable} : 'removable')) {
		is_iso($medium->{removable}) || $o_ask_for_medium
		    or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));
		try_umounting($urpm, $dir);
		system("/usr/bin/eject '$device' 2>/dev/null");
		is_iso($medium->{removable})
		    || $o_ask_for_medium->(remove_internal_name($medium->{name}), $medium->{removable})
		    or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));
	    }
}

sub _filepath {
    my ($url) = @_;

    chomp $url;
    my $filepath = file_from_local_url($url) or return;
    $filepath =~ m!/.*/! or return; #- is this really needed??
    $filepath;
}

sub _examine_removable_medium_ {
    my ($urpm, $medium, $medium_list, $sources, $o_ask_for_medium) = @_;

    _mount_it($urpm, $medium, $medium_list, $o_ask_for_medium);

    my $dir = file_from_local_url($medium->{url});

	    if (-e $dir) {
		while (my ($i, $url) = each %$medium_list) {
		    my $filepath = _filepath($url) or next;

		    if (-r $filepath) {
			#- we should assume a possibly buggy removable device...
			#- First, copy in partial cache, and if the package is still good,
			#- transfer it to the rpms cache.
			my $filename = basename($filepath);
			unlink "$urpm->{cachedir}/partial/$filename";
			$urpm->{log}("copying $filepath");
			if (copy_and_own($filepath, "$urpm->{cachedir}/partial/$filename") &&
			    urpm::get_pkgs::verify_partial_rpm_and_move($urpm, $urpm->{cachedir}, $filename))
			{
			    $sources->{$i} = "$urpm->{cachedir}/rpms/$filename";
			}
		    }
		    if (!$sources->{$i}) {
			#- fallback to use other method for retrieving the file later.
			$urpm->{error}(N("unable to read rpm file [%s] from medium \"%s\"", $filepath, $medium->{name}));
		    }
		}
	    } else {
		$urpm->{error}(N("medium \"%s\" is not available", $medium->{name}));
	    }
}

sub _get_removables_or_check_mounted {
    my ($urpm, $blists) = @_;

    my %removables;

    foreach (@$blists) {
	my $medium = $_->{medium};
	#- examine non removable device but that may be mounted.
	if (my $device = $medium->{removable}) {
	    next if $device =~ m![^a-zA-Z0-9_./-]!; #- bad path
	    push @{$removables{$device} ||= []}, $_;
	} elsif (my $dir = file_from_local_url($medium->{url})) {
	    -e $dir || try_mounting($urpm, $dir) or
	      $urpm->{error}(N("unable to access medium \"%s\"", $medium->{name})), next;
	}
    }
    values %removables;
}

sub _create_blists {
    my ($media, $list) = @_;

    #- make sure everything is correct on input...
    $media or return;
    @$media == @$list or return;

    my $i;
    [ grep { %{$_->{list}} } 
	map { { medium => $_, list => $list->[$i++] } } @$media ];
}

#- $list is a [ { pkg_id1 => url1, ... }, { ... }, ... ]
#- where there is one hash for each medium in {media}
sub copy_packages_of_removable_media {
    my ($urpm, $list, $sources, $o_ask_for_medium) = @_;

    my $blists = _create_blists($urpm->{media}, $list);

    my @removables = _get_removables_or_check_mounted($urpm, $blists);

    foreach my $l (@removables) {
	#- Here we have only removable devices.
	#- If more than one media uses this device, we have to sort
	#- needed packages to copy the needed rpm files.
	my @l = @$l;

	if (@l > 1) {
	    @l = sort { values(%{$a->{list}}) <=> values(%{$b->{list}}) } @l;

	    #- check if a removable device is already mounted (and files present).
	    if (my ($already_mounted) = grep { !_check_notfound($urpm, $_->{list}) } @l) {
		@l = ($already_mounted, grep { $_ != $already_mounted } @l);
	    }
	}
	foreach my $blist (@l) {
	    _examine_removable_medium($urpm, $blist, $sources, $o_ask_for_medium);
	}
    }

    1;
}

1;
