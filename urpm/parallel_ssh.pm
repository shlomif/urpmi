package urpm::parallel_ssh;

#- parallel resolve_dependencies
sub parallel_resolve_dependencies {
    my ($parallel, $synthesis, $urpm, $state, $requested, %options) = @_;

    #- first propagate the synthesis file to all machine.
    foreach (keys %{$parallel->{nodes}}) {
	$urpm->{log}("parallel_ssh: scp '$synthesis' '$_:$synthesis'");
	system "scp '$synthesis' '$_:$synthesis'";
    }
    $parallel->{synthesis} = $synthesis;

    #- compute command line of urpm? tools.
    my $line = $options{auto_select} ? ' --auto-select' : '';
    foreach (keys %$requested) {
	if (/\|/) {
	    #- simplified choices resolution.
	    my $choice = $options{callback_choices}->($urpm, undef, $state, [ map { /^\d+$/ ?
										      $urpm->{depslist}[$_] :
											$urpm->search($_) } split '\|', $_ ]);
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
	foreach my $node (keys %{$parallel->{nodes}}) {
	    $urpm->{log}("parallel_ssh: ssh $node urpmq --synthesis $synthesis -f $line ".join(' ', keys %chosen));
	    open F, "ssh $node urpmq --synthesis $synthesis -fdu $line ".join(' ', keys %chosen)." |";
	    while ($_ = <F>) {
		chomp;
		if (/\|/) {
		    #- distant urpmq returned a choices, check if it has already been chosen
		    #- or continue iteration to make sure no more choices are left.
		    $cont ||= 1; #- invalid transitory state (still choices is strange here if next sentence is not executed).
		    unless (grep { exists $chosen{$_} } split '\|', $_) {
			#- it has not yet been chosen so need to ask user.
			$cont = 2;
			my $choice = $options{callback_choices}->($urpm, undef, $state, [ map { $urpm->search($_) } split '\|', $_ ]);
			$chosen{scalar $choice->fullname} = $choice;
		    }
		} else {
		    my $pkg = $urpm->search($_) or next; #TODO
		    $state->{selected}{$pkg->id}{$node} = $_;
		}
	    }
	    close F or $urpm->{fatal}(1, _("host %s does not have a good version of urpmi", $node));
	}
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

    foreach (keys %{$parallel->{nodes}}) {
	my $sources = join ' ', map { "'$_'" } values %$install, values %$upgrade;
	$urpm->{log}("parallel_ssh: scp $sources $_:$urpm->{cachedir}/rpms");
	system "scp $sources $_:$urpm->{cachedir}/rpms";
    }

    foreach (keys %{$parallel->{nodes}}) {
	$urpm->{log}("parallel_ssh: ssh $_ urpmi --auto --synthesis $parallel->{synthesis} $parallel->{line}");
	system "ssh $_ urpmi --auto --synthesis $parallel->{synthesis} $parallel->{line}";
    }
}


#- allow bootstrap from urpmi code directly (namespace is urpm).
package urpm;
sub handle_parallel_options {
    my ($urpm, $options) = @_;
    my ($id, @nodes) = split ':', $options;

    if ($id eq 'ssh') {
	my %nodes; @nodes{@nodes} = undef;

	return bless {
		      nodes   => \%nodes,
		     }, "urpm::parallel_ssh";
    }

    return undef;
}

1;
