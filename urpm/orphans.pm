package urpm::orphans;

use urpm::util;
use urpm::msg;
use urpm;

# $Id: select.pm 243120 2008-07-01 12:24:34Z pixel $

my $fullname2name_re = qr/^(.*)-[^\-]*-[^\-]*\.[^\.\-]*$/;

#- side-effects: none
sub installed_packages_packed {
    my ($urpm) = @_;

    my $db = urpm::db_open_or_die_($urpm);
    my @l;
    $db->traverse(sub {
        my ($pkg) = @_;
	$pkg->pack_header;
	push @l, $pkg;
    });
    \@l;
}

#- side-effects: none
sub unrequested_list__file {
    my ($urpm) = @_;
    "$urpm->{root}/var/lib/rpm/installed-through-deps.list";
}
#- side-effects: none
sub unrequested_list {
    my ($urpm) = @_;
    +{ map { 
	chomp; 
	s/\s+\(.*\)$//; 
	$_ => 1;
    } cat_(unrequested_list__file($urpm)) };
}

#- side-effects:
#-   + those of _installed_req_and_unreq_and_update_unrequested_list (<root>/var/lib/rpm/installed-through-deps.list)
sub _installed_req_and_unreq {
    my ($urpm) = @_;
    my ($req, $unreq, $_unrequested) = _installed_req_and_unreq_and_update_unrequested_list($urpm);
    ($req, $unreq);
}
#- side-effects:
#-   + those of _installed_req_and_unreq_and_update_unrequested_list (<root>/var/lib/rpm/installed-through-deps.list)
sub _installed_and_unrequested_lists {
    my ($urpm) = @_;
    my ($pkgs, $pkgs2, $unrequested) = _installed_req_and_unreq_and_update_unrequested_list($urpm);
    push @$pkgs, @$pkgs2;
    ($pkgs, $unrequested);
}
#- side-effects: <root>/var/lib/rpm/installed-through-deps.list
sub _installed_req_and_unreq_and_update_unrequested_list {
    my ($urpm) = @_;

    my $pkgs = installed_packages_packed($urpm);

    $urpm->{debug}("reading and cleaning " . unrequested_list__file($urpm)) if $urpm->{debug};
    my $unrequested = unrequested_list($urpm);
    my ($unreq, $req) = partition { $unrequested->{$_->name} } @$pkgs;
    
    # update the list (to filter dups and now-removed-pkgs)
    output_safe(unrequested_list__file($urpm), 
		join('', sort map { $_->name . "\n" } @$unreq),
		".old");

    ($req, $unreq, $unrequested);
}


#- side-effects: none
sub _selected_unrequested {
    my ($urpm, $selected) = @_;

    map {
	if (my $from = $selected->{$_}{from}) {
	    ($urpm->{depslist}[$_]->name => "(required by " . $from->fullname . ")");
	} elsif ($selected->{$_}{suggested}) {
	    ($urpm->{depslist}[$_]->name => "(suggested)");
	} else {
	    ();
	}
    } keys %$selected;
}
#- side-effects: $o_unrequested_list
sub _renamed_unrequested {
    my ($urpm, $rejected, $o_unrequested_list) = @_;
    
    my @obsoleted = grep { $rejected->{$_}{obsoleted} } keys %$rejected or return;

    # we have to read the list to know if the old package was marked "unrequested"
    my $current = $o_unrequested_list || unrequested_list($urpm);

    my %l;
    foreach my $fn (@obsoleted) {
	my ($n) = $fn =~ $fullname2name_re;
	$current->{$n} or next;

	my ($new_fn) = keys %{$rejected->{$fn}{closure}};
	my ($new_n) = $new_fn =~ $fullname2name_re;
	if ($new_n ne $n) {
	    $l{$new_n} = "(obsoletes $fn)";
	}
    }
    %l;
}
sub _new_unrequested {
    my ($urpm, $state) = @_;
    (
	_selected_unrequested($urpm, $state->{selected}),
	_renamed_unrequested($urpm, $state->{rejected}),
    );
}
#- side-effects: <root>/var/lib/rpm/installed-through-deps.list
sub add_unrequested {
    my ($urpm, $state) = @_;

    my %l = _new_unrequested($urpm, $state);
    append_to_file(unrequested_list__file($urpm), join('', map { "$_\t\t$l{$_}\n" } keys %l));
}

