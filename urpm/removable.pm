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

#- side-effects:
#-   + those of try_mounting_ ($urpm->{removable_mounted}, "mount")
#-   + those of try_mounting_iso ($urpm->{removable_mounted}, "mount")
sub try_mounting {
    my ($urpm, $dir, $o_iso) = @_;

    $o_iso ? try_mounting_iso($urpm, $dir, $o_iso) : try_mounting_($urpm, $dir);
}

#- side-effects: $urpm->{removable_mounted}, "mount"
sub try_mounting_iso {
    my ($urpm, $dir, $iso) = @_;

    #- note: for isos, we don't parse the fstab because it might not be declared in it.
    #- so we try to remove suffixes from the dir name until the dir exists
    my $mntpoint = urpm::sys::trim_until_d($dir);

    if ($mntpoint) {
	$urpm->{log}(N("mounting %s", $mntpoint));

	#- to mount an iso image, grab the first loop device
	my $loopdev = urpm::sys::first_free_loopdev();
	sys_log("mount iso $mntpoint on $iso");
	$loopdev and system('mount', $iso, $mntpoint, '-t', 'iso9660', '-o', "loop=$loopdev");
	$iso and $urpm->{removable_mounted}{$mntpoint} = undef;
    }
    -e $mntpoint;
}

#- side-effects: $urpm->{removable_mounted}, "mount"
sub try_mounting_ {
    my ($urpm, $dir) = @_;

    my $mntpoint = _non_mounted_mntpoint($dir);

    if ($mntpoint) {
	$urpm->{log}(N("mounting %s", $mntpoint));
	sys_log("mount $mntpoint");
	system("mount '$mntpoint' 2>/dev/null");
    }
    -e $dir;
}

#- side-effects: $urpm->{removable_mounted}, "umount"
sub try_umounting {
    my ($urpm, $dir) = @_;

    if (my $mntpoint = _mounted_mntpoint($dir)) {
	$urpm->{log}(N("unmounting %s", $mntpoint));
	sys_log("umount $mntpoint");
	system("umount '$mntpoint' 2>/dev/null");
	delete $urpm->{removable_mounted}{$mntpoint};
    }
    ! -e $dir;
}

#- side-effects: none
sub _mounted_mntpoint {
    my ($dir) = @_;
    $dir = reduce_pathname($dir);
    my $entry = urpm::sys::find_a_mntpoint($dir);
    $entry->{mounted} && $entry->{mntpoint};
}
#- side-effects: none
sub _non_mounted_mntpoint {
    my ($dir) = @_;
    $dir = reduce_pathname($dir);
    my $entry = urpm::sys::find_a_mntpoint($dir);
    !$entry->{mounted} && $entry->{mntpoint};
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

#- side-effects:
#-   + those of try_mounting_ ($urpm->{removable_mounted}, "mount")
sub _mount_and_check_notfound {
    my ($urpm, $medium_list, $dir) = @_;

    try_mounting_($urpm, $dir);
    -e $dir or return 2;

    _check_notfound($medium_list);
}

#- side-effects: none
sub _check_notfound {
    my ($medium_list) = @_;

    foreach (values %$medium_list) {
	my $dir_ = _filepath($_) or next;
	-r $dir_ or return 1;
    }
    0;
}

#- removable media have to be examined to keep mounted the one that has
#- more packages than others.
#-
#- side-effects:
#-   + those of _examine_removable_medium_ ($urpm->{removable_mounted}, $sources, "mount", "umount", "eject", "copy-move-files")
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

#- side-effects: "eject"
#-   + those of _mount_and_check_notfound ($urpm->{removable_mounted}, "mount")
#-   + those of try_umounting ($urpm->{removable_mounted}, "umount")
sub _mount_it {
    my ($urpm, $medium, $medium_list, $o_ask_for_medium) = @_;

    my $dir = file_from_local_url($medium->{url});

    #- the directory given does not exist and may be accessible
    #- by mounting some other directory. Try to figure it out and mount
    #- everything that might be necessary.
    while (_mount_and_check_notfound($urpm, $medium_list, $dir)) {
	    $o_ask_for_medium 
	      or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));

	    try_umounting($urpm, $dir);
	    system("/usr/bin/eject '$medium->{removable}' 2>/dev/null");

	    $o_ask_for_medium->(remove_internal_name($medium->{name}), $medium->{removable})
	      or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));
    }

    $dir;
}

