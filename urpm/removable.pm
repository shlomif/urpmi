package urpm::removable;

# $Id$

use urpm::msg;
use urpm::sys;
use urpm::util;
use urpm::get_pkgs;
use urpm 'file_from_local_medium', 'is_local_medium';



#- returns the removable device name if it corresponds to an iso image, '' otherwise
#-
#- side-effects: none
sub is_iso {
    my ($removable_dev) = @_;
    $removable_dev && $removable_dev =~ /\.iso$/i;
}

sub _file_or_synthesis_dir {
    my ($medium, $o_url) = @_;
    
    urpm::media::_valid_synthesis_dir($medium) && !$o_url ? 
	urpm::media::_synthesis_dir($medium) : 
	file_from_local_medium($medium, $o_url);
}

#- side-effects: $medium->{mntpoint}
sub look_for_mounted_cdrom {
    my ($urpm, $medium, $o_url) = @_;

    my @mntpoints = map { $_->{mntpoint} } 
                    grep { $_->{fs} eq 'iso9660' || $_->{fs} eq 'udf' } urpm::sys::read_mtab();
    foreach (@mntpoints) {
	# set it, then verify
	$medium->{mntpoint} = $_;
	if (-r _file_or_synthesis_dir($medium, $o_url)) {
	    $urpm->{log}("using cdrom mounted in $_");
	    return 1;
	}
    }
    0;
}    

#- side-effects:
#-   + those of _try_mounting_medium ($medium->{mntpoint})
sub try_mounting_medium {
    my ($urpm, $medium, $o_url) = @_;

    my $rc = _try_mounting_medium($urpm, $medium, $o_url);
    $rc or $urpm->{error}(N("unable to access medium \"%s\".", $medium->{name}));
    $rc;
}

#- side-effects:
#-   + those of look_for_mounted_cdrom ($medium->{mntpoint})
sub _try_mounting_medium {
    my ($urpm, $medium, $o_url) = @_;

    if (urpm::is_cdrom_url($medium->{url})) {
	look_for_mounted_cdrom($urpm, $medium, $o_url);
    } else {
	-r _file_or_synthesis_dir($medium, $o_url);
    }
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
#-   + those of try_mounting_medium ($medium->{mntpoint})
sub _mount_and_check_notfound {
    my ($urpm, $blist, $medium) = @_;

    my ($first_url) = values %{$blist->{list}};
    try_mounting_medium($urpm, $medium, $first_url) or return 1;

    _check_notfound($blist);
}

#- side-effects: none
sub _check_notfound {
    my ($blist) = @_;

    foreach (values %{$blist->{list}}) {
	my $dir_ = _filepath($blist->{medium}, $_) or next;
	-r $dir_ or return 1;
    }
    0;
}

#- side-effects: "eject"
#-   + those of _mount_and_check_notfound ($urpm->{removable_mounted}, "mount")
#-   + those of try_umounting ($urpm->{removable_mounted}, "umount")
sub _mount_it {
    my ($urpm, $blist, $o_ask_for_medium) = @_;
    my $medium = $blist->{medium};

    #- the directory given does not exist and may be accessible
    #- by mounting some other directory. Try to figure it out and mount
    #- everything that might be necessary.
    while (_mount_and_check_notfound($urpm, $blist, $medium)) {
	    $o_ask_for_medium 
	      or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));

	    my $dir; # TODO
	    try_umounting($urpm, $dir);
	    system("/usr/bin/eject '$medium->{removable}' 2>/dev/null");

	    $o_ask_for_medium->(remove_internal_name($medium->{name}), $medium->{removable})
	      or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));
    }
}

#- side-effects: none
sub _filepath {
    my ($medium, $url) = @_;

    chomp $url;
    my $filepath = file_from_local_medium($medium, $url) or return;
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
sub _copy_from_cdrom {
    my ($urpm, $blist, $sources, $o_ask_for_medium) = @_;

    _mount_it($urpm, $blist, $o_ask_for_medium);

	while (my ($i, $url) = each %{$blist->{list}}) {
	    my $filepath = _filepath($blist->{medium}, $url) or next;

	    if (my $rpm = _do_the_copy($urpm, $filepath)) {
		$sources->{$i} = $rpm;
	    } else {
		#- fallback to use other method for retrieving the file later.
		$urpm->{error}(N("unable to read rpm file [%s] from medium \"%s\"", $filepath, $blist->{medium}{name}));
	    }
	}
}

#- side-effects:
#-   + those of try_mounting_non_cdrom ($urpm->{removable_mounted}, "mount")
sub try_mounting_non_cdroms {
    my ($urpm, $list) = @_;

    my $blist = _create_blists($urpm->{media}, $list);
    my @used_media = map { $_->{medium} } @$blist;

    foreach my $medium (grep { !urpm::is_cdrom_url($_->{url}) } @used_media) {
	try_mounting_non_cdrom($urpm, $medium);
    }
}

#- side-effects:
#-   + those of try_mounting_ ($urpm->{removable_mounted}, "mount")
sub try_mounting_non_cdrom {
    my ($urpm, $medium) = @_;

    my $dir = file_from_local_medium($medium) or return;

    -e $dir || try_mounting($urpm, $dir, $medium->{iso}) or
      $urpm->{error}(N("unable to access medium \"%s\"", $medium->{name})), return;

    1;
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
	if (my ($already_mounted) = grep { !_check_notfound($_) } @l) {
	    @l = ($already_mounted, grep { $_ != $already_mounted } @l);
	}
    }
    @l;
}

#- $list is a [ { pkg_id1 => url1, ... }, { ... }, ... ]
#- where there is one hash for each medium in {media}
#-
#- side-effects:
#-   + those of _copy_from_cdrom ($urpm->{removable_mounted}, $sources, "mount", "umount", "eject", "copy-move-files")
sub copy_packages_of_removable_media {
    my ($urpm, $list, $sources, $o_ask_for_medium) = @_;

    my $blists = _create_blists($urpm->{media}, $list);
    #- If more than one media uses this device, we have to sort
    #- needed packages to copy the needed rpm files.
    my @l = _sort_media(grep { urpm::is_cdrom_url($_->{medium}{url}) } @$blists);

    foreach my $blist (@l) {
	_copy_from_cdrom($urpm, $blist, $sources, $o_ask_for_medium);
    }

    1;
}

1;
