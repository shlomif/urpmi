package urpm;

use strict;
use vars qw($VERSION @ISA);

$VERSION = '1.6';

=head1 NAME

urpm - Mandrake perl tools to handle urpmi database

=head1 SYNOPSYS

    require urpm;

    my $urpm = new urpm;

    $urpm->read_depslist();
    $urpm->read_provides();
    $urpm->read_compss();
    $urpm->read_config();

=head1 DESCRIPTION

C<urpm> is used by urpmi executable to manipulate packages and mediums
on a Linux-Mandrake distribution.

=head1 SEE ALSO

rpmtools package is used to manipulate at a lower level hdlist and rpm
files.

=head1 COPYRIGHT

Copyright (C) 2000 MandrakeSoft <fpons@mandrakesoft.com>

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

use rpmtools;
use POSIX;
use Locale::GetText;

#- I18N.
setlocale (LC_ALL, "");
Locale::GetText::textdomain ("urpmi");

sub _ {
    my ($format, @params) = @_;
    sprintf(Locale::GetText::I_($format), @params);
}

#- create a new urpm object.
sub new {
    my ($class) = @_;
    bless {
	   config     => "/etc/urpmi/urpmi.cfg",
	   skiplist   => "/etc/urpmi/skip.list",
	   depslist   => "/var/lib/urpmi/depslist.ordered",
	   provides   => "/var/lib/urpmi/provides",
	   compss     => "/var/lib/urpmi/compss",
	   statedir   => "/var/lib/urpmi",
	   cachedir   => "/var/cache/urpmi",
	   media      => undef,
	   params     => new rpmtools,

	   fatal      => sub { printf STDERR "%s\n", $_[1]; exit($_[0]) },
	   error      => sub { printf STDERR "%s\n", $_[0] },
	   log        => sub { printf STDERR "%s\n", $_[0] },
	  }, $class;
}

#- quoting/unquoting a string that may be containing space chars.
sub quotespace { local $_ = $_[0]; s/(\s)/\\$1/g; $_ }
sub unquotespace { local $_ = $_[0]; s/\\(\s)/$1/g; $_ }

#- read /etc/urpmi/urpmi.cfg as config file, keep compability with older
#- configuration file by examining if one entry is of the form
#-   <name> <url> {
#-      ...
#-   }
#- else only this form is used
#-   <name> <url>
#-   <name> <ftp_url> with <relative_path_hdlist>
sub read_config {
    my ($urpm, %options) = @_;

    #- keep in mind if it has been called before.
    $urpm->{media} and return; $urpm->{media} ||= [];

    #- check urpmi.cfg content, if the file is old keep track
    #- of old format used.
    local (*F, $_);
    open F, $urpm->{config}; #- no filename can be allowed on some case
    while (<F>) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	/^(.*?[^\\])\s+(?:(.*?[^\\])\s+)?{$/ and do { #- urpmi.cfg format extention
	    my $medium = { name => unquotespace($1), clear_url => unquotespace($2) };
	    while (<F>) {
		chomp; s/#.*$//; s/^\s*//; s/\s*$//;
		/^hdlist\s*:\s*(.*)$/ and $medium->{hdlist} = $1, next;
		/^with_hdlist\s*:\s*(.*)$/ and $medium->{with_hdlist} = $1, next;
		/^list\s*:\s*(.*)$/ and $medium->{list} = $1, next;
		/^removable\s*:\s*(.*)$/ and $medium->{removable} = $1, next;
		/^update\s*$/ and $medium->{update} = 1, next;
		/^ignore\s*$/ and $medium->{ignore} = 1, next;
		/^modified\s*$/ and $medium->{modified} = 1, next;
		$_ eq '}' and last;
		$_ and $urpm->{error}(_("syntax error in config file at line %s", $.));
	    }
	    $urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
	    next; };
	/^(.*?[^\\])\s+(.*?[^\\])\s+with\s+(.*)$/ and do { #- urpmi.cfg old format for ftp
	    my $medium = { name => unquotespace($1), clear_url => unquotespace($2), with_hdlist => unquotespace($3) };
	    $urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
	    next; };
	/^(.*?[^\\])\s+(?:(.*?[^\\])\s*)?$/ and do { #- urpmi.cfg old format (assume hdlist.<name>.cz2?)
	    my $medium = { name => unquotespace($1), clear_url => unquotespace($2) };
	    $urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
	    next; };
	$_ and $urpm->{error}(_("syntax error in config file at line %s", $.));
    }
    close F;

    #- keep in mind when an hdlist/list file is used, really usefull for
    #- the next probe.
    my (%hdlists, %lists);
    foreach (@{$urpm->{media}}) {
	exists $hdlists{$_->{hdlist}} and
	  $_->{ignore} = 1, $urpm->{error}(_("medium \"%s\" try to use an already used hdlist, medium ignored", $_->{name}));
	$hdlists{$_->{hdlist}} = undef;
	exists $lists{$_->{list}} and
	  $_->{ignore} = 1, $urpm->{error}(_("medium \"%s\" try to use an already used list, medium ignored", $_->{name}));
	$lists{$_->{list}} = undef;
    }

    #- urpmi.cfg if old is not enough to known the various media, track
    #- directly into /var/lib/urpmi,
    foreach (glob("$urpm->{statedir}/hdlist.*")) {
	if (/\/hdlist\.((.*)\.cz2?)$/) {
	    #- check if it has already been detected above.
	    exists $hdlists{"hdlist.$1"} and next;

	    #- if not this is a new media to take care if
	    #- there is a list file.
	    if (-s "$urpm->{statedir}/list.$2") {
		if (exists $lists{"list.$2"}) {
		    $urpm->{error}(_("unable to take care of medium \"%s\" as list file is already used by another medium", $2));
		} else {
		    my $medium;
		    foreach (@{$urpm->{media}}) {
			$_->{name} eq $2 and $medium = $_, last;
		    }
		    $medium and $urpm->{error}(_("unable to use name \"%s\" for unamed medium because it is already used",
						 $2)), next;

		    $medium = { name => $2, hdlist => "hdlist.$1", list => "list.$2" };
		    $urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
		}
	    } else {
		$urpm->{error}(_("unable to take medium \"%s\" into account as no list file [%s] exists",
				 $2, "$urpm->{statedir}/list.$2"));
	    }
	} else {
	    $urpm->{error}(_("unable to determine medium of this hdlist file [%s]", $_));
	}
    }

    #- check the presence of hdlist file and list file if necessary.
    #- TODO?: degraded mode is possible with a list file but no hdlist, the medium
    #- is no longer updatable nor removable TODO
    unless ($options{nocheck_access}) {
	foreach (@{$urpm->{media}}) {
	    $_->{ignore} and next;
	    -r "$urpm->{statedir}/$_->{hdlist}" or
	      $_->{ignore} = 1, $urpm->{error}(_("unable to access hdlist file of \"%s\", medium ignored", $_->{name}));
	    $_->{list} && -r "$urpm->{statedir}/$_->{list}" or
	      $_->{ignore} = 1, $urpm->{error}(_("unable to access list file of \"%s\", medium ignored", $_->{name}));
	}
    }
}

#- probe medium to be used, take old medium into account too.
sub probe_medium {
    my ($urpm, $medium, %options) = @_;
    local $_;

    my $existing_medium;
    foreach (@{$urpm->{media}}) {
	$_->{name} eq $medium->{name} and $existing_medium = $_, last;
    }
    $existing_medium and $urpm->{error}(_("trying to bypass existing medium \"%s\", avoiding", $medium->{name})), return;
    
    unless ($medium->{ignore} || $medium->{hdlist}) {
	$medium->{hdlist} = "hdlist.$medium->{name}.cz";
	-e "$urpm->{statedir}/$medium->{hdlist}" or $medium->{hdlist} = "hdlist.$medium->{name}.cz2";
	-e "$urpm->{statedir}/$medium->{hdlist}" or
	  $medium->{ignore} = 1, $urpm->{error}(_("unable to find hdlist file for \"%s\", medium ignored", $medium->{name}));
    }
    unless ($medium->{ignore} || $medium->{list}) {
	$medium->{list} = "list.$medium->{name}";
	-e "$urpm->{statedir}/$medium->{list}" or
	  $medium->{ignore} = 1, $urpm->{error}(_("unable to find list file for \"%s\", medium ignored", $medium->{name}));
    }

    #- there is a little more to do at this point as url is not known, inspect directly list file for it.
    unless ($medium->{url} || $medium->{clear_url}) {
	my %probe;
	local *L;
	open L, "$urpm->{statedir}/$medium->{list}";
	while (<L>) {
	    /^(.*)\/[^\/]*/ and $probe{$1} = undef;
	}
	close L;
	foreach (sort { length($a) <=> length($b) } keys %probe) {
	    if ($medium->{url}) {
		$medium->{url} eq substr($_, 0, length($medium->{url})) or
		  $medium->{ignore} || $urpm->{error}(_("incoherent list file for \"%s\", medium ignored", $medium->{name})),
		    $medium->{ignore} = 1, last;
	    } else {
		$medium->{url} = $_;
	    }
	}
	unless ($options{nocheck_access}) {
	    $medium->{url} or
	      $medium->{ignore} || $urpm->{error}(_("unable to inspect list file for \"%s\", medium ignored", $medium->{name})),
		$medium->{ignore} = 1; #, last; keeping it cause perl to exit caller loop ...
	}
    }
    $medium->{url} ||= $medium->{clear_url};
    $medium->{removable} ||= $medium->{url} =~ /^removable_([^_:]*)(?:_[^:]*)?:/ && "/dev/$1";
    $medium;
}

