package urpm::bug_report; # $Id$

use urpm;
use urpm::msg;


sub rpmdb_to_synthesis {
    my ($urpm, $synthesis, $root) = @_;

    my $db = urpm::db_open_or_die($urpm, $root);
    my $sig_handler = sub { undef $db; exit 3 };
    local $SIG{INT} = $sig_handler;
    local $SIG{QUIT} = $sig_handler;

    open my $rpmdb, "| " . ($ENV{LD_LOADER} || '') . " gzip -9 >'$synthesis'"
      or urpm::sys::syserror($urpm, "Can't fork", "gzip");
    $db->traverse(sub {
		      my ($p) = @_;
		      #- this is not right but may be enough.
		      my $files = join '@', grep { exists($urpm->{provides}{$_}) } $p->files;
		      $p->pack_header;
		      $p->build_info(fileno $rpmdb, $files);
		  });
    close $rpmdb;
}

sub write_urpmdb {
    my ($urpm, $bug_report_dir) = @_;

    require URPM::Build;
    foreach (@{$urpm->{media}}) {
	#- take care of virtual medium this way.
	#- now build directly synthesis file, this is by far the simplest method.
	if (urpm::media::is_valid_medium($_)) {
	    $urpm->build_synthesis(start => $_->{start}, end => $_->{end}, synthesis => "$bug_report_dir/synthesis." . urpm::media::_hdlist($_));
	    $urpm->{log}(N("built hdlist synthesis file for medium \"%s\"", $_->{name}));
	}
    }
    #- fake configuration written to convert virtual media on the fly.
    local $urpm->{config} = "$bug_report_dir/urpmi.cfg";
    urpm::media::write_config($urpm);
}

sub copy_requested {
    my ($urpm, $bug_report_dir, $requested) = @_;

    #- handle local packages, copy them directly in bug environment.
    foreach (keys %$requested) {
	if ($urpm->{source}{$_}) {
	    system "cp", "-af", $urpm->{source}{$_}, $bug_report_dir
		and die N("Copying failed");
	}
    }
}

1;
