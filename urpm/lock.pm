package urpm::lock;

# $Id$

use urpm::msg;


#- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
my ($LOCK_SH, $LOCK_EX, $LOCK_NB, $LOCK_UN) = (1, 2, 4, 8);


################################################################################
#- class functions

#- lock policy concerning chroot :
#  - lock rpm db in chroot
#  - lock urpmi db in /
sub rpm_db {
    my ($urpm, $b_exclusive) = @_;
    urpm::lock->new($urpm, "$urpm->{root}/$urpm->{statedir}/.RPMLOCK", 'rpm', $b_exclusive);
}
sub urpmi_db {
    my ($urpm, $b_exclusive, $b_nofatal) = @_;
    urpm::lock->new($urpm, "$urpm->{statedir}/.LOCK", 'urpmi', $b_exclusive, $b_nofatal);
}


################################################################################
#- methods

sub new {
    my ($_class, $urpm, $file, $db_name, $b_exclusive, $b_nofatal) = @_;
    
    my $fh;
    #- we don't care what the mode is. ">" allow creating the file, but can't be done as user
    open($fh, '>', $file) or open($fh, '<', $file) or return;

    my $lock = bless { 
	fh => $fh, db_name => $db_name, 
	fatal => $b_nofatal ? $urpm->{error} : sub { $urpm->{fatal}(7, $_[0]) }, 
	log => $urpm->{log},
    };
    _lock($lock, $b_exclusive);
    $lock;
}

sub _flock_failed {
    my ($lock) = @_;
    $lock->{fatal}(N("%s database locked", $lock->{db_name}));
}

sub _lock {
    my ($lock, $b_exclusive) = @_;
    $b_exclusive ||= '';
    if ($lock->{log}) {
	my $action = $lock->{exclusive} && !$b_exclusive ? 'releasing exclusive' : $b_exclusive ? 'getting exclusive' : 'getting';
	$lock->{log}("$action lock on $lock->{db_name}");
    }
    my $mode = $b_exclusive ? $LOCK_EX : $LOCK_SH;
    flock $lock->{fh}, $mode|$LOCK_NB or _flock_failed($lock);
    $lock->{locked} = 1;
    $lock->{exclusive} = $b_exclusive;
}

sub get_exclusive {
    my ($lock) = @_;
    _lock($lock, 'exclusive');
}
sub release_exclusive {
    my ($lock) = @_;
    _lock($lock);
}

sub unlock {
    my ($lock) = @_;
    $lock->{fh} or warn "lock $lock->{db_name} already release\n", return;

    if ($lock->{locked}) {
	$lock->{log} and $lock->{log}("unlocking $lock->{db_name} database");
	flock $lock->{fh}, $LOCK_UN;
    }
    close $lock->{fh};
    delete $lock->{fh};
}

sub DESTROY { 
    my ($lock) = @_;
    unlock($lock) if $lock->{fh};
}