#- write back urpmi.cfg code to allow modification of medium listed.
sub write_config {
    my ($urpm) = @_;

    #- avoid trashing exiting configuration in this case.
    $urpm->{media} or return;

    local *F;
    open F, ">$urpm->{config}" or $urpm->{fatal}(6, _("unable to write config file [%s]", $urpm->{config}));
    foreach my $medium (@{$urpm->{media}}) {
	printf F "%s %s {\n", quotespace($medium->{name}), quotespace($medium->{clear_url});
	foreach (qw(hdlist with_hdlist list removable)) {
	    $medium->{$_} and printf F "  %s: %s\n", $_, $medium->{$_};
	}
	foreach (qw(update ignore modified)) {
	    $medium->{$_} and printf F "  %s\n", $_;
	}
	printf F "}\n\n";
    }
    close F;
    $urpm->{log}(_("write config file [%s]", $urpm->{config}));
}

#- add a new medium, sync the config file accordingly.
sub add_medium {
    my ($urpm, $name, $url, $with_hdlist, %options) = @_;

    #- make sure configuration has been read.
    $urpm->{media} or $urpm->read_config();

    #- if a medium with that name has already been found
    #- we have to exit now
    my ($medium);
    foreach (@{$urpm->{media}}) {
	$_->{name} eq $2 and $medium = $_;
    }
    $medium and $urpm->{fatal}(5, _("medium \"%s\" already exists", $medium));

    #- creating the medium info.
    $medium = { name     => $name,
		url      => $url,
		hdlist   => "hdlist.$name.cz",
		list     => "list.$name",
		update   => $options{update},
		modified => 1,
	      };

    #- check to see if the medium is using file protocol or removable medium.
    if (my ($prefix, $dir) = $url =~ /^(removable_.*?|file):\/(.*)/) {
	#- the directory given does not exist or may be accessible
	#- by mounting some other. try to figure out these directory and
	#- mount everything necessary.
	$urpm->try_mounting($dir, 'mount') or $urpm->{log}(_("unable to access medium \"%s\"", $name)), return;

	#- check if directory is somewhat normalized so that we can get back hdlist,
	#- check it that case if depslist, compss and provides file are also
	#- provided.
	if (!($with_hdlist && -e "$dir/$with_hdlist") && $dir =~ /RPMS([^\/]*)\/*$/) {
	    foreach my $rdir (qw(Mandrake/base ../Mandrake/base ..)) {
		-e "$dir/$_/hdlist$1.cz" and $with_hdlist = "$_/hdlist$1.cz", last;
		-e "$dir/$_/hdlist$1.cz2" and $with_hdlist = "$_/hdlist$1.cz2", last;
	    }
	}

	#- add some more flags for this type of medium.
	$medium->{clear_url} = $url;
	$medium->{removable} = $url =~ /^removable_([^_:]*)(?:_[^:]*)?:/ && "/dev/$1";
    }

    #- all flags once everything has been computed.
    $with_hdlist and $medium->{with_hdlist} = $with_hdlist;

    #- create an entry in media list.
    push @{$urpm->{media}}, $medium;

    #- keep in mind the database has been modified and base files need to be updated.
    #- this will be done automatically by transfering modified flag from medium to global.
}

sub remove_media {
    my $urpm = shift;
    my %media; @media{@_} = undef;
    my @result;

    foreach (@{$urpm->{media}}) {
	if (exists $media{$_->{name}}) {
	    $media{$_->{name}} = 1; #- keep it mind this one has been removed

	    #- remove file associated with this medium.
	    #- this is the hdlist and the list files.
	    unlink "$urpm->{statedir}/synthesis.$_->{hdlist}";
	    unlink "$urpm->{statedir}/$_->{hdlist}";
	    unlink "$urpm->{statedir}/$_->{list}";
	} else {
	    push @result, $_; #- not removed so keep it
	}
    }

    #- check if some arguments does not correspond to medium name.
    foreach (keys %media) {
	if ($media{$_}) {
	    #- when a medium is removed, depslist and others need to be recomputed.
	    $urpm->{modified} = 1;
	} else {
	    $urpm->{error}(_("trying to remove inexistant medium \"%s\"", $_));
	}
    }

    #- special case if there is no more media registered.
    #- there is no need to recompute the hdlist and the files
    #- can be safely removed.
    if ($urpm->{modified} && @result == 0) {
	unlink $urpm->{depslist};
	unlink $urpm->{provides};
	unlink $urpm->{compss};
    }

    #- restore newer media list.
    $urpm->{media} = \@result;
}

sub select_media {
    my $urpm = shift;
    my %media; @media{@_} = undef;

    foreach (@{$urpm->{media}}) {
	if (exists $media{$_->{name}}) {
	    $media{$_->{name}} = 1; #- keep it mind this one has been selected.

	    #- select medium by setting modified flags, do not check ignore.
	    $_->{modified} = 1;
	}
    }

    #- check if some arguments does not correspond to medium name.
    foreach (keys %media) {
	unless ($media{$_}) {
	    $urpm->{error}(_("trying to select inexistant medium \"%s\"", $_));
	}
    }
}

sub build_synthesis_hdlist {
    my ($urpm, $medium) = @_;
    my $params = new rpmtools;

    push @{$params->{flags}}, 'sense'; #- make sure to enable sense flags.
    $urpm->{log}(_("reading hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
    $params->read_hdlists("$urpm->{statedir}/$medium->{hdlist}") or return;
    eval {
	unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
	local *F;
	open F, "| gzip >'$urpm->{statedir}/synthesis.$medium->{hdlist}'";
	foreach my $p (values %{$params->{info}}) {
	    foreach (qw(provides requires)) {
		@{$p->{$_} || []} > 0 and
		  print F "$p->{name}\@$_\@" . join('@', map { s/\[\*\]//g; s/\[(.*)\]/ $1/g; $_ } @{$p->{$_}}) . "\n";
	    }
	}
	close F or die "unable to use gzip for compressing hdlist synthesis";
    };
    if ($@) {
	unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
	$urpm->{error}(_("unable to build synthesis file for medium \"%s\"", $medium->{name}));
	return;
    } else {
	$urpm->{log}(_("built hdlist synthesis file for medium \"%s\"", $medium->{name}));
    }
    1;
}

#- update urpmi database regarding the current configuration.
#- take care of modification and try some trick to bypass
#- computational of base files.
#- allow options :
#-   all     -> all medium are rebuilded
#-   force   -> try to force rebuilding base files (1) or hdlist from rpms files (2).
#-   noclean -> keep header directory cleaned.
sub update_media {
    my ($urpm, %options) = @_; #- do not trust existing hdlist and try to recompute them.

    #- avoid trashing existing configuration in this case.
    $urpm->{media} or return;

    #- examine each medium to see if one of them need to be updated.
    #- if this is the case and if not forced, try to use a pre-calculated
    #- hdlist file else build it from rpms files.
    foreach my $medium (@{$urpm->{media}}) {
	#- take care of modified medium only or all if all have to be recomputed.
	#- but do not take care of removable media for all.
	$medium->{ignore} and next;
	$medium->{modified} ||= $options{all} && $medium->{url} !~ /removable/ or next;

	#- list of rpm files for this medium, only available for local medium where
	#- the source hdlist is not used (use force).
	my ($prefix, $dir, $error, @files);

	#- check to see if the medium is using file protocol or removable medium.
	if (($prefix, $dir) = $medium->{url} =~ /^(removable_.*?|file):\/(.*)/) {
	    #- the directory given does not exist and may be accessible
	    #- by mounting some other. try to figure out these directory and
	    #- mount everything necessary.
	    $urpm->try_mounting($dir, 'mount') or $urpm->{log}(_("unable to access medium \"%s\"", $medium->{name})), next;

	    #- try to get the description if it has been found.
	    unlink "$urpm->{statedir}/descriptions.$medium->{name}";
	    -e "$dir/../descriptions" and
	      system("cp", "-a", "$dir/../descriptions", "$urpm->{statedir}/descriptions.$medium->{name}");

	    #- if the source hdlist is present and we are not forcing using rpms file
	    if ($options{force} < 2 && $medium->{with_hdlist} && -e "$dir/$medium->{with_hdlist}") {
		unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
		system("cp", "-a", "$dir/$medium->{with_hdlist}", "$urpm->{cachedir}/partial/$medium->{hdlist}");
		
		-s "$urpm->{cachedir}/partial/$medium->{hdlist}"
		  or $error = 1, $urpm->{error}(_("copy of [%s] failed", "$dir/$medium->{with_hdlist}"));

		#- check if the file are equals...
		unless ($error) {
		    my @sstat = stat "$urpm->{cachedir}/partial/$medium->{hdlist}";
		    my @lstat = stat "$urpm->{statedir}/$medium->{hdlist}";
		    if ($sstat[7] == $lstat[7] && $sstat[9] == $lstat[9]) {
			#- the two files are considered equal here, the medium is so not modified.
			$medium->{modified} = 0;
			unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
			next;
		    }
		}
	    } else {
		#- try to find rpm files, use recursive method, added additional
		#- / after dir to make sure it will be taken into account if this
		#- is a symlink to a directory.
		#- make sure rpm filename format is correct and is not a source rpm
		#- which are not well managed by urpmi.
		@files = grep { $_ !~ /\.src\.rpm/ } split "\n", `find '$dir/' -name "*.rpm" -print`;

		#- check files contains something good!
		if (@files > 0) {
		    #- we need to rebuild from rpm files the hdlist.
		    eval {
			$urpm->{log}(_("building hdlist [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
			$urpm->{params}->build_hdlist($options{noclean}, $options{ratio} || 4, "$urpm->{cachedir}/headers",
						      "$urpm->{cachedir}/partial/$medium->{hdlist}", @files);
		    };
		    $@ and $error = 1, $urpm->{error}(_("unable to build hdlist: %s", $@));
		} else {
		    $error = 1;
		    $urpm->{error}(_("no rpm files found from [%s]", $dir));
		}
	    }
	} else {
	    my $basename = $medium->{with_hdlist} =~ /^.*\/([^\/]*)$/ && $1;

	    #- try to get the description if it has been found.
	    unlink "$urpm->{cachedir}/partial/descriptions";
	    rename "$urpm->{statedir}/descriptions.$medium->{name}", "$urpm->{cachedir}/partial/descriptions";
	    system("wget", "-NP", "$urpm->{cachedir}/partial", "$medium->{url}/../descriptions");
	    -e "$urpm->{cachedir}/partial/descriptions" and
	      rename "$urpm->{cachedir}/partial/descriptions", "$urpm->{statedir}/descriptions.$medium->{name}";

	    #- try to sync (copy if needed) local copy after restored the previous one.
	    unlink "$urpm->{cachedir}/partial/$basename";
	    $options{force} >= 2 || ! -e "$urpm->{statedir}/$medium->{hdlist}" or
	      system("cp", "-a", "$urpm->{statedir}/$medium->{hdlist}", "$urpm->{cachedir}/partial/$basename");
	    system("wget", "-NP", "$urpm->{cachedir}/partial", "$medium->{url}/$medium->{with_hdlist}");
	    $? == 0 or $error = 1, $urpm->{error}(_("wget of [%s] failed (maybe wget is missing?)",
						    "<source_url>/$medium->{with_hdlist}"));
	    -s "$urpm->{cachedir}/partial/$basename" or
	      $error = 1, $urpm->{error}(_("wget of [%s] failed", "<source_url>/$medium->{with_hdlist}"));
	    unless ($error) {
		my @sstat = stat "$urpm->{cachedir}/partial/$basename";
		my @lstat = stat "$urpm->{statedir}/$medium->{hdlist}";
		if ($sstat[7] == $lstat[7] && $sstat[9] == $lstat[9]) {
		    #- the two files are considered equal here, the medium is so not modified.
		    $medium->{modified} = 0;
		    unlink "$urpm->{cachedir}/partial/$basename";
		    next;
		}

		#- the file are different, update local copy.
		rename "$urpm->{cachedir}/partial/$basename", "$urpm->{cachedir}/partial/$medium->{hdlist}";
	    }
	}

	#- build list file according to hdlist used.
	unless (-s "$urpm->{cachedir}/partial/$medium->{hdlist}") {
	    $error = 1;
	    $urpm->{error}(_("no hdlist file found for medium \"%s\"", $medium->{name}));
	}

	#- make sure group and other does not have any access to this file.
	unless ($error) {
	    #- sort list file contents according to depslist.ordered file.
	    my %list;
	    if (@files) {
		foreach (@files) {
		    /\/([^\/]*)-[^-\/]*-[^-\/]*\.[^\/]*\.rpm/;
		    $list{"$prefix:/$_\n"} = ($urpm->{params}{info}{$1} || { id => 1000000000 })->{id};
		}
	    } else {
		local (*F, $_);
		open F, "parsehdlist '$urpm->{cachedir}/partial/$medium->{hdlist}' |";
		while (<F>) {
		    /^([^\/]*)-[^-\/]*-[^-\/]*\.[^\/]*\.rpm/;
		    $list{"$medium->{url}/$_"} = ($urpm->{params}{info}{$1} || { id => 1000000000 })->{id};
		}
		close F or $error = 1, $urpm->{error}(_("unable to parse hdlist file of \"%s\"", $medium->{name}));
	    }

	    #- check there is something found.
	    %list or $error = 1, $urpm->{error}(_("nothing to write in list file for \"%s\"", $medium->{name}));

	    #- write list file.
	    local *LIST;
	    my $mask = umask 077;
	    open LIST, ">$urpm->{cachedir}/partial/$medium->{list}"
	      or $error = 1, $urpm->{error}(_("unable to write list file of \"%s\"", $medium->{name}));
	    umask $mask;
	    print LIST sort { $list{$a} <=> $list{$b} } keys %list;
	    close LIST;

	    #- check if at least something has been written into list file.
	    -s "$urpm->{cachedir}/partial/$medium->{list}"
	      or $error = 1, $urpm->{error}(_("nothing written in list file for \"%s\"", $medium->{name}));
	}

	if ($error) {
	    #- an error has occured for updating the medium, we have to remove tempory files.
	    unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
	    unlink "$urpm->{cachedir}/partial/$medium->{list}";
	} else {
	    #- make sure to rebuild base files and clean medium modified state.
	    $medium->{modified} = 0;
	    $urpm->{modified} = 1;

	    #- but use newly created file.
	    unlink "$urpm->{statedir}/$medium->{hdlist}";
	    unlink "$urpm->{statedir}/$medium->{list}";
	    rename "$urpm->{cachedir}/partial/$medium->{hdlist}", "$urpm->{statedir}/$medium->{hdlist}";
	    rename "$urpm->{cachedir}/partial/$medium->{list}", "$urpm->{statedir}/$medium->{list}";

	    #- and create synthesis file associated.
	    $urpm->build_synthesis_hdlist($medium);
	}
    }

    #- build base files (depslist.ordered, provides, compss) according to modified global status.
    if ($urpm->{modified}) {
	#- special case if there is no more media registered.
	#- there is no need to recompute the hdlist and the files
	#- can be safely removed.
	if (@{$urpm->{media}} == 0) {
	    unlink $urpm->{depslist};
	    unlink $urpm->{provides};
	    unlink $urpm->{compss};

	    $urpm->{modified} = 0;
	}

	if ($options{force} < 1 && @{$urpm->{media}} == 1 && $urpm->{media}[0]{with_hdlist}) {
	    #- this is a special mode where is only one hdlist using a source hdlist, in such
	    #- case we are searching for source depslist, provides and compss files.
	    #- if they are not found or if force is used, an error message is printed and
	    #- we continue using computed results.
	    my $medium = $urpm->{media}[0];
	    my $basedir = $medium->{with_hdlist} =~ /^(.*)\/[^\/]*$/ && $1;

	    foreach my $target ($urpm->{depslist}, $urpm->{provides}, $urpm->{compss}, 'END') {
		$target eq 'END' and $urpm->{modified} = 0, last; #- assume everything is ok.
		my $basename = $target =~ /^.*\/([^\/]*)$/ && $1;

		if (my ($prefix, $dir) = $medium->{url} =~ /^(removable_.*?|file):\/(.*)/) {
		    #- the directory should be existing in any cases or this is an error
		    #- so there is no need of trying to mount it.
		    if (-e "$dir/$basedir/$basename") {
			system("cp", "-f", "$dir/$basedir/$basename", $target);
			$? == 0 or $urpm->{error}(_("unable to copy source of [%s] from [%s]",
						    $target, "$dir/$basedir/$basename")), last;
		    } else {
			$urpm->{error}(_("source of [%s] not found as [%s]", $target, "$dir/$basedir/$basename")), last;
		    }
		} else {
		    #- we have to use wget here instead.
		    system("wget", "-O", $target, "$medium->{url}/$basedir/$basename");
		    $? == 0 or $urpm->{error}(_("wget of [%s] failed (maybe wget is missing?)",
						"$medium->{url}/$basedir/$basename")), last;
		}
	    }
	}

	if ($urpm->{modified}) {
	    #- cleaning.
	    $urpm->{params}->clean();

	    foreach my $medium (@{$urpm->{media}}) {
		$medium->{ignore} and next;
		$urpm->{log}(_("reading hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
		$urpm->{params}->read_hdlists("$urpm->{statedir}/$medium->{hdlist}") or next;
	    }

	    $urpm->{log}(_("keeping only provides files"));
	    $urpm->{params}->keep_only_cleaned_provides_files();
	    foreach my $medium (@{$urpm->{media}}) {
		$medium->{ignore} and next;
		$urpm->{log}(_("reading hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
		$urpm->{params}->read_hdlists("$urpm->{statedir}/$medium->{hdlist}") or next;
		$urpm->{log}(_("computing dependencies"));
		$urpm->{params}->compute_depslist();
	    }

	    #- once everything has been computed, write back the files to
	    #- sync the urpmi database.
	    $urpm->write_base_files();
	    $urpm->{modified} = 0;
	}

	#- clean headers cache directory to remove everything that is no more
	#- usefull according to depslist used.
	if ($options{noclean}) {
	    local (*D, $_);
	    my %arch;
	    opendir D, "$urpm->{cachedir}/headers";
	    while (defined($_ = readdir D)) {
		/^([^\/]*)-([^-]*)-([^-]*)\.([^\.]*)$/ and $arch{"$1-$2-$3"} = $4;
	    }
	    closedir D;
	    $urpm->{log}(_("found %d headers in cache", scalar(keys %arch)));
	    foreach (@{$urpm->{params}{depslist}}) {
		delete $arch{"$_->{name}-$_->{version}-$_->{release}"};
	    }
	    $urpm->{log}(_("removing %d obsolete headers in cache", scalar(keys %arch)));
	    foreach (keys %arch) {
		unlink "$urpm->{cachedir}/headers/$_.$arch{$_}";
	    }
	}

	#- this file is written in any cases.
	$urpm->write_config();

	#- now everything is finished.
	system("sync");
    }
}

#- check for necessity of mounting some directory to get access
sub try_mounting {
    my ($urpm, $dir, $mode) = @_;

    if ($mode eq 'mount' ? !-e $dir : -e $dir) {
	my ($fdir, $pdir, $v, %fstab, @possible_mount_point) = $dir;

	#- read /etc/fstab and check for existing mount point.
	local (*F, $_);
	open F, "/etc/fstab";
	while (<F>) {
	    /^\s*\S+\s+(\/\S+)/ and $fstab{$1} = 0;
	}
	open F, "/etc/mtab";
	while (<F>) {
	    /^\s*\S+\s+(\/\S+)/ and $fstab{$1} = 1;
	}
	close F;

	#- try to follow symlink, too complex symlink graph may not
	#- be seen.
	while ($v = readlink $fdir) {
	    if ($fdir =~ /^\//) {
		$fdir = $v;
	    } else {
		while ($v =~ /^\.\.\/(.*)/) {
		    $v = $1;
		    $fdir =~ s/^(.*)\/[^\/]+\/*/$1/;
		}
		$fdir .= "/$v";
	    }
	}

	#- check the possible mount point.
	foreach (split '/', $fdir) {
	    length($_) or next;
	    $pdir .= "/$_";
	    foreach ($pdir, "$pdir/") {
		exists $fstab{$_} and push @possible_mount_point, $_;
	    }
	}

	#- try to mount or unmount according to mode.
	$mode ne 'mount' and @possible_mount_point = reverse @possible_mount_point;
	foreach (@possible_mount_point) {
	    $fstab{$_} == ($mode ne 'mount') and $fstab{$_} = ($mode eq 'mount'),
	      $urpm->{log}($mode eq 'mount' ? _("mounting %s", $_) : _("unmounting %s", $_)), `$mode '$_' 2>/dev/null`;
	}
    }
    $mode eq 'mount' ? -e $dir : !-e $dir;
}

