package urpm::parallel_ka_run;

#- parallel resolve_dependencies
sub parallel_resolve_dependencies {
    my ($parallel, $synthesis, $urpm, $state, $requested, %options) = @_;
    my (%avoided, %requested);

    #- first propagate the synthesis file to all machine.
    $urpm->{log}("parallel_ka_run: mput $parallel->{options} -- '$synthesis' '$synthesis'");
    system "mput $parallel->{options} -- '$synthesis' '$synthesis'";
    $parallel->{synthesis} = $synthesis;

    #- compute command line of urpm? tools.
    my $line = $options{auto_select} ? ' --auto-select' : '';
    foreach (keys %$requested) {
	if (/\|/) {
	    #- taken from URPM::Resolve to filter out choices, not complete though.
	    my $packages = $urpm->find_candidate_packages($_);
	    foreach (values %$packages) {
		my ($best_requested, $best);
		foreach (@$_) {
		    exists $state->{selected}{$_->id} and $best_requested = $_, last;
		    exists $avoided{$_->name} and next;
		    if ($best_requested || exists $requested{$_->id}) {
			if ($best_requested && $best_requested != $_) {
			    $_->compare_pkg($best_requested) > 0 and $best_requested = $_;
			} else {
			    $best_requested = $_;
			}
		    } elsif ($best && $best != $_) {
			$_->compare_pkg($best) > 0 and $best = $_;
		    } else {
			$best = $_;
		    }
		}
		$_ = $best_requested || $best;
	    }
	    #- simplified choices resolution.
	    my $choice = $options{callback_choices}->($urpm, undef, $state, [ values %$packages ]);
	    $line .= ' '.$choice->fullname;
	} else {
	    my $pkg = $urpm->{depslist}[$_] or next;
	    $line .= ' '.$pkg->fullname;
	}
    }

    #- execute urpmq to determine packages to install.
    my ($node, $cont, %chosen);
    local (*F, $_);
    do {
	$cont = 0; #- prepare to stop iteration.
	#- the following state should be cleaned for each iteration.
	delete $state->{selected};
	#- now try an iteration of urpmq.
	$urpm->{log}("parallel_ka_run: rshp -v $parallel->{options} -- urpmq --synthesis $synthesis -f $line ".join(' ', keys %chosen));
	open F, "rshp -v $parallel->{options} -- urpmq --synthesis $synthesis -fdu $line ".join(' ', keys %chosen)." |";
	while (defined ($_ = <F>)) {
	    chomp;
	    s/<([^>]*)>.*:->:(.*)/$2/ and $node = $1;
	    if (/\|/) {
		#- distant urpmq returned a choices, check if it has already been chosen
		#- or continue iteration to make sure no more choices are left.
		$cont ||= 1; #- invalid transitory state (still choices is strange here if next sentence is not executed).
		unless (grep { exists $chosen{$_} } split '\|', $_) {
		    my $choice = $options{callback_choices}->($urpm, undef, $state, [ map { $urpm->search($_) } split '\|', $_ ]);
		    if ($choice) {
			$chosen{scalar $choice->fullname} = $choice;
			#- it has not yet been chosen so need to ask user.
			$cont = 2;
		    } else {
			#- no choices resolved, so forget it (no choices means no choices at all).
			$cont = 0;
		    }
		}
	    } else {
		my $pkg = $urpm->search($_) or next; #TODO
		$state->{selected}{$pkg->id}{$node} = $_;
	    }
	}
	close F or $urpm->{fatal}(1, _("rshp failed"));
	#- check for internal error of resolution.
	$cont == 1 and die "internal distant urpmq error on choice not taken";
    } while ($cont);

    #- keep trace of what has been chosen finally (if any).
    $parallel->{line} = "$line ".join(' ', keys %chosen);

    #- update ask_remove, ask_unselect too along with provided value.
    #TODO
}

#- parallel install.
sub parallel_install {
    my ($parallel, $urpm, $remove, $install, $upgrade) = @_;

    foreach (values %$install, values %$upgrade) {
	my ($basename) = /([^\/]*)$/;
	$urpm->{log}("parallel_ka_run: mput $parallel->{options} -- '$_' $urpm->{cachedir}/rpms/$basename");
	system "mput $parallel->{options} -- '$_' $urpm->{cachedir}/rpms/$basename";
    }

    local (*F, $_);
    my ($node, %bad_nodes);
    $urpm->{log}("parallel_ka_run: rshp -v $parallel->{options} -- urpmi --no-locales --test --no-verify-rpm --auto --synthesis $parallel->{synthesis} $parallel->{line}");
    open F, "rshp -v $parallel->{options} -- urpmi --no-locales --test --no-verify-rpm --auto --synthesis $parallel->{synthesis} $parallel->{line} |";
    while (defined ($_ = <F>)) {
	chomp;
	s/<([^>]*)>.*:->:(.*)/$2/ and $node = $1;
	/^\s*$/ and next;
	$bad_nodes{$node} .= $_;
	/Installation failed/ and $bad_nodes{$node} = '';
	/Installation is possible/ and delete $bad_nodes{$node};
    }
    close F or $urpm->{fatal}(1, _("rshp failed"));

    foreach (keys %{$parallel->{nodes}}) {
	exists $bad_nodes{$_} or next;
	$urpm->{error}(_("Installation failed on node %s", $_) . ":\n" . $bad_nodes{$_});
    }
    %bad_nodes and return;

    #- continue installation.
    $urpm->{log}("parallel_ka_run: rshp $parallel->{options} -- urpmi --no-locales --no-verify-rpm --auto --synthesis $parallel->{synthesis} $parallel->{line}");
    system("rshp $parallel->{options} -- urpmi --no-locales --no-verify-rpm --auto --synthesis $parallel->{synthesis} $parallel->{line}") == 0;
}


#- allow bootstrap from urpmi code directly (namespace is urpm).
package urpm;
sub handle_parallel_options {
    my ($urpm, $options) = @_;
    my ($media, $ka_run_options) = $options =~ /ka-run(?:\(([^\)]*)\))?:(.*)/;

    if ($ka_run_options) {
	my ($flush_nodes, %nodes);

	foreach (split ' ', $ka_run_options) {
	    if ($_ eq '-m') {
		$flush_nodes = 1;
	    } else {
		$flush_nodes and $nodes{/host=([^,]*)/ ? $1 : $_} = undef;
		undef $flush_nodes;
	    }
	}

	return bless {
		      media   => $media,
		      options => $ka_run_options,
		      nodes   => \%nodes,
		     }, "urpm::parallel_ka_run";
    }

    return undef;
}

1;
