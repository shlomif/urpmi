package urpm::sys;

use strict;

#- check if supermount is used.
sub is_using_supermount {
    my ($device_mntpoint) = @_;
    local $_;
    #- read /etc/fstab and check for existing mount point.
    open my $f, "/etc/fstab" or die "Can't read fstab: $!\n";
    while (<$f>) {
	next if /^\s*#/;
	my ($mntpoint, $fstype, $options) = m!^\s*\S+\s+(/\S+)\s+(\S+)\s+(\S+)!
	    or next;
	$mntpoint =~ s,/+,/,g; $mntpoint =~ s,/$,,;
	if ($fstype eq 'supermount') {
	    return 1 if $device_mntpoint eq $mntpoint;
	    $options =~ /^(?:.*[\s,])?dev=([^\s,]+)/ && $device_mntpoint eq $1
		and return 1;
	}
    }
    return 0;
}

#- find used mount point from a pathname, use a optional mode to allow
#- filtering according the next operation (mount or umount).
sub find_mntpoints {
    my ($dir, $infos) = @_;
    my (%fstab, @mntpoints);
    local ($_);
    #- read /etc/fstab and check for existing mount point.
    open my $f, "/etc/fstab" or die "Can't read fstab: $!\n";
    while (<$f>) {
	next if /^\s*#/;
	my ($device, $mntpoint, $fstype, $options) = m!^\s*(\S+)\s+(/\S+)\s+(\S+)\s+(\S+)!
	    or next;
	$mntpoint =~ s,/+,/,g; $mntpoint =~ s,/$,,;
	$fstab{$mntpoint} =  0;
	if (ref($infos)) {
	    if ($fstype eq 'supermount') {
		$options =~ /^(?:.*[\s,])?dev=([^\s,]+)/ and $infos->{$mntpoint} = {
		    mounted => 0,
		    device => $1,
		    fs => $fstype,
		    supermount => 1,
		};
	    } else {
		$infos->{$mntpoint} = { mounted => 0, device => $device, fs => $fstype };
	    }
	}
    }
    close $f;
    open $f, "/etc/mtab" or die "Can't read mtab: $!\n";
    while (<$f>) {
	my ($device, $mntpoint, $fstype, $options) = m!^\s*(\S+)\s+(/\S+)\s+(\S+)\s+(\S+)!
	    or next;
	$mntpoint =~ s,/+,/,g; $mntpoint =~ s,/$,,;
	$fstab{$mntpoint} = 1;
	if (ref($infos)) {
	    if ($fstype eq 'supermount') {
		$options =~ /^(?:.*[\s,])?dev=([^\s,]+)/ and $infos->{$mntpoint} = {
		    mounted => 1,
		    device => $1,
		    fs => $fstype,
		    supermount => 1,
		};
	    } else {
		$infos->{$mntpoint} = { mounted => 1, device => $device, fs => $fstype };
	    }
	}
    }
    close $f;
    #- try to follow symlink, too complex symlink graph may not be seen.
    #- check the possible mount point.
    my @paths = split '/', $dir;
    my $pdir = '';
    while (defined ($_ = shift @paths)) {
	length($_) or next;
	$pdir .= "/$_";
	$pdir =~ s,/+,/,g; $pdir =~ s,/$,,;
	if (exists($fstab{$pdir})) {
	    ref($infos) and push @mntpoints, $pdir;
	    $infos eq 'mount' && ! $fstab{$pdir} and push @mntpoints, $pdir;
	    $infos eq 'umount' && $fstab{$pdir} and unshift @mntpoints, $pdir;
	    #- following symlinks may be useless or dangerous for supermounted devices.
	    #- this means it is assumed no symlink inside a removable device
	    #- will go outside the device itself (or at least will go into
	    #- regular already mounted device like /).
	    #- for simplification we refuse also any other device and stop here.
	    last;
	} elsif (-l $pdir) {
	    while (my $v = readlink $pdir) {
		if ($pdir =~ m|^/|) {
		    $pdir = $v;
		} else {
		    while ($v =~ m|^\.\./(.*)|) {
			$v = $1;
			$pdir =~ s|^(.*)/[^/]+/*|$1|;
		    }
		    $pdir .= "/$v";
		}
	    }
	    unshift @paths, split '/', $pdir;
	    $pdir = '';
	}
    }
    @mntpoints;
}

#- returns the first unused loop device, or an empty string if none is found.
sub first_free_loopdev () {
    open my $mounts, '/proc/mounts' or do { warn "Can't read /proc/mounts: $!\n"; return 1 };
    my %loopdevs = map { $_ => 1 } grep { ! -d $_ } glob('/dev/loop*');
    local *_;
    while (<$mounts>) {
	(our $dev) = split ' ';
	delete $loopdevs{$dev} if $dev =~ m!^/dev/loop!;
    }
    close $mounts;
    my @l = keys %loopdevs;
    @l ? $l[0] : '';
}

sub trim_until_d {
    my ($dir) = @_;
    while ($dir && !-d $dir) { $dir =~ s,/[^/]*$,, }
    $dir;
}

#- checks if the main filesystems are writeable for urpmi to install files in
sub check_fs_writable () {
    open my $mounts, '/proc/mounts' or do { warn "Can't read /proc/mounts: $!\n"; return 1 };
    local *_;
    while (<$mounts>) {
	(undef, our $mountpoint, undef, my $opts) = split ' ';
	if ($opts =~ /\bro\b/ && $mountpoint =~ m!^(/|/usr|/s?bin)$!) {
	    return 0;
	}
    }
    1;
}

1;