#- read depslist file using rpmtools, this file is not managed directly by urpm.
sub read_depslist {
    my ($urpm) = @_;

    local *F;
    open F, $urpm->{depslist} or $urpm->{error}(_("unable to read depslist file [%s]", $urpm->{depslist})), return;
    $urpm->{params}->read_depslist(\*F);
    close F;
    $urpm->{log}(_("read depslist file [%s]", $urpm->{depslist}));
    1;
}

#- read providest file using rpmtools, this file is not managed directly by urpm.
sub read_provides {
    my ($urpm) = @_;

    local *F;
    open F, $urpm->{provides} or $urpm->{error}(_("unable to read provides file [%s]", $urpm->{provides})), return;
    $urpm->{params}->read_provides(\*F);
    close F;
    $urpm->{log}(_("read provides file [%s]", $urpm->{provides}));
    1;
}

#- read providest file using rpmtools, this file is not managed directly by urpm.
sub read_compss {
    my ($urpm) = @_;

    local *F;
    open F, $urpm->{compss} or $urpm->{error}(_("unable to read compss file [%s]", $urpm->{compss})), return;
    $urpm->{params}->read_compss(\*F);
    close F;
    $urpm->{log}(_("read compss file [%s]", $urpm->{compss}));
    1;
}

#- write base files using rpmtools, these files are not managed directly by urpm.
sub write_base_files {
    my ($urpm) = @_;
    local *F;

    open F, ">$urpm->{depslist}" or $urpm->{fatal}(6, _("unable to write depslist file [%s]", $urpm->{depslist}));
    $urpm->{params}->write_depslist(\*F);
    close F;
    $urpm->{log}(_("write depslist file [%s]", $urpm->{depslist}));

    open F, ">$urpm->{provides}" or $urpm->{fatal}(6, _("unable to write provides file [%s]", $urpm->{provides}));
    $urpm->{params}->write_provides(\*F);
    close F;
    $urpm->{log}(_("write provides file [%s]", $urpm->{provides}));

    open F, ">$urpm->{compss}" or $urpm->{fatal}(6, _("unable to write compss file [%s]", $urpm->{compss}));
    $urpm->{params}->write_compss(\*F);
    close F;
    $urpm->{log}(_("write compss file [%s]", $urpm->{compss}));
}

