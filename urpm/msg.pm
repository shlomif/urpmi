package urpm::msg;

use strict;
use Exporter;
our @ISA = 'Exporter';
our @EXPORT = qw(N log_it to_utf8 message_input gmessage message toMb);

my $noexpr = N("Nn");
my $yesexpr = N("Yy");

#- I18N.
eval {
    require Locale::gettext;
    use POSIX qw(LC_ALL);
    setlocale(LC_ALL, "");
    Locale::gettext::textdomain("urpmi");
};

sub N {
    my ($format, @params) = @_;
    sprintf(eval { Locale::gettext::gettext($format || '') } || $format, @params);
}

sub log_it {
    #- if invoked as a simple user, nothing should be logged.
    if ($::log) {
	open my $fh, ">>$::log" or die "can't output to log file: $!\n";
	print $fh @_;
	close $fh;
    }
}

sub to_utf8 { Locale::gettext::iconv($_[0], undef, "UTF-8") }

sub gmessage {
    my ($msg, %params) = @_;
    my $ok = to_utf8($params{ok} || N("Ok"));
    my $cancel = to_utf8($params{cancel} || N("Cancel"));
    $ok =~ s/,/\\,/g; $cancel =~ s/,/\\,/g;
    my $buttons = $params{ok_only} ? "$ok:0" : "$ok:0,$cancel:2";
    foreach (@{$params{add_buttons}}) {
	s/,/\\,/g;
	$buttons .= ",$_";
    }
    $msg = to_utf8($msg);
    `gmessage -default "$ok" -buttons "$buttons" "$msg"`;
}

sub message_input {
    my ($msg, $default_input, %opts) = @_;
    my $input;
    if ($urpm::args::options{X} && !$default_input) {
	#- if a default input is given, the user doesn't have to choose (and being asked).
	gmessage($msg, ok_only => 1);
	$urpm::args::options{bug} and log_it($msg);
    } else {
	while (1) {
	    if ($urpm::args::options{bug}) {
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
	    $urpm::args::options{bug} and log_it($input);
	    if ($opts{boolean}) {
		$input =~ /^[$noexpr$yesexpr]*$/ and last;
	    } elsif ($opts{range}) {
		1 <= $input && $input <= $opts{range} and last;
	    } else {
		last;
	    }
	    message(N("Sorry, bad choice, try again\n"));
	}
    }
    return $input;
}

sub message {
    my ($msg, $no_X) = @_;
    if ($urpm::args::options{X} && !$no_X && !$::auto) {
	gmessage($msg, ok_only => 1);
	$urpm::args::options{bug} and log_it($msg);
    } else {
	if ($urpm::args::options{bug}) {
	    print STDOUT "$msg\n";
	} else {
	    print ::SAVEOUT "$msg\n";
	}
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

=cut
