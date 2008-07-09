package urpm::parallel_ssh;

# $Id$

#- Copyright (C) 2002, 2003, 2004, 2005 MandrakeSoft SA
#- Copyright (C) 2005 Mandriva SA

use strict;
use urpm::util;
use urpm::msg;
use urpm::parallel;

our @ISA = (); #- help perl_checker

(our $VERSION) = q($Revision$) =~ /(\d+)/;

sub _localhost { $_[0] eq 'localhost' }
sub _nolock    { &_localhost ? '--nolock ' : '' }
sub _ssh       { &_localhost ? '' : "ssh $_[0] " }
sub _host      { &_localhost ? '' : "$_[0]:" }

sub _scp {
    my ($urpm, $host, @para) = @_;
    my $dest = pop @para;

    $urpm->{log}("parallel_ssh: scp " . join(' ', @para) . " $host:$dest");
    system('scp', @para, _host($host) . $dest) == 0
      or $urpm->{fatal}(1, N("scp failed on host %s (%d)", $host, $? >> 8));
}

sub _scp_rpms {
    my ($parallel, $urpm, @files) = @_;

    foreach my $host (keys %{$parallel->{nodes}}) {
	if (_localhost($host)) {
	    if (my @f = grep { dirname($_) ne "$urpm->{cachedir}/rpms" } @files) {
		$urpm->{log}("parallel_ssh: cp @f $urpm->{cachedir}/rpms");
		system('cp', @f, "$urpm->{cachedir}/rpms") == 0
		  or $urpm->{fatal}(1, N("cp failed on host %s (%d)", $host, $? >> 8));
	    }
	} else {
	    _scp($urpm, $host, @files, "$urpm->{cachedir}/rpms");
	}
    }
}

sub _ssh_urpm {
    my ($urpm, $node, $cmd, $para) = @_;
    my $command = _ssh($node) . " $cmd --no-locales $para";
    $urpm->{log}("parallel_ssh: $command");
    $command;
}

#- parallel copy
sub parallel_register_rpms {
    my ($parallel, $urpm, @files) = @_;

    _scp_rpms($parallel, $urpm, @files);
    urpm::parallel::post_register_rpms($parallel, $urpm, @files);
}

#- parallel find_packages_to_remove
sub parallel_find_remove {
    my ($parallel, $urpm, $state, $l, %options) = @_;

    my ($test, $pkgs) = urpm::parallel::find_remove_pre($urpm, $state, %options);
    $pkgs and return @$pkgs;

    my (%bad_nodes, %base_to_remove, %notfound);

    #- now try an iteration of urpme.
    foreach my $node (keys %{$parallel->{nodes}}) {
	my $command = _ssh_urpm($urpm, $node, 'urpme', "--auto $test" . join(' ', map { "'$_'" } @$l));
	open my $fh, "$command 2>&1 |"
	    or $urpm->{fatal}(1, "Can't fork ssh: $!");

	while (my $s = <$fh>) {
	    urpm::parallel::parse_urpme_output($urpm, $state, $node, $s, 
					       \%notfound, \%base_to_remove, \%bad_nodes, %options)
		or last;
	}
	close $fh;
    }

    #- check base, which has been delayed until there.
    if ($options{callback_base} && %base_to_remove) {
	$options{callback_base}->($urpm, keys %base_to_remove) or return ();
    }

    #- build error list contains all the error returned by each node.
    $urpm->{error_remove} = [ map {
	my $msg = N("on node %s", $_);
	map { "$msg, $_" } @{$bad_nodes{$_}};
    } keys %bad_nodes ];

    #- if at least one node has the package, it should be seen as unknown...
    delete @notfound{map { /^(.*)-[^-]*-[^-]*$/ } keys %{$state->{rejected}}};
    if (%notfound) {
	$options{callback_notfound} && $options{callback_notfound}->($urpm, keys %notfound)
	  or delete $state->{rejected};
    }

    keys %{$state->{rejected}};
}