#- we don't want to check orphans on every auto-select,
#- doing it only after many packages have been added
#-
#- side-effects: none
sub check_unrequested_orphans_after_auto_select {
    my ($urpm) = @_;
    my $f = unrequested_list__file($urpm);
    my $nb_added = wc_l($f) - wc_l("$f.old");
    $nb_added >= $urpm->{options}{'nb-of-new-unrequested-pkgs-between-auto-select-orphans-check'};
}

#- this function computes wether removing $toremove packages will create
#- unrequested orphans.
#-
#- it does not return the new orphans since "whatsuggests" is not available,
#- if it detects there are new orphans, _all_unrequested_orphans()
#- must be used to have the list of the orphans
#-
#- side-effects: none
sub unrequested_orphans_after_remove {
    my ($urpm, $toremove) = @_;

    my $db = urpm::db_open_or_die_($urpm);
    my %toremove = map { $_ => 1 } @$toremove;
    _unrequested_orphans_after_remove_once($urpm, $db, unrequested_list($urpm), \%toremove);
}
#- side-effects: none
sub _unrequested_orphans_after_remove_once {
    my ($urpm, $db, $unrequested, $toremove) = @_;

    my @requires;
    foreach my $fn (keys %$toremove) {
	my ($n) = $fn =~ $fullname2name_re;

	$db->traverse_tag('name', [ $n ], sub {
	    my ($p) = @_;
	    $p->fullname eq $fn or return;
	    push @requires, $p->requires, $p->suggests;
	});
    }

    foreach my $req (uniq(@requires)) {
	$db->traverse_tag_find('whatprovides', URPM::property2name($req), sub {
            my ($p) = @_;
	    $toremove->{$p->fullname} and return; # already done
	    $unrequested->{$p->name} or return;
	    $p->provides_overlap($req) or return;

	    # cool we have a potential "unrequested" package newly unneeded
	    if (_check_potential_unrequested_package_newly_unneeded($urpm, $db, $toremove, $p)) {
		$urpm->{debug}("installed " . $p->fullname . " can now be removed") if $urpm->{debug};
		return 1;
	    } else {
		$urpm->{debug}("installed " . $p->fullname . " can not be removed") if $urpm->{debug};
	    }
	    0;
	}) and return 1;
    }
    0;
}
#- side-effects: none
sub _check_potential_unrequested_package_newly_unneeded {
    my ($urpm, $db, $toremove, $pkg) = @_;

    my $required_maybe_loop;

    foreach my $prop ($pkg->provides) {
	_check_potential_unrequested_provide_newly_unneeded($urpm, $db, $toremove, 
							    scalar($pkg->fullname), $prop, \$required_maybe_loop)
	  and return;	
    }

    if ($required_maybe_loop) {
	my ($fullname, @provides) = @$required_maybe_loop;
	$urpm->{debug}("checking wether $fullname is a depency loop") if $urpm->{debug};

	# doing it locally, since we may fail (and so we must backtrack this change)
	my %ignore = %$toremove;
	$ignore{$pkg->fullname} = 1;

	foreach my $prop (@provides) {
	    _check_potential_unrequested_provide_newly_unneeded($urpm, $db, \%ignore, 
								$fullname, $prop, \$required_maybe_loop)
	      and return;
	}
    }
    1;
}
#- side-effects: none
sub _check_potential_unrequested_provide_newly_unneeded {
    my ($urpm, $db, $toremove, $fullname, $prop, $required_maybe_loop) = @_;

    my ($prov, $range) = URPM::property2name_range($prop) or return;
    
    $db->traverse_tag_find('whatrequires', $prov, sub {
	my ($p2) = @_;
	$toremove->{$p2->fullname} and return 0; # this one is going to be removed, skip it

	foreach ($p2->requires) {
	    my ($pn, $ps) = URPM::property2name_range($_) or next;
	    if ($pn eq $prov && URPM::ranges_overlap($ps, $range)) {
		if ($$required_maybe_loop) {
		    $urpm->{debug}("  installed " . $p2->fullname . " still requires " . $fullname) if $urpm->{debug};
		    return 1;
		}
		$urpm->{debug}("  installed " . $p2->fullname . " may still requires " . $fullname) if $urpm->{debug};
		$$required_maybe_loop = [ scalar $p2->fullname, $p2->provides ];
	    }
	}
	0;
    });
}

