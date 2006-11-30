package urpm::select;

# $Id$

use urpm::msg;
use urpm::util;
use URPM;

sub _findindeps {
    my ($urpm, $found, $qv, $v, $caseinsensitive, $src) = @_;

    foreach (keys %{$urpm->{provides}}) {
	#- search through provides to find if a provide matches this one;
	#- but manage choices correctly (as a provides may be virtual or
	#- defined several times).
	/$qv/ || !$caseinsensitive && /$qv/i or next;

	my @list = grep { defined $_ } map {
	    my $pkg = $urpm->{depslist}[$_];
	    $pkg && ($src ? $pkg->arch eq 'src' : $pkg->arch ne 'src')
	      ? $pkg->id : undef;
	} keys %{$urpm->{provides}{$_} || {}};
	@list > 0 and push @{$found->{$v}}, join '|', @list;
    }
}

#- search packages registered by their names by storing their ids into the $packages hash.
#- Recognized options:
#-	all
#-	caseinsensitive
#-	fuzzy
#-	src
#-	use_provides
sub search_packages {
    my ($urpm, $packages, $names, %options) = @_;
    my (%exact, %exact_a, %exact_ra, %found, %foundi);
    foreach my $v (@$names) {
	my $qv = quotemeta $v;
	$qv = '(?i)' . $qv if $options{caseinsensitive};

	unless ($options{fuzzy}) {
	    #- try to search through provides.
	    if (my @l = map {
		    $_
		    && ($options{src} ? $_->arch eq 'src' : $_->is_arch_compat)
		    && ($options{use_provides} || $_->name eq $v)
		    && defined($_->id)
		    && (!defined $urpm->{searchmedia} ||
			    $urpm->{searchmedia}{start} <= $_->id
		    	    && $urpm->{searchmedia}{end} >= $_->id)
		    ? $_ : @{[]};
		} map {
		    $urpm->{depslist}[$_];
		} keys %{$urpm->{provides}{$v} || {}})
	    {
		#- we assume that if there is at least one package providing
		#- the resource exactly, this should be the best one; but we
		#- first check if one of the packages has the same name as searched.
		if (my @l2 = grep { $_->name eq $v } @l) {
		    @l = @l2;
		}
		$exact{$v} = join('|', map { $_->id } @l);
		next;
	    }
	}

	if ($options{use_provides} && $options{fuzzy}) {
	    _findindeps($urpm, \%found, $qv, $v, $options{caseinsensitive}, $options{src});
	}

	foreach my $id (defined $urpm->{searchmedia} ?
	    ($urpm->{searchmedia}{start} .. $urpm->{searchmedia}{end}) :
	    (0 .. $#{$urpm->{depslist}})
	) {
	    my $pkg = $urpm->{depslist}[$id];
	    ($options{src} ? $pkg->arch eq 'src' : $pkg->is_arch_compat) or next;
	    my $pack_name = $pkg->name;
	    my $pack_ra = $pack_name . '-' . $pkg->version;
	    my $pack_a = "$pack_ra-" . $pkg->release;
	    my $pack = "$pack_a." . $pkg->arch;
	    unless ($options{fuzzy}) {
		if ($pack eq $v) {
		    $exact{$v} = $id;
		    next;
		} elsif ($pack_a eq $v) {
		    push @{$exact_a{$v}}, $id;
		    next;
		} elsif ($pack_ra eq $v || $options{src} && $pack_name eq $v) {
		    push @{$exact_ra{$v}}, $id;
		    next;
		}
	    }
	    $pack =~ /$qv/ and push @{$found{$v}}, $id;
	    $pack =~ /$qv/i and push @{$foundi{$v}}, $id unless $options{caseinsensitive};
	}
    }

    my $result = 1;
    foreach (@$names) {
	if (defined $exact{$_}) {
	    $packages->{$exact{$_}} = 1;
	    foreach (split /\|/, $exact{$_}) {
		my $pkg = $urpm->{depslist}[$_] or next;
		$pkg->set_flag_skip(0); #- reset skip flag as manually selected.
	    }
	} else {
	    #- at this level, we need to search the best package given for a given name,
	    #- always prefer already found package.
	    my %l;
	    foreach (@{$exact_a{$_} || $exact_ra{$_} || $found{$_} || $foundi{$_} || []}) {
		my $pkg = $urpm->{depslist}[$_];
		push @{$l{$pkg->name}}, $pkg;
	    }
	    if (values(%l) == 0 || values(%l) > 1 && !$options{all}) {
		$urpm->{error}(N("No package named %s", $_));
		values(%l) != 0 and $urpm->{error}(
		    N("The following packages contain %s: %s",
			$_, "\n" . join("\n", sort { $a cmp $b } keys %l))
		);
		$result = 0;
	    } else {
		if (!@{$exact_a{$_} || $exact_ra{$_} || []}) {
		    #- we found a non-exact match
		    $result = 'substring';
		}
		foreach (values %l) {
		    my $best;
		    foreach (@$_) {
			if ($best && $best != $_) {
			    $_->compare_pkg($best) > 0 and $best = $_;
			} else {
			    $best = $_;
			}
		    }
		    $packages->{$best->id} = 1;
		    $best->set_flag_skip(0); #- reset skip flag as manually selected.
		}
	    }
	}
    }

    #- return true if no error has been encountered, else false.
    $result;
}

#- Resolves dependencies between requested packages (and auto selection if any).
#- handles parallel option if any.
#- The return value is true if program should be restarted (in order to take
#- care of important packages being upgraded (priority upgrades)
#- %options :
#-	rpmdb
#-	auto_select
#-	install_src
#-	priority_upgrade
#- %options passed to ->resolve_requested:
#-	callback_choices
#-	keep
#-	nodeps
sub resolve_dependencies {
    #- $state->{selected} will contain the selection of packages to be
    #- installed or upgraded
    my ($urpm, $state, $requested, %options) = @_;
    my $need_restart;

    if ($options{install_src}) {
	#- only src will be installed, so only update $state->{selected} according
	#- to src status of files.
	foreach (keys %$requested) {
	    my $pkg = $urpm->{depslist}[$_] or next;
	    $pkg->arch eq 'src' or next;
	    $state->{selected}{$_} = undef;
	}
    }
    if ($urpm->{parallel_handler}) {
	require urpm::parallel; #- help perl_checker;
	urpm::parallel::resolve_dependencies($urpm, $state, $requested, %options);
    } else {
	my $db;

	if ($options{rpmdb}) {
	    $db = new URPM;
	    $db->parse_synthesis($options{rpmdb});
	} else {
	    $db = urpm::db_open_or_die($urpm, $urpm->{root});
	}

	my $sig_handler = sub { undef $db; exit 3 };
	local $SIG{INT} = $sig_handler;
	local $SIG{QUIT} = $sig_handler;

	#- auto select package for upgrading the distribution.
	if ($options{auto_select}) {
	    $urpm->request_packages_to_upgrade($db, $state, $requested, requested => undef,
    		start => $urpm->{searchmedia}{start}, end => $urpm->{searchmedia}{end});
	}

	#- resolve dependencies which will be examined for packages that need to
	#- have urpmi restarted when they're updated.
	$urpm->resolve_requested($db, $state, $requested, %options);

	if ($options{priority_upgrade} && !$options{rpmdb}) {
	    my (%priority_upgrade, %priority_requested);
	    @priority_upgrade{split /,/, $options{priority_upgrade}} = ();

	    #- check if a priority upgrade should be tried
	    foreach (keys %{$state->{selected}}) {
		my $pkg = $urpm->{depslist}[$_] or next;
		exists $priority_upgrade{$pkg->name} or next;
		$priority_requested{$pkg->id} = undef;
	    }

	    if (%priority_requested) {
		my %priority_state;

		$urpm->resolve_requested($db, \%priority_state, \%priority_requested, %options);
		if (grep { ! exists $priority_state{selected}{$_} } keys %priority_requested) {
		    #- some packages which were selected previously have not been selected, strange!
		    $need_restart = 0;
		} elsif (grep { ! exists $priority_state{selected}{$_} } keys %{$state->{selected}}) {
		    #- there are other packages to install after this priority transaction.
		    %$state = %priority_state;
		    $need_restart = 1;
		}
	    }
	}
    }
    $need_restart;
}

#- find packages to remove.
#- options:
#-	bundle
#-	callback_base
#-	callback_fuzzy
#-	callback_notfound
#-	force
#-	matches
#-	test
sub find_packages_to_remove {
    my ($urpm, $state, $l, %options) = @_;

    if ($urpm->{parallel_handler}) {
	#- invoke parallel finder.
	$urpm->{parallel_handler}->parallel_find_remove($urpm, $state, $l, %options, find_packages_to_remove => 1);
    } else {
	my $db = urpm::db_open_or_die($urpm, $urpm->{root});
	my (@m, @notfound);

	if (!$options{matches}) {
	    foreach (@$l) {
		my ($n, $found);

		#- check if name-version-release-architecture was given.
		if (($n) = /^(.*)-[^\-]*-[^\-]*\.[^\.\-]*$/) {
		    $db->traverse_tag('name', [ $n ], sub {
			    my ($p) = @_;
			    $p->fullname eq $_ or return;
			    $urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
			    push @m, scalar $p->fullname;
			    $found = 1;
			});
		    $found and next;
		}

		#- check if name-version-release was given.
		if (($n) = /^(.*)-[^\-]*-[^\-]*$/) {
		    $db->traverse_tag('name', [ $n ], sub {
			    my ($p) = @_;
			    my ($name, $version, $release) = $p->fullname;
			    "$name-$version-$release" eq $_ or return;
			    $urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
			    push @m, scalar $p->fullname;
			    $found = 1;
			});
		    $found and next;
		}

		#- check if name-version was given.
		if (($n) = /^(.*)-[^\-]*$/) {
		    $db->traverse_tag('name', [ $n ], sub {
			    my ($p) = @_;
			    my ($name, $version) = $p->fullname;
			    "$name-$version" eq $_ or return;
			    $urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
			    push @m, scalar $p->fullname;
			    $found = 1;
			});
		    $found and next;
		}

		#- check if only name was given.
		$db->traverse_tag('name', [ $_ ], sub {
			my ($p) = @_;
			$p->name eq $_ or return;
			$urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
			push @m, scalar $p->fullname;
			$found = 1;
		    });
		$found and next;

		push @notfound, $_;
	    }
	    if (!$options{force} && @notfound && @$l > 1) {
		$options{callback_notfound} && $options{callback_notfound}->($urpm, @notfound)
		  or return ();
	    }
	}
	if ($options{matches} || @notfound) {
	    my $match = join "|", map { quotemeta } @$l;
	    my $qmatch = qr/$match/;

	    #- reset what has been already found.
	    %$state = ();
	    @m = ();

	    $urpm->{log}(qq(going through installed packages looking for "$match"...));
	    #- search for packages that match, and perform closure again.
	    $db->traverse(sub {
		    my ($p) = @_;
		    my $f = scalar $p->fullname;
		    $f =~ $qmatch or return;
		    $urpm->resolve_rejected($db, $state, $p, removed => 1, bundle => $options{bundle});
		    push @m, $f;
		});
	    $urpm->{log}("...done, packages found [" . join(' ', @m) . "]");

	    if (!$options{force} && @notfound) {
		if (@m) {
		    $options{callback_fuzzy} && $options{callback_fuzzy}->($urpm, @$l > 1 ? $match : $l->[0], @m)
		      or return ();
		} else {
		    $options{callback_notfound} && $options{callback_notfound}->($urpm, @notfound)
		      or return ();
		}
	    }
	}

	#- check if something needs to be removed.
	find_removed_from_basesystem($urpm, $db, $state, $options{callback_base})
	    or return ();
    }
    grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}};
}