#- try to determine which package are belonging to which medium.
#- a flag active is used for that, transfered from medium to each
#- package.
#- relocation can use this flag after.
sub filter_active_media {
    my ($urpm, %options) = @_;
    my (%fullname2id);

    #- build association hash to retrieve id and examine all list files.
    foreach (0 .. $#{$urpm->{params}{depslist}}) {
	my $p = $urpm->{params}{depslist}[$_];
	$fullname2id{"$p->{name}-$p->{version}-$p->{release}.$p->{arch}"} = $_;
    }

    #- examine each medium to search for packages.
    #- now get rpm file name in hdlist to match list file.
    require packdrake;
    foreach my $medium (@{$urpm->{media} || []}) {
	if (-r "$urpm->{statedir}/$medium->{hdlist}" && ($medium->{active} ||
							 $options{use_update} && $medium->{update}) && !$medium->{ignore}) {
	    my $packer = eval { new packdrake("$urpm->{statedir}/$medium->{hdlist}"); };
	    $packer or $urpm->{error}(_("unable to parse correctly [%s]", "$urpm->{statedir}/$medium->{hdlist}")), next;
	    foreach (@{$packer->{files}}) {
		$packer->{data}{$_}[0] eq 'f' or next;
		if (my ($fullname) = /^([^:\s]*-[^:\-\s]+-[^:\-\s]+\.[^:\.\-\s]*)(?::\S+)?/) {
		    my $id = delete $fullname2id{$fullname};
		    defined $id and $urpm->{params}{depslist}[$id]{active} = 1;
		} else {
		    $urpm->{error}(_("unable to parse correctly [%s] on value \"%s\"", "$urpm->{statedir}/$medium->{hdlist}", $_));
		}
	    }
	}
    }
}

#- relocate depslist array id to use only the most recent packages,
#- reorder info hashes to give only access to best packages.
sub relocate_depslist {
    my ($urpm, %options) = @_;
    my $relocated_entries = undef;

    foreach (@{$urpm->{params}{depslist} || []}) {
	if ($options{use_active} && !$_->{active}) {
	    #- disable non active package if active flag should be checked.
	    $urpm->{params}{info}{$_->{name}} == $_ and delete $urpm->{params}{info}{$_->{name}};
	} elsif ($urpm->{params}{info}{$_->{name}} != $_) {
	    #- at this point, it is sure there is a package that
	    #- is multiply defined and this should be fixed.
	    #- remove access to info if arch is incompatible and only
	    #- take into account compatible arch to examine.
	    #- correct info hash by prefering first better version,
	    #- then better release, then better arch.
	    $relocated_entries ||= 0;
	    my $p = $urpm->{params}{info}{$_->{name}};
	    if ($p && (!rpmtools::compat_arch($p->{arch}) || $options{use_active} && !$p->{active})) {
		delete $urpm->{params}{info}{$_->{name}};
		$p = undef;
	    }
	    if (rpmtools::compat_arch($_->{arch})) {
		if ($p) {
		    my $cmp_version = $_->{serial} == $p->{serial} && rpmtools::version_compare($_->{version}, $p->{version});
		    my $cmp_release = $cmp_version == 0 && rpmtools::version_compare($_->{release}, $p->{release});
		    if ($_->{serial} > $p->{serial} || $cmp_version > 0 || $cmp_release > 0 ||
			($_->{serial} == $p->{serial} && $cmp_version == 0 && $cmp_release == 0 &&
			 rpmtools::better_arch($_->{arch}, $p->{arch}))) {
			$urpm->{params}{info}{$_->{name}} = $_;
			++$relocated_entries;
		    }
		} else {
		    $urpm->{params}{info}{$_->{name}} = $_;
		    ++$relocated_entries;
		}
	    }
	}
    }

    #- relocate id used in depslist array, delete id if the package
    #- should NOT be used.
    if (defined $relocated_entries) {
	foreach (@{$urpm->{params}{depslist}}) {
	    unless ($_->{source}) { #- hack to avoid losing local package.
		my $p = $urpm->{params}{info}{$_->{name}};
		if (defined $p) {
		    if ($_->{id} != $p->{id}) {
			$p->{relocated} .= " $_->{id}";
		    }
		} else {
		    delete $_->{id};
		}
	    }
	}
    }

    $urpm->{log}(_("relocated %s entries in depslist", $relocated_entries));
    $relocated_entries;
}

#- register local packages for being installed, keep track of source.
sub register_local_packages {
    my ($urpm, @files) = @_;
    my ($error, @names);

    #- examine each rpm and build the depslist for them using current
    #- depslist and provides environment.
    foreach (@files) {
	/(.*\/)?[^\/]*\.rpm$/ or $error = 1, $urpm->{error}(_("invalid rpm file name [%s]", $_)), next;
	-r $_ or $error = 1, $urpm->{error}(_("unable to access rpm file [%s]", $_)), next;

	my ($name) = $urpm->{params}->read_rpms($_);
	if ($name =~ /(.*)-([^-]*)-([^-]*)\.([^-\.]*)/) {
	    my $pkg = $urpm->{params}{info}{$1};
	    $pkg->{version} eq $2 or $urpm->{error}(_("mismatch version for registering rpm file")), next;
	    $pkg->{release} eq $3 or $urpm->{error}(_("mismatch release for registering rpm file")), next;
	    $pkg->{arch} eq $4 or $urpm->{error}(_("mismatch arch for registering rpm file")), next;
	    $pkg->{source} = $1 ? $_ :  "./$_";
	    push @names, $name;
	} else {
	    $urpm->{fatal}(7, _("rpmtools package is too old, please upgrade it"));
	}
    }
    $error and die "error registering local packages";

    #- compute depslist associated.
    $urpm->{params}->compute_depslist;

    #- return package names...
    @names;
}

