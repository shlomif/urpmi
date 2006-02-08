package urpm::msg;

use strict;
no warnings;
use Exporter;

(our $VERSION) = q$Id$ =~ /(\d+\.\d+)/;

our @ISA = 'Exporter';
our @EXPORT = qw(N bug_log to_utf8 message_input toMb from_utf8 sys_log);

#- I18N.
use Locale::gettext;
use POSIX qw(LC_ALL);
POSIX::setlocale(LC_ALL, "");
Locale::gettext::textdomain("urpmi");

my $codeset; #- encoding of the current locale
eval {
    require I18N::Langinfo;
    I18N::Langinfo->import(qw(langinfo CODESET));
    $codeset = langinfo(CODESET()); # note the ()
};
defined $codeset or eval {
    (undef, $codeset) = `/usr/bin/locale -c charmap`;
    chomp $codeset;
};

sub from_utf8_full { Locale::gettext::iconv($_[0], "UTF-8", $codeset) }
sub from_utf8_dummy { $_[0] }

our $use_utf8_full = defined $codeset && $codeset eq 'UTF-8';

*from_utf8 = $use_utf8_full ? *from_utf8_full : *from_utf8_dummy;

sub N {
    my ($format, @params) = @_;
    my $s = sprintf(
	eval { Locale::gettext::gettext($format || '') } || $format,
	@params,
    );
    utf8::decode($s) unless $use_utf8_full;
    $s;
}

my $noexpr = N("Nn");
my $yesexpr = N("Yy");

eval {
    require Sys::Syslog;
    Sys::Syslog->import();
    (my $tool = $0) =~ s!.*/!!;
    openlog($tool, '', 'user');
    END { closelog() }
};

sub sys_log { defined &syslog and syslog("info", @_) }

#- writes only to logfile, not to screen
sub bug_log {
    if ($::logfile) {
	open my $fh, ">>$::logfile"
	    or die "Can't output to log file [$::logfile]: $!\n";
	print $fh @_;
	close $fh;
    }
}

sub to_utf8 { Locale::gettext::iconv($_[0], undef, "UTF-8") }

sub message_input {
    my ($msg, $default_input, %opts) = @_;
    my $input;
    while (1) {
	if ($urpm::args::options{bug} || !defined fileno ::SAVEOUT) {
	    print STDOUT $msg;
	} else {
	    print ::SAVEOUT $msg;
	}
	if ($default_input) {
	    $urpm::args::options{bug} and bug_log($default_input);
	    return $default_input;
	}
	$input = <STDIN>;
	defined $input or return undef;
	chomp $input;
	$urpm::args::options{bug} and bug_log($input);
	if ($opts{boolean}) {
	    $input =~ /^[$noexpr$yesexpr]?$/ and last;
	} elsif ($opts{range}) {
	    $input eq "" and $input = 1; #- defaults to first choice
	    (defined $opts{range_min} ? $opts{range_min} : 1) <= $input && $input <= $opts{range} and last;
	} else {
	    last;
	}
	print N("Sorry, bad choice, try again\n");
    }
    return $input;
}

sub toMb {
    my $nb = $_[0] / 1024 / 1024;
    int $nb + 0.5;
}

sub localtime2changelog { scalar(localtime($_[0])) =~ /(.*) \S+ (\d{4})$/ && "$1 $2" }

1;

__END__

=head1 NAME

urpm::msg - routines to prompt messages from the urpm* tools

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 COPYRIGHT

Copyright (C) 2000, 2001, 2002, 2003, 2004, 2005 MandrakeSoft SA

Copyright (C) 2005, 2006 Mandriva SA

=cut
