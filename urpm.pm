package urpm;

# $Id$

no warnings 'utf8';
use strict;
use File::Find ();
use urpm::msg;
use urpm::download;
use urpm::util;
use urpm::sys;
use urpm::cfg;
use urpm::md5sum;

our $VERSION = '4.9.30';
our @ISA = qw(URPM Exporter);
our @EXPORT_OK = 'file_from_local_url';

use URPM;
use URPM::Resolve;

#- this violently overrides is_arch_compat() to always return true.
sub shunt_ignorearch {
    eval q( sub URPM::Package::is_arch_compat { 1 } );
}

#- create a new urpm object.
sub new {
    my ($class) = @_;
    my $self;
    $self = bless {
	# from URPM
	depslist   => [],
	provides   => {},

	media      => undef,
	options    => {},

	fatal      => sub { printf STDERR "%s\n", $_[1]; exit($_[0]) },
	error      => sub { printf STDERR "%s\n", $_[0] },
	info       => sub { printf "%s\n", $_[0] }, #- display unless --quiet
	log        => sub { printf "%s\n", $_[0] }, #- displayed is --verbose
	ui_msg     => sub {
	    $self->{log}($_[0]);
	    ref $self->{ui} && ref $self->{ui}{msg} and $self->{ui}{msg}->($_[1]);
	},
    }, $class;

    set_files($self, '');
    $self->set_nofatal(1);
    $self;
}

sub set_files {
    my ($urpm, $urpmi_root) = @_;
    my %h = (
	config        => "$urpmi_root/etc/urpmi/urpmi.cfg",
	skiplist      => "$urpmi_root/etc/urpmi/skip.list",
	instlist      => "$urpmi_root/etc/urpmi/inst.list",
	private_netrc => "$urpmi_root/etc/urpmi/netrc",
	statedir      => "$urpmi_root/var/lib/urpmi",
	cachedir      => "$urpmi_root/var/cache/urpmi",
	root          => $urpmi_root,
	$urpmi_root ? (urpmi_root => $urpmi_root) : (),
    );
    $urpm->{$_} = $h{$_} foreach keys %h;

    require File::Path;
    File::Path::mkpath([ $h{statedir}, 
			 (map { "$h{cachedir}/$_" } qw(headers partial rpms)),
			 dirname($h{config}),
			 "$urpmi_root/var/lib/rpm",
		     ]);
}

sub protocol_from_url {
    my ($url) = @_;
    $url =~ m!^(\w+)(_[^:]*)?:! && $1;
}
sub file_from_local_url {
    my ($url) = @_;
    $url =~ m!^(?:removable[^:]*:/|file:/)?(/.*)! && $1;
}

sub db_open_or_die {
    my ($urpm, $root, $b_write_perm) = @_;

    $urpm->{debug} and $urpm->{debug}("opening rpmdb (root=$root, write=$b_write_perm)");

    my $db = URPM::DB::open($root, $b_write_perm || 0)
      or $urpm->{fatal}(9, N("unable to open rpmdb"));

    $db;
}

sub remove_obsolete_headers_in_cache {
    my ($urpm) = @_;
    my %headers;
    if (my $dh = urpm::sys::opendir_safe($urpm, "$urpm->{cachedir}/headers")) {
	local $_;
	while (defined($_ = readdir $dh)) {
	    m|^([^/]*-[^-]*-[^-]*\.[^\.]*)(?::\S*)?$| and $headers{$1} = $_;
	}
    }
    if (%headers) {
	my $previous_total = scalar(keys %headers);
	foreach (@{$urpm->{depslist}}) {
	    delete $headers{$_->fullname};
	}
	$urpm->{log}(N("found %d rpm headers in cache, removing %d obsolete headers", $previous_total, scalar(keys %headers)));
	foreach (values %headers) {
	    unlink "$urpm->{cachedir}/headers/$_";
	}
    }
}

#- register local packages for being installed, keep track of source.
sub register_rpms {
    my ($urpm, @files) = @_;
    my ($start, $id, $error, %requested);

    #- examine each rpm and build the depslist for them using current
    #- depslist and provides environment.
    $start = @{$urpm->{depslist}};
    foreach (@files) {
	/\.(?:rpm|spec)$/ or $error = 1, $urpm->{error}(N("invalid rpm file name [%s]", $_)), next;

	#- if that's an URL, download.
	if (protocol_from_url($_)) {
	    my $basename = basename($_);
	    unlink "$urpm->{cachedir}/partial/$basename";
	    $urpm->{log}(N("retrieving rpm file [%s] ...", $_));
	    if (urpm::download::sync($urpm, undef, [$_], quiet => 1)) {
		$urpm->{log}(N("...retrieving done"));
		$_ = "$urpm->{cachedir}/partial/$basename";
	    } else {
		$urpm->{error}(N("...retrieving failed: %s", $@));
		unlink "$urpm->{cachedir}/partial/$basename";
		next;
	    }
	} else {
	    -r $_ or $error = 1, $urpm->{error}(N("unable to access rpm file [%s]", $_)), next;
	}

	if (/\.spec$/) {
	    my $pkg = URPM::spec2srcheader($_)
		or $error = 1, $urpm->{error}(N("unable to parse spec file %s [%s]", $_, $!)), next;
	    $id = @{$urpm->{depslist}};
	    $urpm->{depslist}[$id] = $pkg;
	    #- It happens that URPM sets an internal id to the depslist id.
	    #- We need to set it by hand here.
	    $pkg->set_id($id);
	    $urpm->{source}{$id} = $_;
	} else {
	    ($id) = $urpm->parse_rpm($_);
	    my $pkg = defined $id && $urpm->{depslist}[$id];
	    $pkg or $error = 1, $urpm->{error}(N("unable to register rpm file")), next;
	    $pkg->arch eq 'src' || $pkg->is_arch_compat
		or $error = 1, $urpm->{error}(N("Incompatible architecture for rpm [%s]", $_)), next;
	    $urpm->{source}{$id} = $_;
	}
    }
    $error and $urpm->{fatal}(2, N("error registering local packages"));
    defined $id && $start <= $id and @requested{($start .. $id)} = (1) x ($id-$start+1);

    #- distribute local packages to distant nodes directly in cache of each machine.
    @files && $urpm->{parallel_handler} and $urpm->{parallel_handler}->parallel_register_rpms($urpm, @files);

    %requested;
}

