package urpm::md5sum; # $Id$

use urpm;
use urpm::util;
use urpm::msg;

sub parse {
    my ($md5sum_file) = @_;

    my %h = map {
	my ($md5sum, $file) = m|^([0-9-a-f]+)\s+(?:\./)?(\S+)$|i or return;
	$file => $md5sum;
    } cat_($md5sum_file) or return;

    \%h;
}

sub check_file {
    my ($md5sum_file) = @_;

    file_size($md5sum_file) > 32 && parse($md5sum_file);
}

sub from_MD5SUM__or_warn {
    my ($urpm, $md5sums, $basename) = @_;
    $md5sums->{$basename} or $urpm->{log}(N("warning: md5sum for %s unavailable in MD5SUM file", $basename));
    $md5sums->{$basename};
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
