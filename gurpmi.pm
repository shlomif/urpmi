package gurpmi;

#- This is needed because text printed by Gtk2 will always be encoded
#- in UTF-8; we first check if LC_ALL is defined, because if it is,
#- changing only LC_COLLATE will have no effect.
use POSIX qw(setlocale LC_ALL LC_COLLATE);
use locale;
BEGIN {
    my $collation_locale = $ENV{LC_ALL};
    if ($collation_locale) {
	$collation_locale =~ /UTF-8/ or setlocale(LC_ALL, "$collation_locale.UTF-8");
    } else {
	$collation_locale = setlocale(LC_COLLATE);
	$collation_locale =~ /UTF-8/ or setlocale(LC_COLLATE, "$collation_locale.UTF-8");
    }
}

use urpm;
use strict;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(fatal but quit add_button_box new_label);

sub usage () {
    print STDERR <<USAGE;
gurpmi version $urpm::VERSION
Usage :
    gurpmi <rpm> [ <rpm>... ]
USAGE
    exit 0;
}

#- fatal gurpmi initialisation error (*not* fatal urpmi errors)
sub fatal { print STDERR "$_[0]\n"; exit 1 }

#- Parse command line
#- puts options in %gurpmi::options
sub parse_command_line {
    my @all_rpms;
    our %options;
    foreach (@ARGV) {
	if (/^-/) {
	    $_ eq '--no-verify-rpm' and $options{'no-verify-rpm'} = 1;
	    /^--?[hv?]/ and usage();
	    fatal(N("Unknown option %s", $_));
	}
	push @all_rpms, $_;
    }
    return @all_rpms or fatal(N("No packages specified"));
}

sub but ($) { "    $_[0]    " }

sub quit () { Gtk2->main_quit }

sub add_button_box {
    my ($vbox, @buttons) = @_;
    my $hbox = Gtk2::HButtonBox->new;
    $vbox->pack_start($hbox, 0, 0, 0);
    $hbox->set_layout('edge');
    $_->set_alignment(0.5, 0.5), $hbox->add($_) foreach @buttons;
}

sub new_label {
    my ($msg) = @_;
    my $label = Gtk2::Label->new($msg);
    $label->set_line_wrap(1);
    $label->set_alignment(0.5, 0.5);
    if (($msg =~ tr/\n/\n/) > 5) {
	my $sw = Gtk2::ScrolledWindow->new;
	$sw->set_policy('never', 'automatic');
	$sw->add_with_viewport($label);
	$sw->set_size_request(-1,200);
	return $sw;
    } else {
	return $label;
    }
}

1;