#- search packages registered by their name by storing their id into packages hash.
sub search_packages {
    my ($urpm, $packages, $names, %options) = @_;
    my (%exact, %exact_a, %exact_ra, %found, %foundi);

    foreach my $v (@$names) {
	#- it is a way of speedup, providing the name of a package directly help
	#- to find the package.
	#- this is necessary if providing a name list of package to upgrade.
	if ($urpm->{params}{info}{$v} && defined $urpm->{params}{info}{$v}{id}) {
	    $exact{$v} = $urpm->{params}{info}{$v}{id};
	    next;
	}

	my $qv = quotemeta $v;

	if ($options{use_provides}) {
	    #- try to search through provides.
	    if (my $provide_v = $urpm->{params}{provides}{$v}) {
		if (@{$provide_v} == 1 &&
		    $urpm->{params}{info}{$provide_v->[0]} &&
		    defined $urpm->{params}{info}{$provide_v->[0]}{id}) {
		    #- we assume that if the there is only one package providing the resource exactly,
		    #- this should be the best one that is described.
		    $exact{$v} = $urpm->{params}{info}{$provide_v->[0]}{id};
		    next;
		}
	    }

	    foreach (keys %{$urpm->{params}{provides}}) {
		#- search through provides to find if a provide match this one.
		/$qv/ and push @{$found{$v}}, grep { defined $_ }
		  map { $urpm->{params}{info}{$_}{id} } @{$urpm->{params}{provides}{$_}};
		/$qv/i and push @{$found{$v}}, grep { defined $_ }
		  map { $urpm->{params}{info}{$_}{id} } @{$urpm->{params}{provides}{$_}};
	    }
	}

	my $id = 0;
	foreach my $info (@{$urpm->{params}{depslist}}) {
	    rpmtools::compat_arch($info->{arch}) && (!$options{use_active} || $info->{active}) or next;

	    my $pack_ra = "$info->{name}-$info->{version}";
	    my $pack_a = "$pack_ra-$info->{release}";
	    my $pack = "$pack_a.$info->{arch}";

	    if ($pack eq $v) {
		$exact{$v} = $id;
		next;
	    } elsif ($pack_a eq $v) {
		push @{$exact_a{$v}}, $id;
		next;
	    } elsif ($pack_ra eq $v) {
		push @{$exact_ra{$v}}, $id;
		next;
	    }

	    $pack =~ /$qv/ and push @{$found{$v}}, $id;
	    $pack =~ /$qv/i and push @{$foundi{$v}}, $id;

	    ++$id;
	}
    }

    my $result = 1;
    foreach (@$names) {
	if (defined $exact{$_}) {
	    $packages->{$exact{$_}} = undef;
	} else {
	    #- at this level, we need to search the best package given for a given name,
	    #- always prefer alread found package.
	    my %l;
	    foreach (@{$exact_a{$_} || $exact_ra{$_} || $found{$_} || $foundi{$_} || []}) {
		my $info = $urpm->{params}{depslist}[$_];
		push @{$l{$info->{name}}}, { id => $_, info => $info };
	    }
	    if (values(%l) == 0) {
		$urpm->{error}(_("no package named %s", $_));
		$result = 0;
	    } elsif (values(%l) > 1 && !$options{all}) {
		$urpm->{error}(_("The following packages contain %s: %s", $_, join(' ', keys %l)));
		$result = 0;
	    } else {
		foreach (values %l) {
		    my $best;
		    foreach (@$_) {
			if ($best) {
			    my $cmp_version = ($_->{info}{serial} == $best->{info}{serial} &&
					       rpmtools::version_compare($_->{info}{version}, $best->{info}{version}));
			    my $cmp_release = $cmp_version == 0 && rpmtools::version_compare($_->{info}{release},
											     $best->{info}{release});
			    if ($_->{info}{serial} > $best->{info}{serial} || $cmp_version > 0 || $cmp_release > 0 ||
				($_->{info}{serial} == $best->{info}{serial} && $cmp_version == 0 && $cmp_release == 0 &&
				 better_arch($_->{info}{arch}, $best->{info}{arch}))) {
				$best = $_;
			    }
			} else {
			    $best = $_;
			}
		    }
		    $packages->{$best->{id}} = undef;
		}
	    }
	}
    }

    #- return true if no error have been encoutered, else false.
    $result;
}

#- compute the closure of a list, mostly internal function for filter_packages_to_upgrade.
#- limited to values in packages which should not be a reference.
#- package are identified by their id.
sub compute_closure {
    my ($urpm, $packages, $installed, $select_choices) = @_;
    my ($id, @packages) = (undef, keys %$packages);

    #- at this level, compute global closure of what is requested, regardless of
    #- choices for which all package in the choices are taken and their dependencies.
    #- allow iteration over a modifying list.
    while (defined($id = shift @packages)) {
	#- get a relocated id if possible, by this way.
	$id = $urpm->{params}{depslist}[$id]{id};
	defined $id or next; #- this means we have an incompatible arch only (uggly and test it?)

	#- avoid a package if it has already been dropped in the sense of
	#- selected directly by another way.
	foreach ($id, split ' ', $urpm->{params}{depslist}[$id]{deps}) {
	    if (/\|/) {
		my ($follow_id, @upgradable_choices);
		my @choices = map { $urpm->{params}{depslist}[$_]{id} } split /\|/, $_;
		foreach (@choices) {
		    $installed && $installed->{$_} and $follow_id = -1, last;
		    exists $packages->{$_} && ! ref $packages->{$_} and $follow_id = $_, last;
		    $installed && exists $installed->{$_} and push @upgradable_choices, $_;
		}
		unless ($follow_id) {
		    #- if there are at least one upgradable choice, use it instead
		    #- of asking the user to chose among a list.
		    if (@upgradable_choices == 1) {
			push @packages, $upgradable_choices[0];
		    } else {
			@upgradable_choices > 1 and @choices = @upgradable_choices;
			$select_choices and push @packages, $select_choices->($urpm, @choices);
			foreach (@choices) {
			    push @{$packages->{$_} ||= []}, \@choices;
			}
		    }
		}
	    } else {
		local $_ = $urpm->{params}{depslist}[$_]{id};
		if (ref $packages->{$_}) {
		    #- all the choices associated here have to be dropped, need to copy else
		    #- there could be problem with foreach on a modifying list.
		    foreach my $choices (@{$packages->{$id}}) {
			foreach (@$choices) {
			    $packages->{$_} = [ grep { $_ != $choices } @{$packages->{$_}} ];
			    @{$packages->{$_}} > 0 or delete $packages->{$_};
			}
		    }
		}
		if ($installed && $installed->{$_}) {
		    delete $packages->{$_};
		} else {
		    exists $packages->{$_} or $packages->{$_} = $installed && ! exists $installed->{$_};
		}
	    }
	}
    }
}

#- filter the packages list (assuming only the key is registered, so undefined
#- value stored) to keep only packages that need to be upgraded,
#- additionnal packages will be stored using non null values,
#- choice will have a list of other choices as values,
#- initial packages will have a 0 stored as values.
#- options allow changing some behaviour of the algorithms:
#-   complete -> perform a complete closure before trying to look for upgrade.
sub filter_packages_to_upgrade {
    my ($urpm, $packages, $select_choices, %options) = @_;
    my ($id, %closures, %installed, @packages_installed);
    my $db = rpmtools::db_open(''); #- keep it open for all operation that could be done.

    #- request the primary list to rpmlib if complete mode is not activated.
    if (!$options{complete}) {
	#- there are not too many packages selected here to allow
	#- take care of package up-to-date at this point,
	#- so check version and if the package does not need to
	#- updated, ignore it and his dependencies.
	rpmtools::db_traverse_tag($db, "name", [ map { $urpm->{params}{depslist}[$_]{name} } keys %$packages ],
				  [ qw(name version release serial) ], sub {
				      my ($p) = @_;
				      my $pkg = $urpm->{params}{info}{$p->{name}};
				      if ($pkg) {
					  my $cmp = rpmtools::version_compare($pkg->{version}, $p->{version});
					  $installed{$pkg->{id}} = !($pkg->{serial} > $p->{serial} ||
								     $pkg->{serial} == $p->{serial} &&
								     ($cmp > 0 || $cmp == 0 &&
								      rpmtools::version_compare($pkg->{release},
												$p->{release}) > 0))
					    and delete $packages->{$pkg->{id}};
				      }
				  });
    }

    #- select first level of packages, as in packages list will only be
    #- examined deps of each.
    #- at this level, compute global closure of what is requested, regardless of
    #- choices for which all package in the choices are taken and their dependencies.
    #- allow iteration over a modifying list.
    @closures{keys %$packages} = ();
    $urpm->compute_closure(\%closures, undef, sub { my ($urpm, @l) = @_; @l });

    #- closures has been done so that its keys are the package that may be examined.
    #- according to number of keys, get all package installed or only the necessary
    #- packages.
    my $examine_installed_packages = sub {
	my ($p) = @_;
	my $pkg = $urpm->{params}{info}{$p->{name}};
	if ($pkg && exists $closures{$pkg->{id}}) {
	    my $cmp = rpmtools::version_compare($pkg->{version}, $p->{version});
	    $installed{$pkg->{id}} = !($pkg->{serial} > $p->{serial} || $pkg->{serial} == $p->{serial} &&
				       ($cmp > 0 || $cmp == 0 && rpmtools::version_compare($pkg->{release}, $p->{release}) > 0))
	      and delete $packages->{$pkg->{id}};
	}
    };
    #- do not take care of already examined packages.
    delete @closures{keys %installed};
    if (scalar(keys %closures) < 100) {
	rpmtools::db_traverse_tag($db, "name", [ map { $urpm->{params}{depslist}[$_]{name} } keys %closures ],
				  [ qw(name version release serial) ], $examine_installed_packages);
    } else {
	rpmtools::db_traverse($db, [ qw(name version release serial) ], $examine_installed_packages);
    }
    rpmtools::db_close($db);

    #- recompute closure but ask for which package to select on a choices.
    #- this is necessary to have the result before the end else some dependency may
    #- be losed or added.
    #- accept no choice allow to browse list, and to compute it with more iteration.
    %closures = (); @closures{keys %$packages} = ();
    $urpm->compute_closure(\%closures, \%installed, $select_choices);

    #- restore package to match selection done, update the values according to
    #- need upgrade (0), requested (undef), already installed (not present) or
    #- newly added (1).
    #- choices if not chosen are present as ref.
    foreach (keys %closures) {
	exists $packages->{$_} or $packages->{$_} = $closures{$_};
    }

    $packages;
}

