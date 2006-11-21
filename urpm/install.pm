package urpm::install; 

# $Id$

use urpm;
use urpm::msg;
use urpm::util;


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

    my $db = urpm::db_open_or_die($urpm, $urpm->{root}, !$options{test}); #- open in read/write mode unless testing installation.

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
	    $fh = urpm::sys::open_safe($urpm, '<', $install->{$id} || $upgrade->{$id});
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

1;
