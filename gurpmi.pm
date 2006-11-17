package gurpmi;

#- Copyright (C) 2005 MandrakeSoft SA
#- Copyright (C) 2005, 2006 Mandriva SA
#- $Id$

#- This is needed because text printed by Gtk2 will always be encoded
#- in UTF-8; we first check if LC_ALL is defined, because if it is,
#- changing only LC_COLLATE will have no effect.
use POSIX();
use locale;
my $collation_locale = $ENV{LC_ALL};
if ($collation_locale) {
    $collation_locale =~ /UTF-8/ or POSIX::setlocale(POSIX::LC_ALL(), "$collation_locale.UTF-8");
} else {
    $collation_locale = POSIX::setlocale(POSIX::LC_COLLATE());
    $collation_locale =~ /UTF-8/ or POSIX::setlocale(POSIX::LC_COLLATE(), "$collation_locale.UTF-8");
}

use urpm;
use strict;
use Gtk2;
use urpm::util;

use Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(create_scrolled_window fatal but quit add_button_box new_label N);

sub usage () {
    print <<USAGE;
gurpmi version $urpm::VERSION
Usage :
    gurpmi <rpm> [ <rpm>... ]
Options :
    --auto
    --auto-select
    --no-verify-rpm
    --media media1,...
    --root root
    --searchmedia media1,...
USAGE
    exit 0;
}

#- fatal gurpmi initialisation error (*not* fatal urpmi errors)
sub fatal { my $s = $_[0]; print STDERR "$s\n"; exit 1 }

#- Parse command line
#- puts options in %gurpmi::options
#- puts bare names (not rpm filenames) in @gurpmi::names
sub parse_command_line() {
    my @all_rpms;
    our %options;
    our @names;
    # Expand *.urpmi arguments
    my @ARGV_expanded;
    foreach my $a (@ARGV) {
	if ($a =~ /\.urpmi$/) {
	    open my $fh, '<', $a or do { warn "Can't open $a: $!\n"; next };
	    push @ARGV_expanded, map { chomp; $_ } <$fh>;
	    close $fh;
	} else {
	    push @ARGV_expanded, $a;
	}
    }
    my $nextopt;
    foreach (@ARGV_expanded) {
	if ($nextopt) { $options{$nextopt} = $_; undef $nextopt; next }
	if (/^-/) {
	    if (/^--(no-verify-rpm|auto-select|auto)$/) {
		$options{$1} = 1;
		next;
	    }
	    if (/^--(media|searchmedia|root)$/) {
		$nextopt = $1;
		next;
	    }
	    /^--?[hv?]/ and usage();
	    fatal(N("Unknown option %s", $_));
	}
	if (-f $_) {
	    push @all_rpms, $_;
	} else {
	    push @names, $_;
	}
	
    }
    $options{'auto-select'} || @all_rpms + @names
	or fatal(N("No packages specified"));
    return @all_rpms;
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

sub N {
    my ($format, @params) = @_;
    my $r = sprintf(
	eval { Locale::gettext::gettext($format || '') } || $format,
	@params,
    );
    Locale::gettext::iconv($r, undef, "UTF-8");
}


# copied from ugtk2:
sub create_scrolled_window {
    my ($W, $o_policy, $o_viewport_shadow) = @_;
    my $w = Gtk2::ScrolledWindow->new(undef, undef);
    $w->set_policy($o_policy ? @$o_policy : ('automatic', 'automatic'));
    if (member(ref($W), qw(Gtk2::Layout Gtk2::Html2::View Gtk2::Text Gtk2::TextView Gtk2::TreeView))) {
	$w->add($W);
    } else {
	$w->add_with_viewport($W);
    }
    $o_viewport_shadow and $w->child->set_shadow_type($o_viewport_shadow);
    $W->can('set_focus_vadjustment') and $W->set_focus_vadjustment($w->get_vadjustment);
    $W->set_left_margin(6) if ref($W) =~ /Gtk2::TextView/;
    $W->show;
    if (ref($W) =~ /Gtk2::TextView|Gtk2::TreeView/) {
	my $f = Gtk2::Frame->new;
	$f->set_shadow_type('in');
     $f->add($w);
     $f;
    } else {
	$w;
    }
}

1;
