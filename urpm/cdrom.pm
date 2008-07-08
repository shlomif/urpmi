package urpm::cdrom;

# $Id$

use urpm::msg;
use urpm::sys;
use urpm::util;
use urpm::get_pkgs;
use urpm::removable;
use urpm 'file_from_local_medium';



#- side-effects: $blists_url->[_]{medium}{mntpoint}
sub _find_blist_url_matching {
    my ($urpm, $blists_url, $mntpoint) = @_;

    my @l;
    foreach my $blist (@$blists_url) {
	$blist->{medium}{mntpoint} and next;

	# set it, then verify
	$blist->{medium}{mntpoint} = $mntpoint;
	if (-r urpm::removable::file_or_synthesis_dir_from_blist($blist)) {
	    $urpm->{log}("found cdrom $blist->{medium}{name} mounted in $mntpoint");
	    push @l, $blist;
	} else {
	    delete $blist->{medium}{mntpoint};
	}
    }
    @l;
}

#- side-effects: none
sub _look_for_mounted_cdrom_in_mtab() {

    map { $_->{mntpoint} } 
      grep { $_->{fs} eq 'iso9660' || $_->{fs} eq 'udf' } urpm::sys::read_mtab();
}

#- side-effects:
#-   + those of _try_mounting_cdrom_using_hal ($urpm->{cdrom_mounted}, "hal_mount")
#-   + those of _find_blist_url_matching ($blists_url->[_]{medium}{mntpoint})
sub try_mounting_cdrom {
    my ($urpm, $blists_url) = @_;

    my @blists_url;

    # first try without hal, it allows users where hal fails to work (with one CD only)
    my @mntpoints = _look_for_mounted_cdrom_in_mtab();
    @blists_url = map { _find_blist_url_matching($urpm, $blists_url, $_) } @mntpoints;

    if (!@blists_url) {
	@mntpoints = _try_mounting_cdrom_using_hal($urpm);
	@blists_url = map { _find_blist_url_matching($urpm, $blists_url, $_) } @mntpoints;
    }
    @blists_url;
}

#- side-effects: $urpm->{cdrom_mounted}, "hal_mount"
sub _try_mounting_cdrom_using_hal {
    my ($urpm) = @_;

    $urpm->{cdrom_mounted} = {}; # reset

    eval { require Hal::Cdroms; 1 } or $urpm->{error}(N("You must mount CD-ROM yourself (or install perl-Hal-Cdroms to have it done automatically)")), return();

    my $hal_cdroms = eval { Hal::Cdroms->new } or $urpm->{fatal}(N("HAL daemon (hald) is not running or not ready"));

    foreach my $hal_path ($hal_cdroms->list) {
	my $mntpoint;
	if ($mntpoint = $hal_cdroms->get_mount_point($hal_path)) {
	} else {
	    $urpm->{log}("trying to mount $hal_path");
	    $mntpoint = $hal_cdroms->ensure_mounted($hal_path)
	      or $urpm->{error}("failed to mount $hal_path: $hal_cdroms->{error}"), next;
	}
	$urpm->{cdrom_mounted}{$hal_path} = $mntpoint;
    }
    values %{$urpm->{cdrom_mounted}};
}

#- side-effects:
#-   + those of try_mounting_cdrom ($urpm->{cdrom_mounted}, $blists_url->[_]{medium}{mntpoint}, "hal_mount")
sub _mount_cdrom_and_check {
    my ($urpm, $blists) = @_;

    my @matching_blists = try_mounting_cdrom($urpm, $blists) or return;
    grep { !_check_notfound($_) } @matching_blists;
}

#- side-effects: none
sub _check_notfound {
    my ($blist) = @_;

    $blist->{medium}{mntpoint} or return;

    foreach (values %{$blist->{pkgs}}) {
	my $dir_ = _filepath($blist, $_) or next;
	-r $dir_ or return 1;
    }
    0;
}

#- side-effects:
#-   + those of _eject_cdrom ($urpm->{cdrom_mounted}, "hal_umount", "hal_eject")
sub _may_eject_cdrom {
    my ($urpm) = @_;

    my @paths = keys %{$urpm->{cdrom_mounted}};
    @paths == 1 or return;

    # only one cdrom mounted, we know it is the one to umount/eject
    _eject_cdrom($urpm, $paths[0]);
}


