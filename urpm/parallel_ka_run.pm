package urpm::parallel_ka_run;

# $Id$

#- Copyright (C) 2002, 2003, 2004, 2005 MandrakeSoft SA
#- Copyright (C) 2005 Mandriva SA

use strict;
use urpm::util;
use urpm::msg;
use urpm::parallel;

our @ISA = (); #- help perl_checker

(our $VERSION) = q($Revision$) =~ /(\d+)/;
our $mput_command = $ENV{URPMI_MPUT_COMMAND};
our $rshp_command = $ENV{URPMI_RSHP_COMMAND};

if (!$mput_command) {
    ($mput_command) = grep { -x $_ } qw(/usr/bin/mput2 /usr/bin/mput);
}
$mput_command ||= 'mput';
if (!$rshp_command) {
    ($rshp_command) = grep { -x $_ } qw(/usr/bin/rshp2 /usr/bin/rshp);
}
$rshp_command ||= 'rshp';

sub rshp_command {
    my ($urpm, $parallel, $rshp_option, $para) = @_;

    my $cmd = "$rshp_command $rshp_option $parallel->{options} -- $para";
    $urpm->{log}("parallel_ka_run: $cmd");
    $cmd;
}

sub run_mput {
    my ($urpm, $parallel, @para) = @_;

    my @l = (split(' ', $parallel->{options}), '--', @para);
    $urpm->{log}("parallel_ka_run: $mput_command " . join(' ', @l));
    system $mput_command, @l;
}    

#- parallel copy
sub parallel_register_rpms {
    my ($parallel, $urpm, @files) = @_;

    run_mput($urpm, $parallel, @files, "$urpm->{cachedir}/rpms/");
    $? == 0 || $? == 256 or $urpm->{fatal}(1, N("mput failed, maybe a node is unreacheable"));

    urpm::parallel::post_register_rpms($parallel, $urpm, @files);
}

#- parallel find_packages_to_remove
sub parallel_find_remove {
    my ($parallel, $urpm, $state, $l, %options) = @_;

    my ($test, $pkgs) = urpm::parallel::find_remove_pre($urpm, $state, %options);
    $pkgs and return @$pkgs;

    my (%bad_nodes, %base_to_remove, %notfound);

    #- now try an iteration of urpme.
    my $command = rshp_command($urpm, $parallel, "-v", "urpme --no-locales --auto $test" . join(' ', map { "'$_'" } @$l));
    open my $fh, "$command 2>&1 |";

    while (my $s = <$fh>) {
	my ($node, $s_) = _parse_rshp_output($s) or next;

	urpm::parallel::parse_urpme_output($urpm, $state, $node, $s_, 
					   \%notfound, \%base_to_remove, \%bad_nodes, %options)
	    or last;
    }
    close $fh or $urpm->{fatal}(1, N("rshp failed, maybe a node is unreacheable"));

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
    run_mput($urpm, $parallel, $synthesis, $synthesis);
    $? == 0 || $? == 256 or $urpm->{fatal}(1, N("mput failed, maybe a node is unreacheable"));
    $parallel->{synthesis} = $synthesis;

    my $line = urpm::parallel::simple_resolve_dependencies($parallel, $urpm, $state, $requested, %options);

    #- execute urpmq to determine packages to install.
    my ($cont, %chosen);
    do {
	$cont = 0; #- prepare to stop iteration.
	#- the following state should be cleaned for each iteration.
	delete $state->{selected};
	#- now try an iteration of urpmq.
	open my $fh, rshp_command($urpm, $parallel, "-v", "urpmq --synthesis $synthesis -fduc $line " . join(' ', keys %chosen)) . " |";
	while (my $s = <$fh>) {
	    chomp $s;
	    my ($node, $s_) = _parse_rshp_output($s) or next;
	    urpm::parallel::parse_urpmq_output($urpm, $state, $node, $s_, \$cont, \%chosen, %options);
	}
	close $fh or $urpm->{fatal}(1, N("rshp failed, maybe a node is unreacheable"));
	#- check for internal error of resolution.
	$cont == 1 and die "internal distant urpmq error on choice not taken";
    } while $cont;

    #- keep trace of what has been chosen finally (if any).
    $parallel->{line} = join(' ', $line, keys %chosen);
}

#- parallel install.
sub parallel_install {
    my ($parallel, $urpm, undef, $install, $upgrade, %options) = @_;

    run_mput($urpm, $parallel, values %$install, values %$upgrade, "$urpm->{cachedir}/rpms/");
    $? == 0 || $? == 256 or $urpm->{fatal}(1, N("mput failed, maybe a node is unreacheable"));

    local $_;
    my ($node, %bad_nodes);
    open my $fh, rshp_command($urpm, $parallel, "-v", "urpmi --pre-clean --no-locales --test --no-verify-rpm --auto --synthesis $parallel->{synthesis} $parallel->{line}") . ' |';
    while (<$fh>) {
	chomp;
	($node, $_) = _parse_rshp_output($_) or next;
	/^\s*$/ and next;
	$bad_nodes{$node} .= $_;
	/Installation failed/ and $bad_nodes{$node} = '';
	/Installation is possible/ and delete $bad_nodes{$node};
    }
    close $fh or $urpm->{fatal}(1, N("rshp failed, maybe a node is unreacheable"));

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
	#- continue installation.
	system(rshp_command($urpm, $parallel, '', "urpmi --no-locales --no-verify-rpm --auto --synthesis $parallel->{synthesis} $line")) == 0;
    }
}

sub _parse_rshp_output {
    my ($s) = @_;
    #- eg of output of rshp2: <tata2.mandriva.com> [rank:2]:@removing@mpich-1.2.5.2-10mlcs4.x86_64

    if ($s =~ /<([^>]*)>.*:->:(.*)/ || $s =~ /<([^>]*)>\s*\[[^]]*\]:(.*)/) {
	($1, $2);
    } else { 
	warn "bad rshp output $s\n";
	();
    }
}

#- allow to bootstrap from urpmi code directly (namespace is urpm).

package urpm;

no warnings 'redefine';

sub handle_parallel_options {
    my (undef, $options) = @_;
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
