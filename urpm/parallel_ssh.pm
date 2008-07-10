package urpm::parallel_ssh;

# $Id$

#- Copyright (C) 2002, 2003, 2004, 2005 MandrakeSoft SA
#- Copyright (C) 2005 Mandriva SA

use strict;
use urpm::util;
use urpm::msg;
use urpm::parallel;

our @ISA = 'urpm::parallel';

(our $VERSION) = q($Revision$) =~ /(\d+)/;

sub _localhost { $_[0] eq 'localhost' }
sub _ssh       { &_localhost ? '' : "ssh $_[0] " }
sub _host      { &_localhost ? '' : "$_[0]:" }

sub _scp {
    my ($urpm, $host, @para) = @_;
    my $dest = pop @para;

    $urpm->{log}("parallel_ssh: scp " . join(' ', @para) . " $host:$dest");
    system('scp', @para, _host($host) . $dest) == 0
      or $urpm->{fatal}(1, N("scp failed on host %s (%d)", $host, $? >> 8));
}

sub copy_to_dir {
    my ($parallel, $urpm, @para) = @_;
    my $dir = pop @para;

    foreach my $host (keys %{$parallel->{nodes}}) {
	if (_localhost($host)) {
	    if (my @f = grep { dirname($_) ne $dir } @para) {
		$urpm->{log}("parallel_ssh: cp @f $urpm->{cachedir}/rpms");
		system('cp', @f, $dir) == 0
		  or $urpm->{fatal}(1, N("cp failed on host %s (%d)", $host, $? >> 8));
	    }
	} else {
	    _scp($urpm, $host, @para, $dir);
	}
    }
}

sub propagate_file {
    my ($parallel, $urpm, $file) = @_;
    foreach (grep { !_localhost($_) } keys %{$parallel->{nodes}}) {
	_scp($urpm, $_, '-q', $file, $file);
    }
}

sub _ssh_urpm {
    my ($urpm, $node, $cmd, $para) = @_;

    $cmd ne 'urpme' && _localhost($node) and $para = "--nolock $para";

    my $command = _ssh($node) . " $cmd --no-locales $para";
    $urpm->{log}("parallel_ssh: $command");
    $command;
}
sub _ssh_urpm_popen {
    my ($urpm, $node, $cmd, $para) = @_;

    my $command = _ssh_urpm($urpm, $node, $cmd, $para);
    open(my $fh, "$command |") or $urpm->{fatal}(1, "Can't fork ssh: $!");
    $fh;
}

sub urpm_popen {
    my ($parallel, $urpm, $cmd, $para, $do) = @_;

    foreach my $node (keys %{$parallel->{nodes}}) {
	my $fh = _ssh_urpm_popen($urpm, $node, $cmd, $para);

	while (my $s = <$fh>) {
	    $do->($node, $s) or last;
	}
	close $fh or $urpm->{fatal}(1, N("host %s does not have a good version of urpmi (%d)", $node, $? >> 8));
    }
}

#- parallel install.
sub parallel_install {
    my ($parallel, $urpm, undef, $install, $upgrade, %options) = @_;

    copy_to_dir($parallel, $urpm, values %$install, values %$upgrade, "$urpm->{cachedir}/rpms");

    my (%bad_nodes, @good_nodes);
    $parallel->urpm_popen($urpm, 'urpmi', "--pre-clean --test --no-verify-rpm --auto --synthesis $parallel->{synthesis} $parallel->{line}", sub {
	my ($node, $s) = @_;
	$s =~ /^\s*$/ and return;
	$bad_nodes{$node} .= $s;
	$s =~ /Installation failed/ and $bad_nodes{$node} = '';
	$s =~ /Installation is possible/ and push @good_nodes, $node;
	undef;
    });
    delete $bad_nodes{$_} foreach @good_nodes;

    foreach (keys %{$parallel->{nodes}}) {
	exists $bad_nodes{$_} or next;
	$urpm->{error}(N("Installation failed on node %s", $_) . ":\n" . $bad_nodes{$_});
    }
    %bad_nodes and return;

    if ($options{test}) {
	$urpm->{error}(N("Installation is possible"));
	1;
    } else {
	my $line = $parallel->{line} . ($options{excludepath} ? " --excludepath '$options{excludepath}'" : "");
	#- continue installation on each node
	foreach my $node (keys %{$parallel->{nodes}}) {
	    my $command = _ssh_urpm($urpm, $node, 'urpmi', "--no-verify-rpm --auto --synthesis $parallel->{synthesis} $line");
	    system($command);
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
