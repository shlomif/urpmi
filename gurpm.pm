#*****************************************************************************
# 
#  Copyright (c) 2003 Guillaume Cottenceau (gc at mandrakesoft dot com)
# 
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License version 2, as
#  published by the Free Software Foundation.
# 
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
# 
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
# 
#*****************************************************************************

package gurpm;

use strict;
use lib qw(/usr/lib/libDrakX);
use ugtk2 qw(:all);
$::isStandalone = 1;

our ($mainw, $label, $progressbar, $vbox, $cancel, $hbox_cancel);

sub init {
    my ($title, $initializing, $cancel_msg, $cancel_cb) = @_;
    $mainw = ugtk2->new($title);
    $label = Gtk2::Label->new($initializing);
    $progressbar = gtkset_size_request(Gtk2::ProgressBar->new, 300, -1);
    gtkadd($mainw->{window}, gtkpack__($vbox = Gtk2::VBox->new(0, 5), $label, $progressbar));
    $mainw->{rwindow}->set_position('center');
    $mainw->sync;
}

sub sync {
    $mainw->flush;  
}

sub label {
    $label->set($_[0]);
    select(undef, undef, undef, 0.1);  #- hackish :-(
    sync();
}

sub progress {
    $progressbar->set_fraction($_[0]);
    sync();
}

sub end {
    $mainw and $mainw->destroy;
    $mainw = undef;
    $cancel = undef;  #- in case we'll do another one later
}

sub validate_cancel {
    my ($cancel_msg, $cancel_cb) = @_;
    if (!$cancel) {
        gtkpack__($vbox,
                  $hbox_cancel = gtkpack__(create_hbox(),
                                           $cancel = gtksignal_connect(Gtk2::Button->new($cancel_msg), clicked => \&$cancel_cb)));
    }
    $cancel->set_sensitive(1);
    $cancel->show;
}

sub invalidate_cancel {
    $cancel and $cancel->set_sensitive(0);
}

sub invalidate_cancel_forever {
    $hbox_cancel or return;
    $hbox_cancel->destroy;
    $mainw->shrink_topwindow;
}

1;
