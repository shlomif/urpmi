package urpm::md5sum; # $Id$

use urpm;
use urpm::util;
use urpm::msg;

sub parse {
    my ($md5sum_file) = @_;

    my %h = map {
	my ($md5sum, $file) = m|(\S+)\s+(?:\./)?(\S+)|;
	$file => $md5sum;
    } cat_($md5sum_file);

    \%h;
}

sub from_MD5SUM__or_warn {
    my ($urpm, $md5sum_file, $basename) = @_;
    $urpm->{debug}(N("examining %s file", $md5sum_file)) if $urpm->{debug};
    my $retrieved_md5sum = parse($md5sum_file)->{$basename} 
      or $urpm->{log}(N("warning: md5sum for %s unavailable in MD5SUM file", $basename));
    return $retrieved_md5sum;
}

sub compute {
    my ($file) = @_;
    eval { require Digest::MD5 };
    if ($@) {
	#- Use an external command to avoid depending on perl
	return (split ' ', `/usr/bin/md5sum '$file'`)[0];
    } else {
	my $ctx = Digest::MD5->new;
	open my $fh, $file or return '';
	$ctx->addfile($fh);
	close $fh;
	return $ctx->hexdigest;
    }
}

1;