#- parallel resolve_dependencies
sub parallel_resolve_dependencies {
    my ($parallel, $synthesis, $urpm, $state, $requested, %options) = @_;

    #- first propagate the synthesis file to all machines
    foreach (grep { !_localhost($_) } keys %{$parallel->{nodes}}) {
	_scp($urpm, $_, '-q', $synthesis, $synthesis);
    }
    $parallel->{synthesis} = $synthesis;

    my $line = urpm::parallel::simple_resolve_dependencies($parallel, $urpm, $state, $requested, %options);

    #- execute urpmq to determine packages to install.
    my ($cont, %chosen);
    local $_;
    do {
	$cont = 0; #- prepare to stop iteration.
	#- the following state should be cleaned for each iteration.
	delete $state->{selected};
	#- now try an iteration of urpmq.
	foreach my $node (keys %{$parallel->{nodes}}) {
	    my $command = _ssh_urpm($urpm, $node, "urpmq", _nolock($node) . "--synthesis $synthesis -fduc $line " . join(' ', keys %chosen));
	    open my $fh, "$command |"
		or $urpm->{fatal}(1, "Can't fork ssh: $!");
	    while (defined ($_ = <$fh>)) {
		chomp;
		urpm::parallel::parse_urpmq_output($urpm, $state, $node, $_, \$cont, \%chosen, %options);
	    }
	    close $fh or $urpm->{fatal}(1, N("host %s does not have a good version of urpmi (%d)", $node, $? >> 8));
	}
	#- check for internal error of resolution.
	$cont == 1 and die "internal distant urpmq error on choice not taken";
    } while $cont;

    #- keep trace of what has been chosen finally (if any).
    $parallel->{line} = join(' ', $line, keys %chosen);
}

#- parallel install.
sub parallel_install {
    my ($parallel, $urpm, undef, $install, $upgrade, %options) = @_;

    _scp_rpms($parallel, $urpm, values %$install, values %$upgrade);

    my %bad_nodes;
    foreach my $node (keys %{$parallel->{nodes}}) {
	local $_;
	my $command = _ssh_urpm($urpm, $node, 'urpmi', "--pre-clean --test --no-verify-rpm --auto " . _nolock($node) . "--synthesis $parallel->{synthesis} $parallel->{line}");
	open my $fh, "$command |"
	    or $urpm->{fatal}(1, "Can't fork ssh: $!");
	while ($_ = <$fh>) {
	    $bad_nodes{$node} .= $_;
	    /Installation failed/ and $bad_nodes{$node} = '';
	    /Installation is possible/ and delete $bad_nodes{$node}, last;
	}
	close $fh;
    }
    foreach (keys %{$parallel->{nodes}}) {
	exists $bad_nodes{$_} or next;
	$urpm->{error}(N("Installation failed on node %s", $_) . ":\n" . $bad_nodes{$_});
    }
    %bad_nodes and return;

    if ($options{test}) {
	$urpm->{error}(N("Installation is possible"));
	1;
    } else {
	my $line = $parallel->{line} . ($options{excludepath} ? " --excludepath $options{excludepath}" : "");
	#- continue installation on each node
	foreach my $node (keys %{$parallel->{nodes}}) {
	    my $command = _ssh_urpm($urpm, $node, 'urpmi', "--no-verify-rpm --auto " . _nolock($node) . "--synthesis $parallel->{synthesis} $line");
	    open my $fh, "$command |"
		or $urpm->{fatal}(1, "Can't fork ssh: $!");
            local $/ = \1;
	    local $_;
            while (<$fh>) {
                print;
            }
            close $fh;
	}
    }
}

#- allow to bootstrap from urpmi code directly (namespace is urpm).

package urpm;

no warnings 'redefine';

sub handle_parallel_options {
    my (undef, $options) = @_;
    my ($id, @nodes) = split /:/, $options;

    if ($id =~ /^ssh(?:\(([^\)]*)\))?$/) {
	my %nodes; @nodes{@nodes} = undef;
	return bless {
	    media   => $1,
	    nodes   => \%nodes,
	}, "urpm::parallel_ssh";
    }
    return undef;
}

1;
