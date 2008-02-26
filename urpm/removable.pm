package urpm::removable;

# $Id$

use urpm::msg;
use urpm::sys;
use urpm::util;
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
    my %info;
    grep { $infos{$_}{mounted} } urpm::sys::find_mntpoints($dir, \%info);
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
	    try_mounting($urpm, $dir, $removable);
	    -e $dir or return 2;
	}
	foreach (values %{$list->[$id]}) {
	    chomp;
	    my $dir_ = file_from_local_url($_) or next;
	    $dir_ =~ m!/.*/! or next; #- is this really needed??
	    unless ($dir) {
		$dir = $dir_;
		try_mounting($urpm, $dir, $removable);
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
		    or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));
		try_umounting($urpm, $dir);
		system("/usr/bin/eject '$device' 2>/dev/null");
		is_iso($medium->{removable})
		    || $o_ask_for_medium->(remove_internal_name($medium->{name}), $medium->{removable})
		    or $urpm->{fatal}(4, N("medium \"%s\" is not available", $medium->{name}));
	    }
	    if (-e $dir) {
		while (my ($i, $url) = each %{$list->[$id]}) {
		    chomp $url;
		    my $filepath = file_from_local_url($url) or next;
		    $filepath =~ m!/.*/! or next; #- is this really needed??
		    my $filename = basename($filepath);

		    if (-r $filepath) {
			#- we should assume a possibly buggy removable device...
			#- First, copy in partial cache, and if the package is still good,
			#- transfer it to the rpms cache.
			unlink "$urpm->{cachedir}/partial/$filename";
			$urpm->{log}("copying $filepath");
			if (copy_and_own($filepath, "$urpm->{cachedir}/partial/$filename") &&
			    URPM::verify_rpm("$urpm->{cachedir}/partial/$filename", nosignatures => 1))
			{
			    #- now we can consider the file to be fine.
			    unlink "$urpm->{cachedir}/rpms/$filename";
			    urpm::sys::move_or_die($urpm, "$urpm->{cachedir}/partial/$filename", "$urpm->{cachedir}/rpms/$filename");
			    $sources->{$i} = "$urpm->{cachedir}/rpms/$filename";
			}
		    }
		    unless ($sources->{$i}) {
			#- fallback to use other method for retrieving the file later.
			$urpm->{error}(N("unable to read rpm file [%s] from medium \"%s\"", $filepath, $medium->{name}));
		    }
		}
	    } else {
		$urpm->{error}(N("medium \"%s\" is not available", $medium->{name}));
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
	    -e $dir || try_mounting($urpm, $dir) or
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
		@sorted_media = ($already_mounted_medium, 
				 grep { $_ ne $already_mounted_medium } @sorted_media);
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

1;
