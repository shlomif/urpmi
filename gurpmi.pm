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

sub but ($) { "    $_[0]    " }

1;
