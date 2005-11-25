#!perl
# Makefile.PL for urpmi
# $Id$

use strict;
use ExtUtils::MakeMaker;

# Command-line parsing.
my $with_rpm = 1;
$with_rpm = 0 if grep $_ eq '--without-rpm', @ARGV;

# Directory where to build an rpm of this
my $rpmtopdir = $with_rpm ? qx(rpm --eval %_topdir) : '';
chomp $rpmtopdir;

# All scripts, some of them go in /usr/sbin (see DESTINSTALLSBIN below)
our @bin_scripts = qw(urpmq urpmf rpm-find-leaves);
our @sbin_scripts = qw(urpmi urpme urpmi.addmedia urpmi.update urpmi.removemedia rurpmi);

# And now, add some functionality to MakeMaker.
package MY;

# Make proper sbin/man5/man8 dirs in blib
sub top_targets {
    my $inherited = shift->SUPER::top_targets(@_);
    $inherited =~ s/^config ::/$& \$(INST_MAN5DIR)\$(DIRFILESEP).exists \$(INST_MAN8DIR)\$(DIRFILESEP).exists \$(INST_SBIN)\$(DIRFILESEP).exists/m;
    $inherited;
}

# Install sbin_scripts in sbin under blib
sub installbin {
    my $self = shift;
    my $inherited = $self->SUPER::installbin(@_);
    my $s = join '|', map quotemeta, @sbin_scripts;
    $inherited =~ s{\$\(INST_SCRIPT\)/($s)}{\$(INST_SBIN)/$1}g;
    # how to create needed directories under blib
    $inherited .= $self->dir_target("\$(INST_$_)") for qw(SBIN MAN5DIR MAN8DIR);
    $inherited;
}

sub install {
    my $inherited = shift->SUPER::install(@_);
    # Take into account scripts in sbin under blib
    # and new manpage sections
    $inherited =~ s/\$\(INST_BIN\) \$\(DESTINSTALL(\w*)BIN\)/$& \$(INST_SBIN) \$(DESTINSTALL$1SBIN) \$(INST_MAN5DIR) \$(DESTINSTALLMAN5DIR) \$(INST_MAN8DIR) \$(DESTINSTALLMAN8DIR)/g;
    # install files under /etc and /var
    $inherited =~ s/^install ::/$& installconfigfiles installstatedir/gm;
    $inherited;
}

# Due to some hateful layout (that I can't change because the whole stuff is
# hosted in CVS (double hate)) I need to add pm_to_blib in the phonic targets.
sub special_targets {
    my $inherited = shift->SUPER::special_targets(@_);
    $inherited =~ s/PHONY:/$& pm_to_blib/;
    $inherited;
}

# Additional targets
sub postamble {
    <<"**MM**";
.PHONY: installconfigfiles installstatedir ChangeLog rpmdist srpm rpm

po:
	\$(MAKE) -C \$\@

installconfigfiles:
	install -d \$(SYSCONFDIR)/urpmi
	install -m 644 inst.list skip.list \$(SYSCONFDIR)/urpmi

installstatedir:
	install -d \$(LOCALSTATEDIR)/urpmi

ChangeLog:
	cvs2cl -W 400 -I ChangeLog --accum -U ../../soft/common/username
	rm -f *.bak

rpmdist: dist
	cp -f urpmi.spec $rpmtopdir/SPECS
	mv -f urpmi-*.tar.bz2 $rpmtopdir/SOURCES

srpm: rpmdist
	rpmbuild -bs --clean --rmsource $rpmtopdir/SPECS/urpmi.spec

rpm: rpmdist
	rpmbuild -ba --clean --rmsource $rpmtopdir/SPECS/urpmi.spec
**MM**
}

# TODO gurpmi, gurpmi2 (need console-helper)

# Back to our schedule
package main;

WriteMakefile(
    NAME		=> 'urpmi',
    PREREQ_PM		=> {
	'Locale::gettext'	=> '1.01',
	'MDV::Packdrakeng'	=> '1.00',
	'URPM'			=> '1.29',
    },
    VERSION_FROM	=> 'urpm.pm',
    macro		=> {
	DESTINSTALLSBIN		=> '$(DESTINSTALLBIN)/../sbin',
	DESTINSTALLSITESBIN	=> '$(DESTINSTALLSITEBIN)/../sbin',
	DESTINSTALLVENDORSBIN	=> '$(DESTINSTALLVENDORBIN)/../sbin',
	INSTALLMAN5DIR		=> '$(PERLPREFIX)/share/man/man5',
	DESTINSTALLMAN5DIR	=> '$(DESTDIR)$(INSTALLMAN5DIR)',
	INSTALLMAN8DIR		=> '$(PERLPREFIX)/share/man/man8',
	DESTINSTALLMAN8DIR	=> '$(DESTDIR)$(INSTALLMAN8DIR)',
	INST_SBIN		=> 'blib/sbin',
	INST_MAN5DIR		=> 'blib/man5',
	INST_MAN8DIR		=> 'blib/man8',
	# We could read those values from rpm macros.
	SYSCONFDIR		=> '$(DESTDIR)/etc',
	LOCALSTATEDIR		=> '$(DESTDIR)/var/lib',
    },
    EXE_FILES		=> [ @bin_scripts, @sbin_scripts ],
    PMLIBDIRS		=> [ qw(urpm) ],
    MAN1PODS		=> {
	map {
	    my $targ = $_;
	    $targ =~ s{^pod/}{};
	    $targ =~ s/\.(\d)\.pod$//;
	    my $section = $1 || 1;
	    ( $_ => "\$(INST_MAN${section}DIR)/$targ.$section" );
	} <pod/*.pod>
    },
    dist		=> { COMPRESS => "bzip2", SUFFIX => ".bz2" },
);