#- checks whether the delta RPM represented by $pkg is installable wrt the
#- RPM DB on $root. For this, it extracts the rpm version to which the
#- delta applies from the delta rpm filename itself. So naming conventions
#- do matter :)
sub is_delta_installable {
    my ($urpm, $pkg, $root) = @_;
    $pkg->flag_installed or return 0;
    my $f = $pkg->filename;
    my $n = $pkg->name;
    my ($v_match) = $f =~ /^\Q$n\E-(.*)_.+\.delta\.rpm$/;
    my $db = db_open_or_die($urpm, $root);
    my $v_installed;
    $db->traverse(sub {
	my ($p) = @_;
	$p->name eq $n and $v_installed = $p->version . '-' . $p->release;
    });
    $v_match eq $v_installed;
}

#- Obsolescent method.
sub download_source_packages {
    my ($urpm, $local_sources, $list, %options) = @_;
    my %sources = %$local_sources;
    my %error_sources;

    require urpm::get_pkgs;
    urpm::removable::copy_packages_of_removable_media($urpm, $list, \%sources, $options{ask_for_medium}) or return;
    urpm::get_pkgs::download_packages_of_distant_media($urpm, $list, \%sources, \%error_sources, %options);

    %sources, %error_sources;
}

#- extract package that should be installed instead of upgraded,
#- installing instead of upgrading is useful
#- - for inst.list (cf flag disable_obsolete)
#- sources is a hash of id -> source rpm filename.
sub extract_packages_to_install {
    my ($urpm, $sources, $state) = @_;
    my %inst;

    foreach (keys %$sources) {
	my $pkg = $urpm->{depslist}[$_] or next;
	$pkg->flag_disable_obsolete
	  and $inst{$pkg->id} = delete $sources->{$pkg->id};
    }

    \%inst;
}

#- deprecated
sub install { require urpm::install; &urpm::install::install }

#- deprecated
sub parallel_remove { &urpm::parallel::remove }

#- get reason of update for packages to be updated
#- use all update medias if none given
sub get_updates_description {
    my ($urpm, @update_medias) = @_;
    my %update_descr;
    my ($cur, $section);

    @update_medias or @update_medias = grep { !$_->{ignore} && $_->{update} } @{$urpm->{media}};

    foreach my $medium (@update_medias) {
        # fix not taking into account the last %package token of each descrptions file: '%package dummy'
	foreach (cat_utf8(urpm::media::statedir_descriptions($urpm, $medium)), '%package dummy') {
	    /^%package +(.+)/ and do {
		# fixes not parsing descriptions file when MU adds itself the security source:
		if (exists $cur->{importance} && !member($cur->{importance}, qw(security bugfix))) {
		    $cur->{importance} = 'normal';
		}
		$update_descr{$_} = $cur foreach @{$cur->{pkgs} || []};
		$cur = { pkgs => [ split /\s/, $1 ], medium => $medium->{name} };
		$section = 'pkg';
		next;
	    };
	    /^Updated?: +(.+)/ && $section eq 'pkg' and do { $cur->{updated} = $1; next };
	    /^Importance: +(.+)/ && $section eq 'pkg' and do { $cur->{importance} = $1; next };
	    /^(ID|URL): +(.+)/ && $section eq 'pkg' and do { $cur->{$1} = $2; next };
	    /^%(pre|description)/ and do { $section = $1; next };
	    $section  =~ /^(pre|description)\z/ and $cur->{$1} .= $_;
	}
    }
    \%update_descr;
}

sub error_restricted ($) {
    my ($urpm) = @_;
    $urpm->{fatal}(2, N("This operation is forbidden while running in restricted mode"));
}

sub DESTROY {}

1;

__END__

=head1 NAME

urpm - Mandriva perl tools to handle the urpmi database

=head1 DESCRIPTION

C<urpm> is used by urpmi executables to manipulate packages and media
on a Mandriva Linux distribution.

=head1 SEE ALSO

The C<URPM> package is used to manipulate at a lower level hdlist and rpm
files.

=head1 COPYRIGHT

Copyright (C) 2000, 2001, 2002, 2003, 2004, 2005 MandrakeSoft SA

Copyright (C) 2005, 2006 Mandriva SA

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2, or (at your option)
any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut

# ex: set ts=8 sts=4 sw=4 noet:
