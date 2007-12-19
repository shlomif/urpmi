package urpm::md5sum; # $Id$

use urpm;
use urpm::util;
use urpm::msg;


#- parse an MD5SUM file from a mirror
sub from_MD5SUM {
    my ($md5sum_file, $f) = @_;  
    my $basename = basename($f);

    my ($retrieved_md5sum) = map {
	my ($md5sum, $file) = m|(\S+)\s+(?:\./)?(\S+)|;
	$file && $file eq $basename ? $md5sum : @{[]};
    } cat_($md5sum_file);

    $retrieved_md5sum;
}

sub from_MD5SUM__or_warn {
    my ($urpm, $md5sum_file, $basename) = @_;
    $urpm->{log}(N("examining %s file", $md5sum_file));
    my $retrieved_md5sum = from_MD5SUM($md5sum_file, $basename) 
      or $urpm->{log}(N("warning: md5sum for %s unavailable in MD5SUM file", $basename));
    return $retrieved_md5sum;
}

sub on_local_medium {
    my ($urpm, $medium, $force) = @_;
    if ($force) {
	#- force downloading the file again, else why a force option has been defined ?
	delete $medium->{md5sum};
    } else {
	$medium->{md5sum} ||= compute_on_local_medium($urpm, $medium);
    }
    $medium->{md5sum};
}

sub compute_on_local_medium {
    my ($urpm, $medium) = @_;

    require urpm::media; #- help perl_checker
    my $f = urpm::media::statedir_synthesis($urpm, $medium);
    $urpm->{log}(N("computing md5sum of existing source synthesis [%s]", $f));
    -e $f && compute($f);
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
