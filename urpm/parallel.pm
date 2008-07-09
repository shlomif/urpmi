package urpm::parallel; # $Id$

use urpm;
use urpm::util;
use urpm::msg;


sub configure {
    my ($urpm, $alias) = @_;
    my @parallel_options;
    #- read parallel configuration
    foreach (cat_("/etc/urpmi/parallel.cfg")) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	/\s*([^:]*):(.*)/ or $urpm->{error}(N("unable to parse \"%s\" in file [%s]", $_, "/etc/urpmi/parallel.cfg")), next;
	$1 eq $alias and push @parallel_options, $2;
    }
    #- if a configuration option has been found, use it; else fatal error.
    my $parallel_handler;
    if (@parallel_options) {
	foreach my $dir (grep { -d $_ } map { "$_/urpm" } @INC) {
	    foreach my $pm (grep { -f $_ } glob("$dir/parallel*.pm")) {
		#- load parallel modules
		$urpm->{log}->(N("examining parallel handler in file [%s]", $pm));
		# perl_checker: require urpm::parallel_ka_run
		# perl_checker: require urpm::parallel_ssh
		eval { require $pm; $parallel_handler = $urpm->handle_parallel_options(join("\n", @parallel_options)) };
		$parallel_handler and last;
	    }
	    $parallel_handler and last;
	}
    }
    if ($parallel_handler) {
	if ($parallel_handler->{nodes}) {
	    $urpm->{log}->(N("found parallel handler for nodes: %s", join(', ', keys %{$parallel_handler->{nodes}})));
	}
	$urpm->{parallel_handler} = $parallel_handler;
    } else {
	$urpm->{fatal}(1, N("unable to use parallel option \"%s\"", $alias));
    }
}

sub resolve_dependencies {
    my ($urpm, $state, $requested, %options) = @_;

    #- build the global synthesis file first.
    my $file = "$urpm->{cachedir}/partial/parallel.cz";
    unlink $file;
    foreach (@{$urpm->{media}}) {
	urpm::media::is_valid_medium($_) or next;
	my $f = urpm::media::any_synthesis($urpm, $_);
	system "cat '$f' >> '$file'";
    }
    #- let each node determine what is requested, according to handler given.
    $urpm->{parallel_handler}->parallel_resolve_dependencies($file, $urpm, $state, $requested, %options);
}

#- remove packages from node as remembered according to resolving done.
sub remove {
    my ($urpm, $remove, %options) = @_;
    my $state = {};
    my $callback = sub { $urpm->{fatal}(1, "internal distributed remove fatal error") };
    $urpm->{parallel_handler}->parallel_find_remove($urpm, $state, $remove, %options,
						    callback_notfound => undef,
						    callback_fuzzy => $callback,
						    callback_base => $callback,
						   );
}

sub post_register_rpms {
    my ($parallel, $urpm, @files) = @_;

    #- keep trace of direct files.
    $parallel->{line} .= 
      join(' ',
	   map { "'$_'" }
	   map { "$urpm->{cachedir}/rpms/" . basename($_) } @files);
}

sub find_remove_pre {
    my ($urpm, $state, %options) = @_;

    #- keep in mind if the previous selection is still active, it avoids
    #- to re-start urpme --test on each node.
    if ($options{find_packages_to_remove}) {
	delete $state->{rejected};
	delete $urpm->{error_remove};
	'--test ';
    } elsif (@{$urpm->{error_remove} || []}) {
	undef, $urpm->{error_remove};
    } elsif ($options{test}) {
	#- no need to restart what has been started before.
	undef, [ keys %{$state->{rejected}} ];
    } else {
	'--force ';
    }
}

sub parse_urpme_output {
    my ($urpm, $state, $node, $s, $notfound, $base_to_remove, $bad_nodes, %options) = @_;

    $s =~ /^\s*$/ and return;
    $s =~ /Checking to remove the following packages/ and return;

    $s =~ /To satisfy dependencies, the following packages are going to be removed/
      and $urpm->{fatal}(1, N("node %s has an old version of urpme, please upgrade", $node));

    if ($s =~ /unknown packages?:? (.*)/) {
	#- remember unknown packages from the node, because it should not be a fatal error
	#- if other nodes have it.
	$notfound->{$_} = undef foreach split ", ", $1;
    } elsif ($s =~ /The following packages contain ([^:]*): (.*)/) {
	$options{callback_fuzzy} && $options{callback_fuzzy}->($urpm, $1, split(" ", $2))
	  or delete($state->{rejected}), return 'stop_parse';
    } elsif ($s =~ /removing package (.*) will break your system/) {
	$base_to_remove->{$1} = undef;
    } elsif ($s =~ /removing \S/) {
	#- this is log for newer urpme, so do not try to remove removing...
    } elsif ($s =~ /Remov(?:al|ing) failed/) {
	$bad_nodes->{$node} = [];
    } else {
	if (exists $bad_nodes->{$node}) {
	    $s =~ /^\s+(.+)/ and push @{$bad_nodes->{$node}}, $1;
	} else {
	    $s =~ s/\s*\(.*//; #- remove reason (too complex to handle, needs to be removed)
	    $state->{rejected}{$s}{removed} = 1;
	    $state->{rejected}{$s}{nodes}{$node} = undef;
	}
    }
    return;
}

#- compute command line of urpm? tools.
sub simple_resolve_dependencies {
    my ($parallel, $urpm, $state, $requested, %options) = @_;

    my @pkgs;
    foreach (keys %$requested) {
	if (/\|/) {
	    #- taken from URPM::Resolve to filter out choices, not complete though.
	    my $packages = $urpm->find_candidate_packages($_);
	    foreach (values %$packages) {
		my ($best_requested, $best);
		foreach (@$_) {
		    exists $state->{selected}{$_->id} and $best_requested = $_, last;
		    if ($best_requested) {
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
	    #- simplified choice resolution.
	    my $choice = $options{callback_choices}->($urpm, undef, $state, [ values %$packages ]);
	    if ($choice) {
		push @pkgs, $choice;
	    }
	} else {
	    my $pkg = $urpm->{depslist}[$_] or next;
	    push @pkgs, $pkg;
	}
    }
    #- local packages have already been added.
    @pkgs = grep { !$urpm->{source}{$_->id} } @pkgs;

    $parallel->{line} . 
	($options{auto_select} ? ' --auto-select' : '') . 
	($options{keep} ? ' --keep' : '') .
	join(' ', map { scalar $_->fullname } @pkgs);
}

1;