sub find_removed_from_basesystem {
    my ($urpm, $db, $state, $callback_base) = @_;
    if ($callback_base && %{$state->{rejected} || {}}) {
	my %basepackages;
	my @dont_remove = ('basesystem', split /,\s*/, $urpm->{global_config}{'prohibit-remove'});
	#- check if a package to be removed is a part of basesystem requires.
	$db->traverse_tag('whatprovides', \@dont_remove, sub {
	    my ($p) = @_;
	    $basepackages{$p->fullname} = 0;
	});
	foreach (grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}}) {
	    exists $basepackages{$_} or next;
	    ++$basepackages{$_};
	}
	if (grep { $_ } values %basepackages) {
	    return $callback_base->($urpm, grep { $basepackages{$_} } keys %basepackages);
	}
    }
    return 1;
}

#- misc functions to help finding ask_unselect and ask_remove elements with their reasons translated.
sub unselected_packages {
    my (undef, $state) = @_;
    grep { $state->{rejected}{$_}{backtrack} } keys %{$state->{rejected} || {}};
}

sub translate_why_unselected {
    my ($urpm, $state, @fullnames) = @_;

    join("\n", map { translate_why_unselected_one($urpm, $state, $_) } sort @fullnames);
}

sub translate_why_unselected_one {
    my ($urpm, $state, $fullname) = @_;

    my $rb = $state->{rejected}{$fullname}{backtrack};
    my @froms = keys %{$rb->{closure} || {}};
    my @unsatisfied = @{$rb->{unsatisfied} || []};
    my $s = join ", ", (
	(map { N("due to missing %s", $_) } @froms),
	(map { N("due to unsatisfied %s", $_) } uniq(map {
	    #- XXX in theory we shouldn't need this, dependencies (and not ids) should
	    #- already be present in @unsatisfied. But with biarch packages this is
	    #- not always the case.
	    /\D/ ? $_ : scalar($urpm->{depslist}[$_]->fullname);
	} @unsatisfied)),
	$rb->{promote} && !$rb->{keep} ? N("trying to promote %s", join(", ", @{$rb->{promote}})) : (),
	$rb->{keep} ? N("in order to keep %s", join(", ", @{$rb->{keep}})) : (),
    );
    $fullname . ($s ? " ($s)" : '');
}

