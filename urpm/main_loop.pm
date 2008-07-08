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
    my ($auto_select, $no_install, $install_src, $clean, $noclean, $force, $parallel, $test, $env) =
      ($::auto_select, $::no_install, $::install_src, $::clean, $::noclean, $::force, $::parallel, $::test, $::env);

    urpm::get_pkgs::clean_all_cache($urpm) if $clean;

my ($local_sources, $list) = urpm::get_pkgs::selected2list($urpm,
    $state->{selected},
    clean_other => !$noclean && $urpm->{options}{'pre-clean'},
);
if (!$local_sources && !$list) {
    $urpm->{fatal}(3, N("unable to get source packages, aborting"));
}

my %sources = %$local_sources;

urpm::removable::try_mounting_non_cdroms($urpm, $list);

$callbacks->{pre_removable} and $callbacks->{pre_removable}->();
require urpm::cdrom;
urpm::cdrom::copy_packages_of_removable_media($urpm,
    $list, \%sources,
    $callbacks->{copy_removable});
$callbacks->{post_removable} and $callbacks->{post_removable}->();

#- now create transaction just before installation, this will save user impression of slowness.
#- split of transaction should be disabled if --test is used.
urpm::install::build_transaction_set_($urpm, $state,
			  rpmdb => $env && "$env/rpmdb.cz",
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
my @errors;
my $exit_code = 0;

foreach my $set (@{$state->{transaction} || []}) {
    my $transaction_sources = {};
    my @transaction_list;

    #- put a blank line to separate with previous transaction or user question.
    print "\n" if $options{verbose} >= 0;

    #- prepare transaction...
    urpm::install::prepare_transaction($urpm, $set, $list, \%sources, \@transaction_list, $transaction_sources);

    #- first, filter out what is really needed to download for this small transaction.
    my @error_sources;
    urpm::get_pkgs::download_packages_of_distant_media($urpm,
	\@transaction_list,
	$transaction_sources,
	\@error_sources,
	quiet => $options{verbose} < 0,
	callback => $callbacks->{trans_log},
    );
    if (@error_sources) {
	$_->[0] = urpm::download::hide_password($_->[0]) foreach @error_sources;
	if (my @missing = grep { $_->[1] eq 'missing' } @error_sources) {
	    $exit_code = 10;
	    push @errors, map { "missing $_->[0]" } @missing;

	    my $msg = join("\n", map { "    $_->[0]" } @missing);
	    !$urpm->{options}{auto} && $callbacks->{ask_yes_or_no}->(
		N("Installation failed"), 
		N("Installation failed, some files are missing:\n%s\nYou may want to update your urpmi database", $msg)
		  . "\n\n" . N("Try to go on anyway? (y/N) ")) or last;
	}
	if (my @bad = grep { $_->[1] eq 'bad' } @error_sources) {
	    $exit_code = 11;
	    push @errors, map { "bad $_->[0]" } @bad;

	    my $msg = join("\n", map { "    $_->[0]" } @bad);
	    !$urpm->{options}{auto} && $callbacks->{ask_yes_or_no}->(
		N("Installation failed"), 
		N("Installation failed, bad rpms:\n%s", $msg)
		  . "\n\n" . N("Try to go on anyway? (y/N) ")) or last;
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
	    $callbacks->{bad_signature}->("$msg:\n$p\n", $msg2);
	}
    }

    #- install source package only (whatever the user is root or not, but use rpm for that).
    if ($install_src) {
	if (my @l = grep { /\.src\.rpm$/ } values %transaction_sources_install, values %$transaction_sources) {
	    my $rpm_opt = $options{verbose} >= 0 ? 'vh' : '';
	    system("rpm", "-i$rpm_opt", @l, ($urpm->{root} ? ("--root", $urpm->{root}) : @{[]}));
	    #- Warning : the following message is parsed in urpm::parallel_*
	    if ($?) {
		print N("Installation failed"), "\n";
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
	    print N("distributing %s", join(' ', values %transaction_sources_install, values %$transaction_sources)), "\n";
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
		    print N("installing %s from %s", join(' ', map { s!.*/!!; $_ } @packnames), $common_prefix), "\n";
		} else {
		    print N("installing %s", join "\n", @packnames), "\n";
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
		oldpackage => $state->{oldpackage},
		justdb => $options{justdb},
		replacepkgs => $options{replacepkgs},
		callback_inst => $callbacks->{inst},
		callback_trans => $callbacks->{trans},
		callback_report_uninst => $callbacks->{callback_report_uninst},
	    );
	    
	    urpm::orphans::add_unrequested($urpm, $state);

	    my @l = urpm::install::install($urpm,
		$to_remove,
		\%transaction_sources_install, $transaction_sources,
		%install_options_common,
	    );
	    if (@l) {
		#- Warning : the following message is parsed in urpm::parallel_*
		my $msg = N("Installation failed:") . "\n" . join("\n",  map { "\t$_" } @l) . "\n";
		if ($urpm->{options}{auto} || !$urpm->{options}{'allow-nodeps'} && !$urpm->{options}{'allow-force'}) {
		    print $msg;
		    ++$nok;
		    ++$urpm->{logger_id};
		    push @errors, @l;
		} else {
		    $callbacks->{ask_yes_or_no}->(N("Installation failed"), 
						  $msg . N("Try installation without checking dependencies? (y/N) ")) or ++$nok, next;
		    $urpm->{log}("starting installing packages without deps");
		    @l = urpm::install::install($urpm,
			$to_remove,
			\%transaction_sources_install, $transaction_sources,
			nodeps => 1,
			%install_options_common,
		    );
		    if (@l) {
			#- Warning : the following message is parsed in urpm::parallel_*
			my $msg = N("Installation failed:") . "\n" . join("\n", map { "\t$_" } @l) . "\n";
			if (!$urpm->{options}{'allow-force'}) {
			    print $msg;
			    ++$nok;
			    ++$urpm->{logger_id};
			    push @errors, @l;
			} else {
			    $callbacks->{ask_yes_or_no}->(N("Installation failed"),
							  $msg . N("Try harder to install (--force)? (y/N) ")) or ++$nok, next;
			    $urpm->{log}("starting force installing packages without deps");
			    @l = urpm::install::install($urpm,
				$to_remove,
				\%transaction_sources_install, $transaction_sources,
				nodeps => 1, force => 1,
				%install_options_common,
			    );
			    if (@l) {
				#- Warning : the following message is parsed in urpm::parallel_*
				print N("Installation failed:") . "\n" . join("\n", map { "\t$_" } @l), "\n";
				++$nok;
				++$urpm->{logger_id};
				push @errors, @l;
			    } else {
				++$ok;
			    }
			}
		    } else {
			++$ok;
		    }
		}
	    } else {
		++$ok;
	    }
	}
    }
}

$callbacks->{completed} and $callbacks->{completed}->();

if ($nok) {
    $callbacks->{trans_error_summary} and $callbacks->{trans_error_summary}->($nok, \@errors);
    print N("Installation failed:"), "\n", map { "\t$_\n" } @errors;
    if ($exit_code) {
	$exit_code = $ok ? 13 : 14;
    } else {
	$exit_code = $ok ? 11 : 12;
    }
} else {
    $callbacks->{success_summary} and $callbacks->{success_summary}->();
    if ($something_was_to_be_done || $auto_select) {
	if (@{$state->{transaction} || []} == 0 && @$ask_unselect == 0) {
	    if ($auto_select) {
		if ($options{verbose} >= 0) {
		    print N("Packages are up to date"), "\n";
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
	} elsif (intersection([ keys %{$state->{selected}} ],
			      [ keys %{$urpm->{provides}{'should-restart'}} ])) {
	    if (my $need_restart_formatted = urpm::sys::need_restart_formatted($urpm->{root})) {
		$callbacks->{need_restart}($need_restart_formatted) if $callbacks->{need_restart};
	    }
	}
    }
}
    $exit_code;
}

1;