#- returns the list of "unrequested" orphans.
#-
#- side-effects: none
sub _all_unrequested_orphans {
    my ($req, $unreq) = @_;

    my (%l, %provides);
    foreach my $pkg (@$unreq) {
	$l{$pkg->name} = $pkg;
	push @{$provides{$_}}, $pkg foreach $pkg->provides_nosense;
    }

    while (my $pkg = shift @$req) {
	foreach my $prop ($pkg->requires, $pkg->suggests) {
	    my $n = URPM::property2name($prop);
	    foreach my $p (@{$provides{$n} || []}) {
		if ($p != $pkg && $l{$p->name} && $p->provides_overlap($prop)) {
		    delete $l{$p->name};
		    push @$req, $p;
		}
	    }
	}
    }

    [ values %l ];
}


#- side-effects: $state->{orphans_to_remove}
#-   + those of _installed_and_unrequested_lists (<root>/var/lib/rpm/installed-through-deps.list)
sub compute_future_unrequested_orphans {
    my ($urpm, $state) = @_;

    $urpm->{log}("computing unrequested orphans");

    my ($current_pkgs, $unrequested) = _installed_and_unrequested_lists($urpm);

    put_in_hash($unrequested, { _new_unrequested($urpm, $state) });

    my %toremove = map { $_ => 1 } URPM::removed_or_obsoleted_packages($state);
    my @pkgs = grep { !$toremove{$_->fullname} } @$current_pkgs;
    push @pkgs, map { $urpm->{depslist}[$_] } keys %{$state->{selected} || {}};

    my ($unreq, $req) = partition { $unrequested->{$_->name} } @pkgs;

    $state->{orphans_to_remove} = _all_unrequested_orphans($req, $unreq);

    # nb: $state->{orphans_to_remove} is used when computing ->selected_size
}

#- it is quite fast. the slow part is the creation of $installed_packages_packed
#- (using installed_packages_packed())
#
#- side-effects:
#-   + those of _installed_req_and_unreq (<root>/var/lib/rpm/installed-through-deps.list)
sub get_orphans {
    my ($urpm) = @_;

    $urpm->{log}("computing unrequested orphans");

    my ($req, $unreq) = _installed_req_and_unreq($urpm);
    _all_unrequested_orphans($req, $unreq);
}
sub get_now_orphans_msg {
    my ($urpm) = @_;

    my $orphans = get_orphans($urpm);
    my @orphans = map { scalar $_->fullname } @$orphans or return '';

    P("The following package is now orphan, use \"urpme --auto-orphans\" to remove it.",
      "The following packages are now orphans, use \"urpme --auto-orphans\" to remove them.", scalar(@orphans))
      . "\n" . add_leading_spaces(join("\n", sort @orphans) . "\n");
}

#- side-effects: none
sub add_leading_spaces {
    my ($s) = @_;
    $s =~ s/^/  /gm;
    $s;
}

#- side-effects: none
sub installed_leaves {
    my ($urpm, $o_discard) = @_;

    my $packages = installed_packages_packed($urpm);

    my (%l, %provides);
    foreach my $pkg (@$packages) {
	next if $o_discard && $o_discard->($pkg);
	$l{$pkg->name} = $pkg;
	push @{$provides{$_}}, $pkg foreach $pkg->provides_nosense;
    }

    foreach my $pkg (@$packages) {
	foreach my $prop ($pkg->requires) {
	    my $n = URPM::property2name($prop);
	    foreach my $p (@{$provides{$n} || []}) {
		$p != $pkg && $p->provides_overlap($prop) and 
		  delete $l{$p->name};
	    }
	}
    }

    [ values %l ];
}