#- side-effects: none
sub _filepath {
    my ($url) = @_;

    chomp $url;
    my $filepath = file_from_local_url($url) or return;
    $filepath =~ m!/.*/! or return; #- is this really needed??
    $filepath;
}

#- side-effects: "copy-move-files"
sub _do_the_copy {
    my ($urpm, $filepath) = @_;

    -r $filepath or return;

    #- we should assume a possibly buggy removable device...
    #- First, copy in partial cache, and if the package is still good,
    #- transfer it to the rpms cache.
    my $filename = basename($filepath);
    unlink "$urpm->{cachedir}/partial/$filename";
    $urpm->{log}("copying $filepath");
    copy_and_own($filepath, "$urpm->{cachedir}/partial/$filename") or return;
    my $f = urpm::get_pkgs::verify_partial_rpm_and_move($urpm, $urpm->{cachedir}, $filename) or return;
    $f;
}

#- side-effects: $sources
#-   + those of _mount_it ($urpm->{removable_mounted}, "mount", "umount", "eject")
#-   + those of _do_the_copy: "copy-move-files"
sub _examine_removable_medium_ {
    my ($urpm, $medium, $medium_list, $sources, $o_ask_for_medium) = @_;

    my $dir = _mount_it($urpm, $medium, $medium_list, $o_ask_for_medium);

	while (my ($i, $url) = each %$medium_list) {
	    my $filepath = _filepath($url) or next;

	    if (my $rpm = _do_the_copy($urpm, $filepath)) {
		$sources->{$i} = $rpm;
	    } else {
		#- fallback to use other method for retrieving the file later.
		$urpm->{error}(N("unable to read rpm file [%s] from medium \"%s\"", $filepath, $medium->{name}));
	    }
	}
}

#- side-effects:
#-   + those of try_mounting_non_cdrom ($urpm->{removable_mounted}, "mount")
sub try_mounting_non_cdroms {
    my ($urpm, $list) = @_;

    my @used_media = map { $_->{medium} } _create_blists($urpm->{media}, $list);

    foreach my $medium (grep { !$_->{removable} } @used_media) {
	try_mounting_non_cdrom($urpm, $medium);
    }
}

#- side-effects:
#-   + those of try_mounting_ ($urpm->{removable_mounted}, "mount")
sub try_mounting_non_cdrom {
    my ($urpm, $medium) = @_;

    my $dir = file_from_local_url($medium->{url}) or return;

    -e $dir || try_mounting($urpm, $dir, $medium->{iso}) or
      $urpm->{error}(N("unable to access medium \"%s\"", $medium->{name})), return;

    1;
}

#- side-effects: none
sub _get_cdroms {
    my ($blists) = @_;

    my %removables;

    foreach (@$blists) {
	#- examine non removable device but that may be mounted.
	if (my $device = $_->{medium}{removable}) {
	    next if $device =~ m![^a-zA-Z0-9_./-]!; #- bad path
	    push @{$removables{$device} ||= []}, $_;
	}
    }
    values %removables;
}

#- side-effects: none
sub _create_blists {
    my ($media, $list) = @_;

    #- make sure everything is correct on input...
    $media or return;
    @$media == @$list or return;

    my $i;
    [ grep { %{$_->{list}} } 
	map { { medium => $_, list => $list->[$i++] } } @$media ];
}

#- side-effects: none
sub _sort_media {
    my (@l) = @_;

    if (@l > 1) {
	@l = sort { values(%{$a->{list}}) <=> values(%{$b->{list}}) } @l;

	#- check if a removable device is already mounted (and files present).
	if (my ($already_mounted) = grep { !_check_notfound($_->{list}) } @l) {
	    @l = ($already_mounted, grep { $_ != $already_mounted } @l);
	}
    }
    @l;
}

#- $list is a [ { pkg_id1 => url1, ... }, { ... }, ... ]
#- where there is one hash for each medium in {media}
#-
#- side-effects:
#-   + those of _examine_removable_medium ($urpm->{removable_mounted}, $sources, "mount", "umount", "eject", "copy-move-files")
sub copy_packages_of_removable_media {
    my ($urpm, $list, $sources, $o_ask_for_medium) = @_;

    my $blists = _create_blists($urpm->{media}, $list);

    foreach my $l (_get_cdroms($blists)) {

	#- Here we have only removable devices.
	#- If more than one media uses this device, we have to sort
	#- needed packages to copy the needed rpm files.
	foreach my $blist (_sort_media(@$l)) {
	    _examine_removable_medium($urpm, $blist, $sources, $o_ask_for_medium);
	}
    }

    1;
}

1;