#- side-effects: $urpm->{cdrom_mounted}, "hal_umount", "hal_eject"
sub _eject_cdrom {
    my ($urpm, $hal_path) = @_;

    my $mntpoint = delete $urpm->{cdrom_mounted}{$hal_path};
    $urpm->{debug} and $urpm->{debug}("umounting and ejecting $mntpoint (cdrom $hal_path)");

    eval { require Hal::Cdroms; 1 } or return;

    my $hal_cdroms = Hal::Cdroms->new;
    $hal_cdroms->unmount($hal_path) or do {
	my $mntpoint = $hal_cdroms->get_mount_point($hal_path);
	#- trying harder. needed when the cdrom was not mounted by hal
	$mntpoint && system("umount '$mntpoint' 2>/dev/null") == 0
	  or $urpm->{error}("failed to umount $hal_path: $hal_cdroms->{error}");
    };
    $hal_cdroms->eject($hal_path);
    1;
}

#- side-effects: "eject"
#-   + those of _mount_cdrom_and_check ($urpm->{cdrom_mounted}, $blists_url->[_]{medium}{mntpoint}, "hal_mount")
#-   + those of _may_eject_cdrom ($urpm->{cdrom_mounted}, "hal_umount", "hal_eject")
sub _mount_cdrom {
    my ($urpm, $blists, $ask_for_medium) = @_;

    my $retry;

    #- the directory given does not exist and may be accessible
    #- by mounting some other directory. Try to figure it out and mount
    #- everything that might be necessary.
    while (1) {

	if (my @blists = _mount_cdrom_and_check($urpm, $blists)) {
	    return @blists;
	}

	# ask for the first one, it's ok if the user insert another wanted cdrom
	my $medium = $blists->[0]{medium};

	$retry++ and $urpm->{log}("wrong CDROM, wanted $medium->{name}");

	    $ask_for_medium 
	      or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));

	    _may_eject_cdrom($urpm);

	    $ask_for_medium->(remove_internal_name($medium->{name}))
	      or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));
    }
}

#- side-effects: none
sub _filepath {
    my ($blist, $pkg) = @_;

    my $url = urpm::blist_pkg_to_url($blist, $pkg);
    my $filepath = file_from_local_medium($blist->{medium}, $url) or return;
    $filepath =~ m!/.*/! or return; #- is this really needed??
    $filepath;
}

#- side-effects: "copy-move-files"
sub _do_the_copy {
    my ($urpm, $filepath) = @_;

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
#-   + those of _do_the_copy: "copy-move-files"
sub _copy_from_cdrom__if_needed {
    my ($urpm, $blist, $sources, $want_copy) = @_;

	while (my ($id, $pkg) = each %{$blist->{pkgs}}) {
	    my $filepath = _filepath($blist, $pkg) or next;

	    if (-r $filepath) {
		$sources->{$id} = $want_copy ? _do_the_copy($urpm, $filepath) : $filepath;
	    } else {
		#- fallback to use other method for retrieving the file later.
		$urpm->{error}(N("unable to read rpm file [%s] from medium \"%s\"", $filepath, $blist->{medium}{name}));
	    }
	}
}

#- side-effects:
#-   + those of _may_eject_cdrom ($urpm->{cdrom_mounted}, "hal_umount", "hal_eject")
#-   + those of _mount_cdrom ($urpm->{cdrom_mounted}, $blists_url->[_]{medium}{mntpoint}, "hal_mount", "hal_eject")
#-   + those of _copy_from_cdrom__if_needed ("copy-move-files")
sub copy_packages_of_removable_media {
    my ($urpm, $blists, $sources, $o_ask_for_medium) = @_;

    my @blists = grep { urpm::is_cdrom_url($_->{medium}{url}) } @$blists;

    # we prompt for CDs used less first, since the last CD will be used directly
    @blists = sort { values(%{$a->{list}}) <=> values(%{$b->{list}}) } @blists;

    my $prev_medium;
    while (@blists) {
	$prev_medium and delete $prev_medium->{mntpoint};
	_may_eject_cdrom($urpm);

	my @blists_mounted = _mount_cdrom($urpm, \@blists, $o_ask_for_medium);
	@blists = difference2(\@blists, \@blists_mounted);
	foreach my $blist (@blists_mounted) {
	    _copy_from_cdrom__if_needed($urpm, $blist, $sources, @blists > 0);
	    $prev_medium = $blist->{medium};
        }
    }

    1;
}

1;
