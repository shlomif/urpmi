package urpm::msg;

use strict;
use Exporter;
our @ISA = 'Exporter';
our @EXPORT = qw(N log_it to_utf8 message_input message toMb from_utf8);

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

sub from_utf8_full { Locale::gettext::iconv($_[0], "UTF-8", $codeset) }
sub from_utf8_dummy { $_[0] }

*from_utf8 = defined $codeset ? *from_utf8_full : *from_utf8_dummy;

sub N {
    my ($format, @params) = @_;
    sprintf(
	eval { Locale::gettext::gettext($format || '') } || $format,
	@params,
    );
}

my $noexpr = N("Nn");
my $yesexpr = N("Yy");

sub log_it {
    #- if invoked as a simple user, nothing should be logged.
    if ($::log) {
	open my $fh, ">>$::log" or die "can't output to log file: $!\n";
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
	    $urpm::args::options{bug} and log_it($default_input);
	    return $default_input;
	}
	$input = <STDIN>;
	defined $input or return undef;
	chomp $input;
	$urpm::args::options{bug} and log_it($input);
	if ($opts{boolean}) {
	    $input =~ /^[$noexpr$yesexpr]?$/ and last;
	} elsif ($opts{range}) {
	    $input eq "" and $input = 1; #- defaults to first choice
	    (defined $opts{range_min} ? $opts{range_min} : 1) <= $input && $input <= $opts{range} and last;
	} else {
	    last;
	}
	message(N("Sorry, bad choice, try again\n"));
    }
    return $input;
}

sub message {
    my ($msg) = @_;
    if ($urpm::args::options{bug} || !defined fileno ::SAVEOUT) {
	print STDOUT "$msg\n";
    } else {
	print ::SAVEOUT "$msg\n";
    }
}

sub toMb {
    my $nb = $_[0] / 1024 / 1024;
    int $nb + 0.5;
}

sub localtime2changelog { scalar(localtime($_[0])) =~ /(.*) \S+ (\d{4})$/ && "$1 $2" };

1;

__END__

=head1 NAME

urpm::msg - routines to prompt messages from the urpm* tools

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 COPYRIGHT

Copyright (C) 2000-2004 Mandrakesoft

=cut