#- filter minimal list, upgrade packages only according to rpm requires
#- satisfied, remove upgrade for package already installed or with a better
#- version, try to upgrade to minimize upgrade errors.
#- all additional package selected have a true value.
sub filter_minimal_packages_to_upgrade {
    my ($urpm, $packages, $select_choices, %options) = @_;

    #- make a subprocess here for reading filelist, this is important
    #- not to waste a lot of memory for the main program which will fork
    #- latter for each transaction.
    local (*INPUT, *OUTPUT_CHILD);
    local (*INPUT_CHILD, *OUTPUT);
    my $pid = 1;

    #- try to figure out if parsehdlist need to be called,
    #- or we have to use synthesis file.
    my @synthesis = map { "$urpm->{statedir}/synthesis.$_->{hdlist}" } grep { ! $_->{ignore} } @{$urpm->{media}};
    if (grep { ! -r $_ || ! -s $_ } @synthesis) {
	$urpm->{log}(_("unable to find all synthesis file, using parsehdlist server"));
	pipe INPUT, OUTPUT_CHILD;
	pipe INPUT_CHILD, OUTPUT;
	$pid = fork();
    } else {
	foreach (@synthesis) {
	    local *F;
	    open F, "gzip -dc '$_' |";
	    local $_;
	    my %info;
	    my $update_info = sub {
		my $found;
		#- check with provides that version and release are matching else ignore safely.
		#- simply ignore src rpm, which does not have any provides.
		$info{name} && $info{provides} or return;
		foreach (@{$info{provides}}) {
		    if (/(\S*)\s*==\s*(?:\d+:)?([^-]*)-([^-]*)/ && $info{name} eq $1) {
			$found = $urpm->{params}{info}{$info{name}};
			foreach ($found, map { $urpm->{params}{depslist}[$_] } split ' ', $found->{relocated}) {
			    if ($_->{version} eq $2 && $_->{release} eq $3) {
				foreach my $tag (keys %info) {
				    $_->{$tag} ||= $info{$tag};
				}
				return 1; #- we have found the right info.
			    }
			}
		    }
		}
		$found and return 0;  #- we are sure having found a package but with wrong version or release.
		#- at this level, nothing in params has been found, this could be an error so
		#- at least print an error message.
		$urpm->{error}(_("unknown data associated with %s", $info{name}));
		return;
	    };
	    while (<F>) {
		chomp;
		my ($name, $tag, @data) = split '@';
		if ($name ne $info{name}) {
		    $update_info->();
		    %info = ( name => $name );
		}
		$info{$tag} = \@data;
	    }
	    $update_info->();
	    close F;
	}
    }

    if ($pid) {
	close INPUT_CHILD;
	close OUTPUT_CHILD;
	select((select(OUTPUT), $| = 1)[0]);

	#- internal reading from interactive mode of parsehdlist.
	#- takes a code to call with the line read, this avoid allocating
	#- memory for that.
	my $ask_child = sub {
	    my ($name, $tag, $code) = @_;
	    $code or die "no callback code for parsehdlist output";
	    if ($pid == 1) {
		my $p = $urpm->{params}{info}{$name};
		if (!$p && $name =~ /(.*)-([^\-]*)-([^\-]*)\.([^\-\.]*)$/) {
		    foreach ($urpm->{params}{info}{$1}{id}, split ' ', $urpm->{params}{info}{$1}{relocated}) {
			$p = $urpm->{params}{depslist}[$_];
			$p->{version} eq $2 && $p->{release} eq $3 && $p->{arch} eq $4 and last;
			$p = undef;
		    }
		}
		foreach (@{$p->{$tag} || []}) {
		    $code->($_);
		}
	    } else {
		print OUTPUT "$name:$tag\n";

		local $_;
		while (<INPUT>) {
		    chomp;
		    /^\s*$/ and last;
		    $code->($_);
		}
	    }
	};

	my ($db, @packages) = (rpmtools::db_open(''), keys %$packages);
	my ($id, %installed);

	#- at this level, compute global closure of what is requested, regardless of
	#- choices for which all package in the choices are taken and their dependencies.
	#- allow iteration over a modifying list.
	while (defined($id = shift @packages)) {
	    if (ref $id) {
		#- at this point we have almost only choices to resolves.
		#- but we have to check if one package here is already selected
		#- previously, if this is the case, use it instead.
		foreach (@$id) {
		    exists $packages->{$_} and $id = undef, last;
		}
		defined $id or next;

		#- propose the choice to the user now, or select the best one (as it is supposed to be).
		my @selection = $select_choices ? ($select_choices->($urpm, @$id)) : ($id->[0]);
		foreach (@selection) {
		    unshift @packages, $_;
		    exists $packages->{$_} or $packages->{$_} = 1;
		}
	    }
	    my $pkg = $urpm->{params}{depslist}[$id];
	    defined $pkg->{id} or next; #- id has been removed for package that only exists on some arch.

	    #- search for package that will be upgraded, and check the difference
	    #- of provides to see if something will be altered and need to be upgraded.
	    #- this is bogus as it only take care of == operator if any.
	    #- defining %provides here could slow the algorithm but it solves multi-pass
	    #- where a provides is A and after A == version-release, when A is already
	    #- installed.
	    my (%diffprovides, %provides);
	    rpmtools::db_traverse_tag($db,
				      'name', [ $pkg->{name} ],
				      [ qw(name version release sense provides) ], sub {
					  my ($p) = @_;
					  foreach (@{$p->{provides}}) {
					      s/\[\*\]//;
					      s/\[([^\]]*)\]/ $1/;
					      /^(\S*\s*\S*\s*)(\d+:)?([^\s-]*)(-?\S*)/;
					      foreach ($_, "$1$3", "$1$2$3", "$1$3$4") {
						  $diffprovides{$_} = "$p->{name}-$p->{version}-$p->{release}";
					      }
					  }
				      });
	    $ask_child->("$pkg->{name}-$pkg->{version}-$pkg->{release}.$pkg->{arch}", "provides", sub {
			     $_[0] =~ /^(\S*\s*\S*\s*)(\d+:)?([^\s-]*)(-?\S*)/;
			     foreach ($_[0], "$1$3", "$1$2$3", "$1$3$4") {
				 delete $diffprovides{$_[0]};
			     }
			 });
	    foreach ($pkg->{name}, "$pkg->{name} == $pkg->{version}", "$pkg->{name} == $pkg->{version}-$pkg->{release}") {
		delete $diffprovides{$_};
	    }
	    delete $diffprovides{""};

	    foreach (keys %diffprovides) {
		#- check for exact match on it.
		if (/^(\S*)\s*(\S*)\s*(\d+:)?([^\s-]*)-?(\S*)/) {
		    rpmtools::db_traverse_tag($db,
					      'whatrequires', [ $1 ],
					      [ qw(name version release sense requires) ], sub{
						  my ($p) = @_;
						  foreach (@{$p->{requires}}) {
						      s/\[\*\]//;
						      s/\[([^\]]*)\]/ $1/;
						      exists $diffprovides{$_} and $provides{$p->{name}} = undef;
						  }
					      });
		}
	    }

	    #- iterate over requires of the packages, register them.
	    $provides{$pkg->{name}} = undef; #"$pkg->{name}-$pkg->{version}-$pkg->{release}";
	    $ask_child->("$pkg->{name}-$pkg->{version}-$pkg->{release}.$pkg->{arch}", "requires", sub {
			     if ($_[0] =~ /^(\S*)\s*(\S*)\s*([^\s\-]*)-?(\S*)/) {
				 exists $provides{$1} and return;
				 #- if the provides is not found, it will be resolved at next step, else
				 #- it will be resolved by searching the rpm database.
				 $provides{$1} ||= undef;
				 my $check_pkg = sub {
				     $3 and eval(rpmtools::version_compare($_[0]{version}, $3) . $2 . 0) || return;
				     $4 and eval(rpmtools::version_compare($_[0]{release}, $4) . $2 . 0) || return;
				     $provides{$1} = "$_[0]{name}-$_[0]{version}-$_[0]{release}";
				 };
				 rpmtools::db_traverse_tag($db, 'whatprovides', [ $1 ],
							   [ qw (name version release) ], $check_pkg);
				 rpmtools::db_traverse_tag($db, 'path', [ $1 ],
							   [ qw (name version release) ], $check_pkg);
			     }
			 });

	    #- at this point, all unresolved provides (requires) should be fixed by
	    #- provides files, try to minimize choice at this level.
	    foreach (keys %provides) {
		$provides{$_} and next;
		my (@choices, @upgradable_choices);
		foreach (@{$urpm->{params}{provides}{$_}}) {
		    #- prefer upgrade package that need to be upgraded, if they are present in the choice.
		    my $pkg = $urpm->{params}{info}{$_};
		    if (my @best = grep { exists $packages->{$_->{id}} }
			($pkg, map { $urpm->{params}{depslist}[$_] } split ' ', $pkg->{relocated})) {
			$pkg = $best[0]; #- keep already requested packages.
		    }
		    push @choices, $pkg;
		    rpmtools::db_traverse_tag($db,
					      'name', [ $_ ],
					      [ qw(name version release serial) ], sub {
						  my ($p) = @_;
						  my $cmp = rpmtools::version_compare($pkg->{version}, $p->{version});
						  $installed{$pkg->{id}} ||= !($pkg->{serial} > $p->{serial} || $pkg->{serial} == $p->{serial} && ($cmp > 0 || $cmp == 0 && rpmtools::version_compare($pkg->{release}, $p->{release}) > 0))
					      });
		    $installed{$pkg->{id}} and delete $packages->{$pkg->{id}};
		    if (exists $packages->{$pkg->{id}} || $installed{$pkg->{id}}) {
			#- the package is already selected, or installed with a better version and release.
			@choices = @upgradable_choices = ();
			last;
		    }
		    exists $installed{$pkg->{id}} and push @upgradable_choices, $pkg;
		}
		@upgradable_choices > 0 and @choices = @upgradable_choices;
		if (@choices > 0) {
		    if (@choices == 1) {
			exists $packages->{$choices[0]{id}} or $packages->{$choices[0]{id}} = 1;
			unshift @packages, $choices[0]{id};
		    } else {
			push @packages, [ sort { $a <=> $b } map { $_->{id} } @choices ];
		    }
		}
	    }
	}

	rpmtools::db_close($db);

	#- no need to still use the child as this point, we can let him to terminate.
	if ($pid > 1) {
	    close OUTPUT;
	    close INPUT;
	    waitpid $pid, 0;
	}
    } else {
	close INPUT;
	close OUTPUT;
	open STDIN, "<&INPUT_CHILD";
	open STDOUT, ">&OUTPUT_CHILD";
	exec "parsehdlist", "--interactive", map { "$urpm->{statedir}/$_->{hdlist}" } grep { ! $_->{ignore} } @{$urpm->{media}}
	  or rpmtools::_exit(1);
    }
}

