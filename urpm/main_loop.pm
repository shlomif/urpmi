package urpm::main_loop;

# $Id$

#- Copyright (C) 1999, 2000, 2001, 2002, 2003, 2004, 2005 MandrakeSoft SA
#- Copyright (C) 2005-2007 Mandriva SA
#-
#- This program is free software; you can redistribute it and/or modify
#- it under the terms of the GNU General Public License as published by
#- the Free Software Foundation; either version 2, or (at your option)
#- any later version.
#-
#- This program is distributed in the hope that it will be useful,
#- but WITHOUT ANY WARRANTY; without even the implied warranty of
#- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#- GNU General Public License for more details.
#-
#- You should have received a copy of the GNU General Public License
#- along with this program; if not, write to the Free Software
#- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

use strict;
use urpm;
use urpm::args;
use urpm::msg;
use urpm::install;
use urpm::media;
use urpm::select;
use urpm::orphans;
use urpm::get_pkgs;
use urpm::signature;
use urpm::util qw(untaint difference2 intersection member partition);

# locking is left to callers
sub run {
    my ($urpm, $state, $something_was_to_be_done, $ask_unselect, $_requested, $callbacks) = @_;

    #- global boolean options
    my ($auto_select, $no_install, $install_src, $clean, $noclean, $force, $parallel, $test, $_env) =
      ($::auto_select, $::no_install, $::install_src, $::clean, $::noclean, $::force, $::parallel, $::test, $::env);

    urpm::get_pkgs::clean_all_cache($urpm) if $clean;

my ($local_sources, $blists) = urpm::get_pkgs::selected2local_and_blists($urpm,
    $state->{selected},
    clean_other => !$noclean && $urpm->{options}{'pre-clean'},
);
if (!$local_sources && !$blists) {
    $urpm->{fatal}(3, N("unable to get source packages, aborting"));
}

my %sources = %$local_sources;

urpm::removable::try_mounting_non_cdroms($urpm, $blists);

$callbacks->{pre_removable} and $callbacks->{pre_removable}->();
require urpm::cdrom;
urpm::cdrom::copy_packages_of_removable_media($urpm,
    $blists, \%sources,
    $callbacks->{copy_removable});
$callbacks->{post_removable} and $callbacks->{post_removable}->();

sub download_packages {
    my ($blists, $sources) = @_;
    my @error_sources;
    urpm::get_pkgs::download_packages_of_distant_media($urpm,
	$blists,
	$sources,
	\@error_sources,
	quiet => $options{verbose} < 0,
	callback => $callbacks->{trans_log},
        ask_retry => !$urpm->{options}{auto} && ($callbacks->{ask_retry} || sub {
	    my ($raw_msg, $msg) = @_;
	    if (my $download_errors = delete $urpm->{download_errors}) {
		$raw_msg = join("\n", @$download_errors, '');
	    }
	    $callbacks->{ask_yes_or_no}('', $raw_msg . "\n" . $msg . "\n" . N("Retry?"));
	}),
    );
    my @msgs;
    if (@error_sources) {
	$_->[0] = urpm::download::hide_password($_->[0]) foreach @error_sources;
	my @bad = grep { $_->[1] eq 'bad' } @error_sources;
	my @missing = grep { $_->[1] eq 'missing' } @error_sources;

	if (@missing) {
	    push @msgs, N("Installation failed, some files are missing:\n%s", 
			  join("\n", map { "    $_->[0]" } @missing))
	      . "\n" .
	      N("You may need to update your urpmi database.");
	}
	if (@bad) {
	    push @msgs, N("Installation failed, bad rpms:\n%s",
			  join("\n", map { "    $_->[0]" } @bad));
	}
    }
    
    (\@error_sources, \@msgs);
}

if (exists $urpm->{options}{'download-all'}) {
    if ($urpm->{options}{'download-all'}) {
	$urpm->{cachedir} = $urpm->{'urpmi-root'}.$urpm->{options}{'download-all'};
	urpm::init_cache_dir($urpm, $urpm->{cachedir});
    }
    my (undef, $available) = urpm::sys::df("$urpm->{cachedir}/rpms");

    if (!$urpm->{options}{ignoresize}) {
	my ($download_size) = urpm::get_pkgs::get_distant_media_filesize($urpm, $blists, \%sources); 
	if ($download_size >= $available*1000) {
	    my $p = N("There is not enough space on your filesystem to download all packages (%s needed, %s available).\nAre you sure you want to continue?", formatXiB($download_size), formatXiB($available*1000)); 
	    $force || urpm::msg::ask_yes_or_no($p) or return 10;
	}	
    }

    #download packages one by one so that we don't try to download them again
    #and again if the user has to restart urpmi because of some failure
    foreach my $blist (@$blists) {
	foreach my $pkg (keys %{$blist->{pkgs}}) {
	    my $blist_one = [{ pkgs => { $pkg => $blist->{pkgs}{$pkg} }, medium => $blist->{medium} }];
	    my ($error_sources) = download_packages($blist_one, \%sources);
	    if (@$error_sources) {
		return 10;
	    }
	}
    }
}

#- now create transaction just before installation, this will save user impression of slowness.
#- split of transaction should be disabled if --test is used.
urpm::install::build_transaction_set_($urpm, $state,
			  nodeps => $urpm->{options}{'allow-nodeps'} || $urpm->{options}{'allow-force'},
			  keep => $urpm->{options}{keep},
			  split_level => $urpm->{options}{'split-level'},
			  split_length => !$test && $urpm->{options}{'split-length'});

    if ($options{debug__do_not_install}) {
	$urpm->{debug} = sub { print STDERR "$_[0]\n" };
    }

$urpm->{debug} and $urpm->{debug}(join("\n", "scheduled sets of transactions:", 
				       urpm::install::transaction_set_to_string($urpm, $state->{transaction} || [])));

$options{debug__do_not_install} and exit 0;

my ($ok, $nok) = (0, 0);
my (@errors, @formatted_errors);
my $exit_code = 0;

my $migrate_back_rpmdb_db_version = 
  $urpm->{root} && urpm::select::should_we_migrate_back_rpmdb_db_version($urpm, $state);

foreach my $set (@{$state->{transaction} || []}) {

    #- put a blank line to separate with previous transaction or user question.
    $urpm->{print}("\n") if $options{verbose} >= 0;

    my ($transaction_blists, $transaction_sources) = 
      urpm::install::prepare_transaction($urpm, $set, $blists, \%sources);

    #- first, filter out what is really needed to download for this small transaction.
    my ($error_sources, $msgs) = download_packages($transaction_blists, $transaction_sources);
    if (@$error_sources) {
	$nok++;
	my $go_on;
	if ($urpm->{options}{auto}) {
	    push @formatted_errors, @$msgs;
	} else {
	    $go_on = $callbacks->{ask_yes_or_no}->(
		N("Installation failed"),
		join("\n\n", @$msgs, N("Try to continue anyway?")));
	}
	if (!$go_on) {
	    my @missing = grep { $_->[1] eq 'missing' } @$error_sources;
	    if (@missing) {
		$exit_code = $ok ? 13 : 14;
	    }
	    last;
	}
    }

    $callbacks->{post_download} and $callbacks->{post_download}->();
    my %transaction_sources_install = %{$urpm->extract_packages_to_install($transaction_sources, $state) || {}};
    $callbacks->{post_extract} and $callbacks->{post_extract}->($set, $transaction_sources, \%transaction_sources_install);

    if (!$force && ($urpm->{options}{'verify-rpm'} || grep { $_->{'verify-rpm'} } @{$urpm->{media}})) {
        $callbacks->{pre_check_sig} and $callbacks->{pre_check_sig}->();
        # CHECK ME: rpmdrake passed "basename => 1" option:
	my @bad_signatures = urpm::signature::check($urpm, \%transaction_sources_install, $transaction_sources,
                                                 callback => $callbacks->{check_sig}
                                             );

	if (@bad_signatures) {
	    my $msg = @bad_signatures == 1 ?
	    	N("The following package has bad signature")
		: N("The following packages have bad signatures");
	    my $msg2 = N("Do you want to continue installation ?");
	    my $p = join "\n", @bad_signatures;
	    $callbacks->{bad_signature}->("$msg:\n$p\n", $msg2) or return 16;
	}
    }

    #- install source package only (whatever the user is root or not, but use rpm for that).
    if ($install_src) {
	if (my @l = grep { /\.src\.rpm$/ } values %transaction_sources_install, values %$transaction_sources) {
	    my $rpm_opt = $options{verbose} >= 0 ? 'vh' : '';
	    system("rpm", "-i$rpm_opt", @l, ($urpm->{root} ? ("--root", $urpm->{root}) : @{[]}));
	    #- Warning : the following message is parsed in urpm::parallel_*
	    if ($?) {
		$urpm->{print}(N("Installation failed"));
		++$nok;
	    } elsif ($urpm->{options}{'post-clean'}) {
		if (my @tmp_srpm = grep { urpm::is_temporary_file($urpm, $_) } @l) {
		    $urpm->{log}(N("removing installed rpms (%s)", join(' ', @tmp_srpm)));
		    unlink @tmp_srpm;
		}
	    }
	}
	next;
    }

    next if $no_install;

    #- clean to remove any src package now.
    foreach (\%transaction_sources_install, $transaction_sources) {
	foreach my $id (keys %$_) {
	    my $pkg = $urpm->{depslist}[$id] or next;
	    $pkg->arch eq 'src' and delete $_->{$id};
	}
    }

    if (keys(%transaction_sources_install) || keys(%$transaction_sources) || $set->{remove}) {
	if ($parallel) {
	    $urpm->{print}(N("distributing %s", join(' ', values %transaction_sources_install, values %$transaction_sources)));
	    #- no remove are handle here, automatically done by each distant node.
	    $urpm->{log}("starting distributed install");
	    $urpm->{parallel_handler}->parallel_install(
		$urpm,
		[ keys %{$state->{rejected} || {}} ], \%transaction_sources_install, $transaction_sources,
		test => $test,
		excludepath => $urpm->{options}{excludepath}, excludedocs => $urpm->{options}{excludedocs},
	    );
	} else {
	    if ($options{verbose} >= 0) {
	      if (my @packnames = (values %transaction_sources_install, values %$transaction_sources)) {
		(my $common_prefix) = $packnames[0] =~ m!^(.*)/!;
		if (length($common_prefix) && @packnames == grep { m!^\Q$common_prefix/! } @packnames) {
		    #- there's a common prefix, simplify message
		    $urpm->{print}(N("installing %s from %s", join(' ', map { s!.*/!!; $_ } @packnames), $common_prefix));
		} else {
		    $urpm->{print}(N("installing %s", join "\n", @packnames));
		}
	      }
	    }
	    my $to_remove = $urpm->{options}{'allow-force'} ? [] : $set->{remove} || [];
	    bug_log(scalar localtime(), " ", join(' ', values %transaction_sources_install, values %$transaction_sources), "\n");
	    $urpm->{log}("starting installing packages");
	    my %install_options_common = (
		urpm::install::options($urpm),
		test => $test,
		verbose => $options{verbose},
		script_fd => $urpm->{options}{script_fd},
		oldpackage => $state->{oldpackage},
		justdb => $options{justdb},
		replacepkgs => $options{replacepkgs},
		callback_close_helper => $callbacks->{close_helper},
		callback_inst => $callbacks->{inst},
		callback_open_helper => $callbacks->{open_helper},
		callback_trans => $callbacks->{trans},
		callback_report_uninst => $callbacks->{callback_report_uninst},
		raw_message => 1,
	    );
	    
	    urpm::orphans::add_unrequested($urpm, $state);

	  install:
	    my @l = urpm::install::install($urpm,
		$to_remove,
		\%transaction_sources_install, $transaction_sources,
		%install_options_common,
	    );
	    if (@l) {
		my ($raw_error, $translated) = partition { /^(badarch|bados|installed|badrelocate|conflicts|installed|diskspace|disknodes|requires|conflicts|unknown)\@/ } @l;
		@l = @$translated;
		my $fatal = grep { /^disk/ } @$raw_error;
		my $no_question = $fatal || $urpm->{options}{auto};

		#- Warning : the following message is parsed in urpm::parallel_*
		my $msg = N("Installation failed:") . "\n" . join("\n",  map { "\t$_" } @l) . "\n";
		if (!$no_question && !$install_options_common{nodeps} && ($urpm->{options}{'allow-nodeps'} || $urpm->{options}{'allow-force'})) {
		    if ($callbacks->{ask_yes_or_no}->(N("Installation failed"), 
						      $msg . N("Try installation without checking dependencies?"))) {
			$urpm->{log}("starting installing packages without deps");
			$install_options_common{nodeps} = 1;
			goto install;
		    }
		} elsif (!$no_question && !$install_options_common{force} && $urpm->{options}{'allow-force'}) {
		    if ($callbacks->{ask_yes_or_no}->(N("Installation failed"),
						      $msg . N("Try harder to install (--force)?"))) {
			$urpm->{log}("starting force installing packages without deps");
			$install_options_common{force} = 1;
			goto install;
		    }
		}
		$urpm->{log}($msg);

		++$nok;
		push @errors, @l;
		$fatal and last;
	    } else {
		++$ok;
	    }
	}
    }
    if ($callbacks->{is_canceled}) {
        last if $callbacks->{is_canceled}->();
    }
}

if ($migrate_back_rpmdb_db_version) {
    urpm::sys::migrate_back_rpmdb_db_version($urpm, $urpm->{root});
}

$callbacks->{completed} and $callbacks->{completed}->();

if ($nok) {
    $callbacks->{trans_error_summary} and $callbacks->{trans_error_summary}->($nok, \@errors);
    if (@formatted_errors) {
	$urpm->{print}(join("\n", @formatted_errors));
    }
    if (@errors) {
	$urpm->{print}(N("Installation failed:") . join("\n", map { "\t$_" } @errors));
    }
    $exit_code ||= $ok ? 11 : 12;
} else {
    $callbacks->{success_summary} and $callbacks->{success_summary}->();
    if ($something_was_to_be_done || $auto_select) {
	if (@{$state->{transaction} || []} == 0 && @$ask_unselect == 0) {
	    if ($auto_select) {
		if ($options{verbose} >= 0) {
		    #- Warning : the following message is parsed in urpm::parallel_*
		    $urpm->{print}(N("Packages are up to date"));
		}
	    } else {
		if ($callbacks->{already_installed_or_not_installable}) {
		    my $msg = urpm::select::translate_already_installed($state);
		    $callbacks->{already_installed_or_not_installable}->([$msg], []);
		}
	    }
	    $exit_code = 15 if our $expect_install;
	} elsif ($test && $exit_code == 0) {
	    #- Warning : the following message is parsed in urpm::parallel_*
	    print N("Installation is possible"), "\n";
	} elsif ($callbacks->{need_restart} && intersection([ keys %{$state->{selected}} ],
                                                            [ keys %{$urpm->{provides}{'should-restart'}} ])) {
	    if (my $need_restart_formatted = urpm::sys::need_restart_formatted($urpm->{root})) {
		$callbacks->{need_restart}($need_restart_formatted);

		# need_restart() accesses rpm db, so we need to ensure things are clean:
		urpm::sys::may_clean_rpmdb_shared_regions($urpm, $options{test});
	    }
	}
    }
}
    $exit_code;
}

1;
