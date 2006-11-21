package urpm::sys;

# $Id$

use strict;
use warnings;
use urpm::util;
use urpm::msg;
use POSIX ();

(our $VERSION) = q($Revision$) =~ /(\d+)/;

#- find used mount point from a pathname, use a optional mode to allow
#- filtering according the next operation (mount or umount).
sub find_mntpoints {
    my ($dir, $infos) = @_;
    my (%fstab, @mntpoints);

    #- read /etc/fstab and check for existing mount point.
    foreach (cat_("/etc/fstab")) {
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
    foreach (cat_("/etc/mtab")) {
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

    #- try to follow symlink, too complex symlink graph may not be seen.
    #- check the possible mount point.
    my @paths = split '/', $dir;
    my $pdir = '';
    local $_;
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

sub proc_mounts() {
    my @l = cat_('/proc/mounts') or warn "Can't read /proc/mounts: $!\n";
    @l;
}

#- returns the first unused loop device, or an empty string if none is found.
sub first_free_loopdev () {
    my %loopdevs = map { $_ => 1 } grep { ! -d $_ } glob('/dev/loop*');
    foreach (proc_mounts()) {
	(our $dev) = split ' ';
	delete $loopdevs{$dev} if $dev =~ m!^/dev/loop!;
    }
    my @l = keys %loopdevs;
    @l ? $l[0] : '';
}

sub trim_until_d {
    my ($dir) = @_;
    foreach (proc_mounts()) {
	#- fail if an iso is already mounted
	m!^/dev/loop! and return $dir;
    }
    while ($dir && !-d $dir) { $dir =~ s,/[^/]*$,, }
    $dir;
}

#- checks if the main filesystems are writeable for urpmi to install files in
sub check_fs_writable () {
    foreach (proc_mounts()) {
	(undef, our $mountpoint, undef, my $opts) = split ' ';
	if ($opts =~ /(?:^|,)ro(?:,|$)/ && $mountpoint =~ m!^(/|/usr|/s?bin)\z!) {
	    return 0;
	}
    }
    1;
}

#- create a plain rpm from an installed rpm and a delta rpm (in the current directory)
#- returns the new rpm filename in case of success
#- params :
#-	$deltarpm : full pathname of the deltarpm
#-	$o_dir : directory where to put the produced rpm (optional)
#-	$o_pkg : URPM::Package object corresponding to the deltarpm (optional)
our $APPLYDELTARPM = '/usr/bin/applydeltarpm';
sub apply_delta_rpm {
    my ($deltarpm, $o_dir, $o_pkg) = @_;
    -x $APPLYDELTARPM or return 0;
    -e $deltarpm or return 0;
    my $rpm;
    if ($o_pkg) {
	require URPM; #- help perl_checker
	$rpm = $o_pkg->name . '-' . $o_pkg->version . '-' . $o_pkg->release . '.' . $o_pkg->arch . '.rpm';
    } else {
	$rpm = `rpm -qp --qf '%{name}-%{version}-%{release}.%{arch}.rpm' '$deltarpm'`;
    }
    $rpm or return 0;
    $rpm = $o_dir . '/' . $rpm;
    unlink $rpm;
    system($APPLYDELTARPM, $deltarpm, $rpm);
    -e $rpm ? $rpm : '';
}

our $tempdir_template = '/tmp/urpm.XXXXXX';
sub mktempdir() {
    my $tmpdir;
    eval { require File::Temp };
    if ($@) {
	#- fall back to external command (File::Temp not in perl-base)
	$tmpdir = `mktemp -d $tempdir_template`;
	chomp $tmpdir;
    } else {
	$tmpdir = File::Temp::tempdir($tempdir_template);
    }
    return $tmpdir;
}

# temporary hack used by urpmi when restarting itself.
sub fix_fd_leak() {
    opendir my $dirh, "/proc/$$/fd" or return undef;
    my @fds = grep { /^(\d+)$/ && $1 > 2 } readdir $dirh;
    closedir $dirh;
    foreach (@fds) {
	my $link = readlink("/proc/$$/fd/$_");
	$link or next;
	next if $link =~ m!^/(usr|dev)/! || $link !~ m!^/!;
	POSIX::close($_);
    }
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


my $RPMLOCK_FILE;
my $LOCK_FILE;

sub lock_rpm_db { 
    my ($urpm, $b_exclusive) = @_;
    _lock($urpm, \$RPMLOCK_FILE, "$urpm->{root}/$urpm->{statedir}/.RPMLOCK", $b_exclusive);
}
sub lock_urpmi_db {
    my ($urpm, $b_exclusive) = @_;
    _lock($urpm, \$LOCK_FILE, "$urpm->{statedir}/.LOCK", $b_exclusive);
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

sub syserror { 
    my ($urpm, $msg, $info) = @_;
    $urpm->{error}("$msg [$info] [$!]");
}

sub open_safe {
    my ($urpm, $sense, $filename) = @_;
    open my $f, $sense, $filename
	or syserror($urpm, $sense eq '>' ? "Can't write file" : "Can't open file", $filename), return undef;
    return $f;
}

sub opendir_safe {
    my ($urpm, $dirname) = @_;
    opendir my $d, $dirname
	or syserror($urpm, "Can't open directory", $dirname), return undef;
    return $d;
}

1;
__END__

=head1 NAME

urpm::sys - OS-related routines for urpmi

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 COPYRIGHT

Copyright (C) 2005 MandrakeSoft SA

Copyright (C) 2005 Mandriva SA

=cut