#- get out of package that should not be upgraded.
sub deselect_unwanted_packages {
    my ($urpm, $packages, %options) = @_;

    my %skip;
    local ($_, *F);
    open F, $urpm->{skiplist};
    while (<F>) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	my $pkg = $urpm->{params}{info}{$_} or next;
	$options{force} || (exists $packages->{$pkg->{id}} && defined $packages->{$pkg->{id}}) and delete $packages->{$pkg->{id}};
    }
    close F;
}

#- select source for package selected.
#- according to keys given in the packages hash.
#- return a list of list containing the source description for each rpm,
#- match exactly the number of medium registered, ignored medium always
#- have a null list.
sub get_source_packages {
    my ($urpm, $packages) = @_;
    my ($error, @local_to_removes, @local_sources, @list, %fullname2id, %file2fullnames);
    local (*D, *F, $_);

    #- build association hash to retrieve id and examine all list files.
    foreach (keys %$packages) {
	my $p = $urpm->{params}{depslist}[$_];
	$fullname2id{"$p->{name}-$p->{version}-$p->{release}.$p->{arch}"} = $_;
    }

    #- examine each medium to search for packages.
    #- now get rpm file name in hdlist to match list file.
    require packdrake;
    foreach my $medium (@{$urpm->{media} || []}) {
	if (-r "$urpm->{statedir}/$medium->{hdlist}" && -r "$urpm->{statedir}/$medium->{list}" && !$medium->{ignore}) {
	    my $packer = eval { new packdrake("$urpm->{statedir}/$medium->{hdlist}"); };
	    $packer or $urpm->{error}(_("unable to parse correctly [%s]", "$urpm->{statedir}/$medium->{hdlist}")), next;
	    foreach (@{$packer->{files}}) {
		$packer->{data}{$_}[0] eq 'f' or next;
		if (my ($fullname, $file) = /^([^:\s]*-[^:\-\s]+-[^:\-\s]+\.[^:\.\-\s]*)(?::(\S+))?/) {
		    $file2fullnames{$file || $fullname}{$fullname} = undef;
		} else {
		    $urpm->{error}(_("unable to parse correctly [%s] on value \"%s\"", "$urpm->{statedir}/$medium->{hdlist}", $_));
		}
	    }
	}
    }

    #- examine the local repository, which is trusted.
    opendir D, "$urpm->{cachedir}/rpms";
    while (defined($_ = readdir D)) {
	if (/([^\/]*)\.rpm/) {
	    if (keys(%{$file2fullnames{$1} || {}}) > 1) {
		$urpm->{error}(_("there are multiples packages with the same rpm filename \"%s\""), $1);
		next;
	    } elsif (keys(%{$file2fullnames{$1} || {}}) == 1) {
		my ($fullname) = keys(%{$file2fullnames{$2} || {}});
		if (defined delete $fullname2id{$fullname}) {
		    push @local_sources, "$urpm->{cachedir}/rpms/$1.rpm";
		} else {
		    push @local_to_removes, "$urpm->{cachedir}/rpms/$1.rpm";
		}
	    }
	} #- no error on unknown filename located in cache (because .listing)
    }
    closedir D;

    foreach my $medium (@{$urpm->{media} || []}) {
	my @sources;

	if (-r "$urpm->{statedir}/$medium->{hdlist}" && -r "$urpm->{statedir}/$medium->{list}" && !$medium->{ignore}) {
	    open F, "$urpm->{statedir}/$medium->{list}";
	    while (<F>) {
		if (/(.*)\/([^\/]*)\.rpm$/) {
		    if (keys(%{$file2fullnames{$2} || {}}) > 1) {
			$urpm->{error}(_("there are multiples packages with the same rpm filename \"%s\""), $2);
			next;
		    } elsif (keys(%{$file2fullnames{$2} || {}}) == 1) {
			my ($fullname) = keys(%{$file2fullnames{$2} || {}});
			defined delete $fullname2id{$fullname} and push @sources, "$1/$2.rpm";
		    }
		} else {
		    chomp;
		    $error = 1;
		    $urpm->{error}(_("unable to parse correctly [%s] on value \"%s\"", "$urpm->{statedir}/$medium->{list}", $_));
		    last;
		}
	    }
	    close F;
	}
	push @list, \@sources;
    }

    #- examine package list to see if a package has not been found.
    foreach (keys %fullname2id) {
	$error = 1;
	$urpm->{error}(_("package %s is not found.", $_));
    }	

    $error ? () : ( \@local_sources, \@list, \@local_to_removes );
}

