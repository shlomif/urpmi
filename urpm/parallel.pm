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

1;