sub removed_packages {
    my (undef, $state) = @_;
    grep {
	$state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted};
    } keys %{$state->{rejected} || {}};
}

sub translate_why_removed {
    my ($urpm, $state, @fullnames) = @_;
    join("\n", map { translate_why_removed_one($urpm, $state, $_) } sort @fullnames);
}
sub translate_why_removed_one {
    my ($urpm, $state, $fullname) = @_;

    my $closure = $state->{rejected}{$fullname}{closure};
    my ($from) = keys %$closure;
    my ($whyk) = keys %{$closure->{$from}};
    my $whyv = $closure->{$from}{$whyk};
    my $frompkg = $urpm->search($from, strict_fullname => 1);
    my $s = do {
	if ($whyk =~ /old_requested/) {
	    N("in order to install %s", $frompkg ? scalar $frompkg->fullname : $from);
	} elsif ($whyk =~ /unsatisfied/) {
	    join(",\n  ", map {
		if (/([^\[\s]*)(?:\[\*\])?(?:\[|\s+)([^\]]*)\]?$/ && $2 ne '*') {
		    N("due to unsatisfied %s", "$1 $2");
		} else {
		    N("due to missing %s", $_);
		}
	    } @$whyv);
	} elsif ($whyk =~ /conflicts/) {
	    N("due to conflicts with %s", $whyv);
	} elsif ($whyk =~ /unrequested/) {
	    N("unrequested");
	} else {
	    undef;
	}
    };
    #- now insert the reason if available.
    $fullname . ($s ? "\n ($s)" : '');
}


1;