#- upload package that may need to be uploaded.
#- make sure header are available in the appropriate directory.
#- change location to find the right package in the local
#- filesystem for only one transaction.
#- try to mount/eject removable media here.
#- return a list of package ready for rpm.
sub upload_source_packages {
    my ($urpm, $local_sources, $list, $force_local, $ask_for_medium) = @_;
    my (@sources, @distant_sources, %media, %removables);

    #- make sure everything is correct on input...
    @{$urpm->{media}} == @$list or return;

    #- removable media have to be examined to keep mounted the one that has
    #- more package than other (size is better ?).
    my $examine_removable_medium = sub {
	my ($id, $device, $copy) = @_;
	my $medium = $urpm->{media}[$id];
	$media{$id} = undef;
	if (my ($prefix, $dir) = $medium->{url} =~ /^(removable_[^:]*|file):\/(.*)/) {
	    until (-e $dir) {
		#- the directory given does not exist or may be accessible
		#- by mounting some other. try to figure out these directory and
		#- mount everything necessary.
		unless ($urpm->try_mounting($dir, 'mount')) {
		    $urpm->try_mounting($dir, 'unmount'); system("eject", $device);
		    $ask_for_medium->($medium->{name}, $medium->{removable}) or
		      $urpm->{fatal}(4, _("removable medium not selected"));
		}
	    }
	    if (-e $dir) {
		my @removable_sources;
		foreach (@{$list->[$id]}) {
		    /^(removable_[^:]*|file):\/(.*\/([^\/]*))/ or next;
		    -r $2 or $urpm->{error}(_("unable to read rpm file [%s] from medium \"%s\"", $2, $medium->{name}));
		    if ($copy) {
			push @removable_sources, $2;
			push @sources, "$urpm->{cachedir}/rpms/$3";
		    } else {
			push @sources, $2;
		    }
		}
		if (@removable_sources) {
		    system("cp", "-a", @removable_sources, "$urpm->{cachedir}/rpms");
		}
	    } else {
		$urpm->{error}(_("medium \"%s\" is not selected", $medium->{name}));
	    }
	} else {
	    #- we have a removable device that is not removable, well...
	    $urpm->{error}(_("incoherent medium \"%s\" marked removable but not really", $medium->{name}));
	}
    };
    foreach (0..$#$list) {
	@{$list->[$_]} or next;
	my $medium = $urpm->{media}[$_];
	#- examine non removable device but that may be mounted.
	if ($medium->{removable}) {
	    push @{$removables{$medium->{removable}} ||= []}, $_;
	} elsif (my ($prefix, $dir) = $medium->{url} =~ /^(removable_[^:]*|file):\/(.*)/) {
	    -e $dir || $urpm->try_mounting($dir, 'mount') or
	      $urpm->{error}(_("unable to access medium \"%s\"", $medium->{name})), next;
	}
    }
    foreach my $device (keys %removables) {
	#- here we have only removable device.
	#- if more than one media use this device, we have to sort
	#- needed package to copy first the needed rpms files.
	if (@{$removables{$device}} > 1) {
	    my @sorted_media = sort { @{$list->[$a]} <=> @{$list->[$b]} } @{$removables{$device}};

	    #- mount all except the biggest one.
	    foreach (@sorted_media[0 .. $#sorted_media-1]) {
		$examine_removable_medium->($_, $device, 'copy');
	    }
	    #- now mount the last one...
	    $removables{$device} = [ $sorted_media[-1] ];
	}

	#- mount the removable device, only one or the important one.
	$examine_removable_medium->($removables{$device}[0], $device);
    }

    #- get back all ftp and http accessible rpms file into the local cache
    #- if necessary (as used by checksig or any other reasons).
    #- we are using wget for that with an input from its stdin.
    foreach (0..$#$list) {
	exists $media{$_} and next;
	@{$list->[$_]} or next;
	foreach (@{$list->[$_]}) {
	    if (/^(removable_[^:]*|file):\/(.*)/) {
		push @sources, $2;
	    } elsif (/^([^:]*):\/(.*\/([^\/]*))/) {
		if ($force_local) {
		    push @distant_sources, $_;
		    push @sources, "$urpm->{cachedir}/rpms/$3";
		} else {
		    push @sources, $_;
		}
	    } else {
		$urpm->{error}(_("malformed input: [%s]", $_));
	    }
	}
    }
    foreach (@distant_sources) {
	$urpm->{log}(_("retrieving [%s]", $_));
	system "wget", "-NP", "$urpm->{cachedir}/rpms", $_;
	$? == 0 or $urpm->{error}(_("wget of [%s] failed", "<source_url>/$_"));
    }

    #- return the list of rpm file that have to be installed, they are all local now.
    @$local_sources, @sources;
}

sub select_packages_to_upgrade {
    my ($urpm, $prefix, $packages, $remove_packages, $keep_files) = @_;
    my $db = rpmtools::db_open($prefix);

    #- used for package that are not correctly updated.
    #- should only be used when nothing else can be done correctly.
    my %upgradeNeedRemove = (
			     'libstdc++' => 1,
			     'compat-glibc' => 1,
			     'compat-libs' => 1,
			    );

    #- help removing package which may have different release numbering
    my %toRemove;

    #- help searching package to upgrade in regard to already installed files.
    my %installedFilesForUpgrade;

    #- help keeping memory by this set of package that have been obsoleted.
    my %obsoletedPackages;

    #- make a subprocess here for reading filelist, this is important
    #- not to waste a lot of memory for the main program which will fork
    #- latter for each transaction.
    local (*INPUT, *OUTPUT_CHILD); pipe INPUT, OUTPUT_CHILD;
    local (*INPUT_CHILD, *OUTPUT); pipe INPUT_CHILD, OUTPUT;
    if (my $pid = fork()) {
	close INPUT_CHILD;
	close OUTPUT_CHILD;
	select((select(OUTPUT), $| = 1)[0]);

	#- internal reading from interactive mode of parsehdlist.
	#- takes a code to call with the line read, this avoid allocating
	#- memory for that.
	my $ask_child = sub {
	    my ($name, $tag, $code) = @_;
	    $code or die "no callback code for parsehdlist output";
	    print OUTPUT "$name:$tag\n";

	    local $_;
	    while (<INPUT>) {
		chomp;
		/^\s*$/ and last;
		$code->($_);
	    }
	};

	#- select packages which obseletes other package, obselete package are not removed,
	#- should we remove them ? this could be dangerous !
	foreach my $pkg (values %{$urpm->{params}{info}}) {
	    $ask_child->($pkg->{name}, "obsoletes", sub {
			     #- take care of flags and version and release if present
			     if ($_[0] =~ /^(\S*)\s*(\S*)\s*([^\s-]*)-?(\S*)/ &&
				 rpmtools::db_traverse_tag($db, "name", [$1], [], undef) > 0) {
				 $3 and eval(rpmtools::version_compare($pkg->{version}, $3) . $2 . 0) or next;
				 $4 and eval(rpmtools::version_compare($pkg->{release}, $4) . $2 . 0) or next;
				 $urpm->{log}(_("selecting %s using obsoletes", "$pkg->{name}-$pkg->{version}-$pkg->{release}"));
				 $obsoletedPackages{$1} = undef;
				 $pkg->{selected} = 1;
			     }
			 });
	}

	#- mark all files which are not in /etc/rc.d/ for packages which are already installed but which
	#- are not in the packages list to upgrade.
	#- the 'installed' property will make a package unable to be selected, look at select.
	rpmtools::db_traverse($db, [ qw(name version release serial files) ], sub {
				  my ($p) = @_;
				  my $otherPackage = $p->{release} !~ /mdk\w*$/ && "$p->{name}-$p->{version}-$p->{release}";
				  my $pkg = $urpm->{params}{info}{$p->{name}};

				  if ($pkg) {
				      my $version_cmp = rpmtools::version_compare($p->{version}, $pkg->{version});
				      if ($p->{serial} > $pkg->{serial} || $p->{serial} == $pkg->{serial} &&
					  ($version_cmp > 0 ||
					   $version_cmp == 0 && rpmtools::version_compare($p->{release}, $pkg->{release}) >= 0)) {
					  if ($otherPackage && $version_cmp <= 0) {
					      $toRemove{$otherPackage} = 0;
					      $pkg->{selected} = 1;
					      $urpm->{log}(_("removing %s to upgrade ...\n to %s since it will not be updated otherwise", $otherPackage, "$pkg->{name}-$pkg->{version}-$pkg->{release}"));
					  } else {
					      $pkg->{installed} = 1;
					  }
				      } elsif ($upgradeNeedRemove{$pkg->{name}}) {
					  my $otherPackage = "$p->{name}-$p->{version}-$p->{release}";
					  $toRemove{$otherPackage} = 0;
					  $pkg->{selected} = 1;
					  $urpm->{log}(_("removing %s to upgrade ...\n to %s since it will not upgrade correctly!", $otherPackage, "$pkg->{name}-$pkg->{version}-$pkg->{release}"));
				      }
				  } else {
				      if (! exists $obsoletedPackages{$p->{name}}) {
					  @installedFilesForUpgrade{grep { ($_ !~ m|^/etc/rc.d/| && $_ !~ m|\.la$| &&
									    ! -d "$prefix/$_" && ! -l "$prefix/$_") }
								      @{$p->{files}}} = ();
				      }
				  }
			      });

	#- find new packages to upgrade.
	foreach my $pkg (values %{$urpm->{params}{info}}) {
	    my $skipThis = 0;
	    my $count = rpmtools::db_traverse_tag($db, "name", [ $pkg->{name} ], [ 'name' ], sub {
						      $skipThis ||= $pkg->{installed};
						  });

	    #- skip if not installed (package not found in current install).
	    $skipThis ||= ($count == 0);

	    #- select the package if it is already installed with a lower version or simply not installed.
	    unless ($skipThis) {
		my $cumulSize;

		$pkg->{selected} = 1;

		#- keep in mind installed files which are not being updated. doing this costs in
		#- execution time but use less memory, else hash all installed files and unhash
		#- all file for package marked for upgrade.
		rpmtools::db_traverse_tag($db, "name", [ $pkg->{name} ], [ qw(name files) ], sub {
					      my ($p) = @_;
					      @installedFilesForUpgrade{grep { ($_ !~ m|^/etc/rc.d/| && $_ !~ m|\.la$| &&
										! -d "$prefix/$_" && ! -l "$prefix/$_") }
									  @{$p->{files}}} = ();
					  });

		$ask_child->($pkg->{name}, "files", sub {
				 delete $installedFilesForUpgrade{$_[0]};
			     });
	    }
	}

	#- unmark all files for all packages marked for upgrade. it may not have been done above
	#- since some packages may have been selected by depsList.
	foreach my $pkg (values %{$urpm->{params}{info}}) {
	    if ($pkg->{selected}) {
		$ask_child->($pkg->{name}, "files", sub {
				 delete $installedFilesForUpgrade{$_[0]};
			     });
	    }
	}

	#- select packages which contains marked files, then unmark on selection.
	#- a special case can be made here, the selection is done only for packages
	#- requiring locales if the locales are selected.
	#- another special case are for devel packages where fixes over the time has
	#- made some files moving between the normal package and its devel couterpart.
	#- if only one file is affected, no devel package is selected.
	foreach my $pkg (values %{$urpm->{params}{info}}) {
	    unless ($pkg->{selected}) {
		my $toSelect = 0;
		$ask_child->($pkg->{name}, "files", sub {
				 if ($_[0] !~  m|^/etc/rc.d/| &&  $_ !~ m|\.la$| && exists $installedFilesForUpgrade{$_[0]}) {
				     ++$toSelect if ! -d "$prefix/$_[0]" && ! -l "$prefix/$_[0]";
				 }
				 delete $installedFilesForUpgrade{$_[0]};
			     });
		if ($toSelect) {
		    if ($toSelect <= 1 && $pkg->{name} =~ /-devel/) {
			$urpm->{log}(_("avoid selecting %s as not enough files will be updated", "$pkg->{name}-$pkg->{version}-$pkg->{release}"));
		    } else {
			#- default case is assumed to allow upgrade.
			my @deps = map { /\|/ and next; #- do not inspect choice
					 my $p = $urpm->{params}{depslist}[$_];
					 $p && $p->{name} =~ /locales-/ ? ($p) : () } split ' ', $pkg->{deps};
			if (@deps == 0 || @deps > 0 && (grep { !$_->{selected} && !$_->{installed} } @deps) == 0) {
			    $urpm->{log}(_("selecting %s by selection on files", $pkg->{name}));
			    $pkg->{selected} = 1;
			} else {
			    $urpm->{log}(_("avoid selecting %s as its locales language is not already selected",
					   "$pkg->{name}-$pkg->{version}-$pkg->{release}"));
			}
		    }
		}
	    }
	}

	#- clean memory...
	%installedFilesForUpgrade = ();

	#- no need to still use the child as this point, we can let him to terminate.
	close OUTPUT;
	close INPUT;
	waitpid $pid, 0;
    } else {
	close INPUT;
	close OUTPUT;
	open STDIN, "<&INPUT_CHILD";
	open STDOUT, ">&OUTPUT_CHILD";
	exec "parsehdlist", "--interactive", map { "$urpm->{statedir}/$_->{hdlist}" } grep { ! $_->{ignore} } @{$urpm->{media}}
	  or rpmtools::_exit(1);
    }

    #- let the caller known about what we found here!
    foreach my $pkg (values %{$urpm->{params}{info}}) {
	$packages->{$pkg->{id}} = 0 if $pkg->{selected};
    }

    #- clean false value on toRemove.
    delete $toRemove{''};

    #- get filenames that should be saved for packages to remove.
    #- typically config files, but it may broke for packages that
    #- are very old when compabilty has been broken.
    #- but new version may saved to .rpmnew so it not so hard !
    if ($keep_files && keys %toRemove) {
	rpmtools::db_traverse($db, [ qw(name version release conffiles) ], sub {
				  my ($p) = @_;
				  my $otherPackage = "$p->{name}-$p->{version}-$p->{release}";
				  if (exists $toRemove{$otherPackage}) {
				      @{$keep_files}{@{$p->{conffiles} || []}} = ();
				  }
			      });
    }

    #- close db, job finished !
    rpmtools::db_close($db);
}

1;
