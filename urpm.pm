package urpm;

use strict;
use vars qw($VERSION @ISA);

$VERSION = '1.40';

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

#- create a new urpm object.
sub new {
    my ($class) = @_;
    bless {
	   config     => "/etc/urpmi/urpmi.cfg",
	   depslist   => "/var/lib/urpmi/depslist.ordered",
	   provides   => "/var/lib/urpmi/provides",
	   compss     => "/var/lib/urpmi/compss",
	   statedir   => "/var/lib/urpmi",
	   cachedir   => "/var/cache/urpmi",
	   media      => undef,
	   params     => new rpmtools,

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
    my ($urpm) = @_;

    #- keep in mind if it has been called before.
    $urpm->{media} ||= [];

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
		/^ignore\s*$/ and $medium->{ignore} = 1, next;
		/^modified\s*$/ and $medium->{modified} = 1, next;
		$_ eq '}' and last;
		$_ and $urpm->{error}("syntax error at line $. in $urpm->{config}");
	    }
	    $urpm->probe_medium($medium) and push @{$urpm->{media}}, $medium;
	    next; };
	/^(.*?[^\\])\s+(.*?[^\\])\s+with\s+(.*)$/ and do { #- urpmi.cfg old format for ftp
	    my $medium = { name => unquotespace($1), clear_url => unquotespace($2), with_hdlist => unquotespace($3) };
	    $urpm->probe_medium($medium) and push @{$urpm->{media}}, $medium;
	    next; };
	/^(.*?[^\\])\s+(?:(.*?[^\\])\s*)?$/ and do { #- urpmi.cfg old format (assume hdlist.<name>.cz2?)
	    my $medium = { name => unquotespace($1), clear_url => unquotespace($2) };
	    $urpm->probe_medium($medium) and push @{$urpm->{media}}, $medium;
	    next; };
	$_ and $urpm->{error}("syntax error at line $. in [$urpm->{config}]");
    }
    close F;

    #- keep in mind when an hdlist/list file is used, really usefull for
    #- the next probe.
    my (%hdlists, %lists);
    foreach (@{$urpm->{media}}) {
	exists $hdlists{$_->{hdlist}} and
	  $_->{ignore} = 1, $urpm->{error}("medium \"$_->{name}\" try to use an already used hdlist, medium ignored");
	$hdlists{$_->{hdlist}} = undef;
	exists $lists{$_->{list}} and
	  $_->{ignore} = 1, $urpm->{error}("medium \"$_->{name}\" try to use an already used list, medium ignored");
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
		    $urpm->{error}("unable to take medium \"$2\" into account as list file is already used by another medium");
		} else {
		    my $medium;
		    foreach (@{$urpm->{media}}) {
			$_->{name} eq $2 and $medium = $_, last;
		    }
		    $medium and $urpm->{error}("unable to use name \"$2\" for unamed medium because it is already used"), next;

		    $medium = { name => $2, hdlist => "hdlist.$1", list => "list.$2" };
		    $urpm->probe_medium($medium) and push @{$urpm->{media}}, $medium;
		}
	    } else {
		$urpm->{error}("unable to take medium \"$2\" into account as no list file [$urpm->{statedir}/list.$2] exists");
	    }
	} else {
	    $urpm->{error}("unable to determine medium of this hdlist file [$_]");
	}
    }

    #- check the presence of hdlist file and list file if necessary.
    #- TODO?: degraded mode is possible with a list file but no hdlist, the medium
    #- is no longer updatable nor removable TODO
    foreach (@{$urpm->{media}}) {
	$_->{ignore} and next;
	-r "$urpm->{statedir}/$_->{hdlist}" or
	  $_->{ignore} = 1, $urpm->{error}("unable to access hdlist file of \"$_->{name}\", medium ignored");
	$_->{list} && -r "$urpm->{statedir}/$_->{list}" or
	  $_->{ignore} = 1, $urpm->{error}("unable to access list file of \"$_->{name}\", medium ignored");
    }
}

#- probe medium to be used, take old medium into account too.
sub probe_medium {
    my ($urpm, $medium) = @_;
    local $_;

    my $existing_medium;
    foreach (@{$urpm->{media}}) {
	$_->{name} eq $medium->{name} and $existing_medium = $_, last;
    }
    $existing_medium and $urpm->{error}("trying to bypass existing medium \"$medium->{name}\", avoiding"), return;
    
    unless ($medium->{ignore} || $medium->{hdlist}) {
	$medium->{hdlist} = "hdlist.$medium->{name}.cz";
	-e "$urpm->{statedir}/$medium->{hdlist}" or $medium->{hdlist} = "hdlist.$medium->{name}.cz2";
	-e "$urpm->{statedir}/$medium->{hdlist}" or
	  $medium->{ignore} = 1, $urpm->{error}("unable to find hdlist file for \"$medium->{name}\", medium ignored");
    }
    unless ($medium->{ignore} || $medium->{list}) {
	$medium->{list} = "list.$1";
	-e "$urpm->{statedir}/$medium->{list}" or
	  $medium->{ignore} = 1, $urpm->{error}("unable to find list file for \"$medium->{name}\", medium ignored");
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
		  $medium->{ignore} || $urpm->{error}("incoherent list file for \"$medium->{name}\", medium ignored"),
		    $medium->{ignore} = 1, last;
	    } else {
		$medium->{url} = $_;
	    }
	}
	$medium->{url} or
	  $medium->{ignore} || $urpm->{error}("unable to inspect list file for \"$medium->{name}\", medium ignored"),
	    $medium->{ignore} = 1; #, last; keeping it cause perl to exit caller loop ...
    }
    $medium->{url} ||= $medium->{clear_url};
    $medium;
}

#- write back urpmi.cfg code to allow modification of medium listed.
sub write_config {
    my ($urpm) = @_;

    #- avoid trashing exiting configuration in this case.
    $urpm->{media} or return;

    local *F;
    open F, ">$urpm->{config}" or $urpm->{error}("unable to write config file [$urpm->{config}]");
    foreach my $medium (@{$urpm->{media}}) {
	printf F "%s %s {\n", quotespace($medium->{name}), quotespace($medium->{clear_url});
	foreach (qw(hdlist with_hdlist list removable)) {
	    $medium->{$_} and printf F "  %s: %s\n", $_, $medium->{$_};
	}
	foreach (qw(ignore modified)) {
	    $medium->{$_} and printf F "  %s\n", $_;
	}
	printf F "}\n\n";
    }
    close F;
    $urpm->{log}("write config file [$urpm->{config}]");
}

#- add a new medium, sync the config file accordingly.
sub add_medium {
    my ($urpm, $name, $url, $with_hdlist) = @_;

    #- make sure configuration has been read.
    $urpm->{media} or $urpm->read_config();

    #- if a medium with that name has already been found
    #- we have to exit now
    my ($medium);
    foreach (@{$urpm->{media}}) {
	$_->{name} eq $2 and $medium = $_;
    }
    $medium and $urpm->{error}("medium \"$medium\" already exists"), return;

    #- creating the medium info.
    $medium = { name     => $name,
		url      => $url,
		hdlist   => "hdlist.$name.cz",
		list     => "list.$name",
		modified => 1,
	      };

    #- check to see if the medium is using file protocol or removable medium.
    if (my ($prefix, $dir) = $url =~ /^(removable_.*?|file):\/(.*)/) {
	#- the directory given does not exist or may be accessible
	#- by mounting some other. try to figure out these directory and
	#- mount everything necessary.
	$urpm->try_mounting($dir, 'mount') or $urpm->{log}("unable to access medium \"$name\""), return;

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
    $urpm->{modified} = 1;
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
	    $urpm->{error}("trying to remove inexistant medium \"$_\"");
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
	    $urpm->{error}("trying to select inexistant medium \"$_\"");
	}
    }
}

#- update urpmi database regarding the current configuration.
#- take care of modification and try some trick to bypass
#- computational of base files.
#- allow options :
#-   all     -> all medium are rebuilded
#-   force   -> try to force rebuilding from rpms files.
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
	$medium->{ignore} and next;
	$medium->{modified} ||= $options{all} or next;

	#- list of rpm files for this medium, only available for local medium where
	#- the source hdlist is not used (use force).
	my ($prefix, $dir, $error, @files);

	#- check to see if the medium is using file protocol or removable medium.
	if (($prefix, $dir) = $medium->{url} =~ /^(removable_.*?|file):\/(.*)/) {
	    #- the directory given does not exist and may be accessible
	    #- by mounting some other. try to figure out these directory and
	    #- mount everything necessary.
	    $urpm->try_mounting($dir, 'mount') or $urpm->{log}("unable to access medium \"$medium->{name}\""), next;

	    #- if the source hdlist is present and we are not forcing using rpms file
	    if (!$options{force} && $medium->{with_hdlist} && -e "$dir/$medium->{with_hdlist}") {
		unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
		system("cp", "-a", "$dir/$medium->{with_hdlist}", "$urpm->{cachedir}/partial/$medium->{hdlist}");
		
		-s "$urpm->{cachedir}/partial/$medium->{hdlist}"
		  or $error = 1, $urpm->{error}("copy of [$dir/$medium->{with_hdlist}] failed");

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
		@files = split "\n", `find '$dir/' -name "*.rpm" -print`;

		#- check files contains something good!
		if (@files > 0) {
		    #- we need to rebuild from rpm files the hdlist.
		    eval {
			$urpm->{log}("building hdlist [$urpm->{cachedir}/partial/$medium->{hdlist}]");
			$urpm->{params}->build_hdlist($options{noclean}, "$urpm->{cachedir}/headers",
						      "$urpm->{cachedir}/partial/$medium->{hdlist}", @files);
		    };
		    $@ and $error = 1, $urpm->{error}("unable to build hdlist: $@");
		} else {
		    $error = 1;
		    $urpm->{error}("no rpm files found from [$dir/]");
		}
	    }
	} else {
	    my $basename = $medium->{with_hdlist} =~ /^.*\/([^\/]*)$/ && $1;

	    #- try to sync (copy if needed) local copy after restored the previous one.
	    unlink "$urpm->{cachedir}/partial/$basename";
	    $options{force} or
	      system("cp", "-a", "$urpm->{statedir}/$medium->{hdlist}", "$urpm->{cachedir}/partial/$basename");
	    system("wget", "-NP", "$urpm->{cachedir}/partial", "$medium->{url}/$medium->{with_hdlist}");
	    $? == 0 or $error = 1, $urpm->{error}("wget of [<source_url>/$medium->{with_hdlist}] failed (maybe wget is missing?)");
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
	#- make sure group and other does not have any access to this file.
	unless ($error) {
	    local *LIST;
	    my $mask = umask 077;
	    open LIST, ">$urpm->{cachedir}/partial/$medium->{list}"
	      or $error = 1, $urpm->{error}("unable to write list file of \"$medium->{name}\"");
	    umask $mask;
	    if (@files) {
		foreach (@files) {
		    print LIST "$prefix:/$_\n";
		}
	    } else {
		local (*F, $_);
		open F, "parsehdlist '$urpm->{cachedir}/partial/$medium->{hdlist}' |";
		while (<F>) {
		    print LIST "$medium->{url}/$_";
		}
		close F;
	    }
	    close LIST;

	    #- check if at least something has been written into list file.
	    -s "$urpm->{cachedir}/partial/$medium->{list}"
	      or $error = 1, $urpm->{error}("nothing written in list file for \"$medium->{name}\"");
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

	if (!$options{force} && @{$urpm->{media}} == 1 && $urpm->{media}[0]{with_hdlist}) {
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
			$? == 0 or $urpm->{error}("unable to copy source of [$target] from [$dir/$basedir/$basename]"), last;
		    } else {
			$urpm->{error}("source of [$target] not found as [$dir/$basedir/$basename]"), last;
		    }
		} else {
		    #- we have to use wget here instead.
		    system("wget", "-O", $target, "$medium->{url}/$basedir/$basename");
		    $? == 0 or $urpm->{error}("wget of [$medium->{url}/$basedir/$basename] failed (maybe wget is missing?)"), last;
		}
	    }
	}

	if ($urpm->{modified}) {
	    #- cleaning.
	    $urpm->{params}->clean();

	    #- if a provides exists, try to use it to speed up process
	    #- but this is not mandatory here.
	    -r $urpm->{provides} and $urpm->read_provides();

	    #- compute depslist after reading each hdlist of medium
	    #- in the right order.
	    foreach my $medium (@{$urpm->{media}}) {
		$medium->{ignore} and next;
		$urpm->{params}->read_hdlists("$urpm->{statedir}/$medium->{hdlist}");
		$urpm->{params}->compute_depslist();
	    }

	    #- there has been a problem with provides not resolved on files, there
	    #- must be at least 2 linked pass on the whole process.
	    if ($urpm->{params}->get_unresolved_provides_files() > 0) {
		#- cleaning.
		$urpm->{params}->clean();

		foreach my $medium (@{$urpm->{media}}) {
		    $medium->{ignore} and next;
		    $urpm->{params}->read_hdlists("$urpm->{statedir}/$medium->{hdlist}");
		}
		$urpm->{params}->keep_only_cleaned_provides_files();
		foreach my $medium (@{$urpm->{media}}) {
		    $medium->{ignore} and next;
		    $urpm->{params}->read_hdlists("$urpm->{statedir}/$medium->{hdlist}");
		    $urpm->{params}->compute_depslist();
		}
	    }

	    #- once everything has been computed, write back the files to
	    #- sync the urpmi database.
	    $urpm->write_base_files();
	    $urpm->{modified} = 0;
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
	      $urpm->{log}("${mode}ing $_"), `$mode '$_' 2>/dev/null`;
	}
    }
    $mode eq 'mount' ? -e $dir : !-e $dir;
}

#- read depslist file using rpmtools, this file is not managed directly by urpm.
sub read_depslist {
    my ($urpm) = @_;

    local *F;
    open F, $urpm->{depslist} or $urpm->{error}("unable to read depslist file [$urpm->{depslist}]"), return;
    $urpm->{params}->read_depslist(\*F);
    close F;
    $urpm->{log}("read depslist file [$urpm->{depslist}]");
    1;
}

#- read providest file using rpmtools, this file is not managed directly by urpm.
sub read_provides {
    my ($urpm) = @_;

    local *F;
    open F, $urpm->{provides} or $urpm->{error}("unable to read provides file [$urpm->{provides}]"), return;
    $urpm->{params}->read_provides(\*F);
    close F;
    $urpm->{log}("read provides file [$urpm->{provides}]");
    1;
}

#- read providest file using rpmtools, this file is not managed directly by urpm.
sub read_compss {
    my ($urpm) = @_;

    local *F;
    open F, $urpm->{compss} or $urpm->{error}("unable to read compss file [$urpm->{compss}]"), return;
    $urpm->{params}->read_compss(\*F);
    close F;
    $urpm->{log}("read compss file [$urpm->{compss}]");
    1;
}

#- write base files using rpmtools, these files are not managed directly by urpm.
sub write_base_files {
    my ($urpm) = @_;
    local *F;

    open F, ">$urpm->{depslist}" or $urpm->{error}("unable to write depslist file [$urpm->{depslist}]");
    $urpm->{params}->write_depslist(\*F);
    close F;
    $urpm->{log}("write depslist file [$urpm->{depslist}]");

    open F, ">$urpm->{provides}" or $urpm->{error}("unable to write provides file [$urpm->{provides}]");
    $urpm->{params}->write_provides(\*F);
    close F;
    $urpm->{log}("write provides file [$urpm->{provides}]");

    open F, ">$urpm->{compss}" or $urpm->{error}("unable to write compss file [$urpm->{compss}]");
    $urpm->{params}->write_compss(\*F);
    close F;
    $urpm->{log}("write compss file [$urpm->{compss}]");
}

#- relocate depslist array to use only the most recent packages,
#- reorder info hashes too in the same manner.
sub relocate_depslist {
    my ($urpm) = @_;

    $urpm->{params}->relocate_depslist;
}

#- register local packages for being installed, keep track of source.
sub register_local_packages {
    my ($urpm, @files) = @_;
    my @names;

    #- examine each rpm and build the depslist for them using current
    #- depslist and provides environment.
    foreach (@files) {
	/(.*\/)?(.*)-([^-]*)-([^-]*)\.[^.]+\.rpm$/ or $urpm->{error}("invalid rpm file name [$_]"), next;
	$urpm->{params}->read_rpms($_);

	#- update info according to version and release, for source tracking.
	$urpm->{params}{info}{$2} or $urpm->{error}("rpm file is not accessible with rpm file [$_]"), next;
	$urpm->{params}{info}{$2}{version} eq $3 or $urpm->{error}("rpm file [$_] has not right version"), next;
	$urpm->{params}{info}{$2}{release} eq $4 or $urpm->{error}("rpm file [$_] has not right release"), next;
	$urpm->{params}{info}{$2}{source} = $1 ? $_ : "./$_";

	#- keep in mind this package has to be installed.
	push @names, "$2-$3-$4";
    }

    #- compute depslist associated.
    $urpm->{params}->compute_depslist;

    #- return package names...
    @names;
}

#- search packages registered by their name by storing their id into packages hash.
sub search_packages {
    my ($urpm, $packages, $names, %options) = @_;
    my (%exact, %found, %foundi);

    foreach my $v (@$names) {
	#- it is a way of speedup, providing the name of a package directly help
	#- to find the package.
	#- this is necessary if providing a name list of package to upgrade.
	if ($urpm->{params}{info}{$v}) {
	    $exact{$v} = $urpm->{params}{info}{$v}; next;
	}

	my $qv = quotemeta $v;
	foreach (keys %{$urpm->{params}{info}}) {
	    my $info = $urpm->{params}{info}{$_};
	    my $pack = $info->{name} .'-'. $info->{version} .'-'. $info->{release};

	    $pack =~ /^$qv-[^-]+-[^-]+$/ and $exact{$v} = $info;
	    $pack =~ /^$qv-[^-]+$/ and $exact{$v} = $info;
	    $pack =~ /$qv/ and push @{$found{$v}}, $info;
	    $pack =~ /$qv/i and push @{$foundi{$v}}, $info; 
	}
    }

    my $result = 1;
    foreach (@$names) {
	my $info = $exact{$_};
	if ($info) {
	    $packages->{$info->{id}} = undef;
	} else {
	    my $l = $found{$_} || $foundi{$_};
	    if (@{$l || []} == 0) {
		$urpm->{error}(sprintf("no package named %s\n", $_)); $result = 0;
	    } elsif (@$l > 1 && !$options{all}) {
		$urpm->{error}(sprintf("The following packages contain %s: %s\n", $_, join(' ', map { $_->{name} } @$l))); $result = 0; 
	    } else {
		foreach (@$l) {
		    $packages->{$_->{id}} = undef;
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

    #- select first level of packages, as in packages list will only be
    #- examined deps of each.
    @{$packages}{@packages} = ();

    #- at this level, compute global closure of what is requested, regardless of
    #- choices for which all package in the choices are taken and their dependancies.
    #- allow iteration over a modifying list.
    while (defined($id = shift @packages)) {
	#- get a relocated id if possible, by this way.
	$id = $urpm->{params}{depslist}[$id]{id};

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
		    $packages->{$_} = $installed && ! exists $installed->{$_};
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

    #- request the primary list to rpmlib if complete mode is not activated.
    if (!$options{complete} &&
	rpmtools::get_packages_installed('', \@packages_installed,
					 [ map { $urpm->{params}{depslist}[$_]{name} } keys %$packages ])) {
	#- there are not too many packages selected here to allow
	#- take care of package up-to-date at this point,
	#- so check version and if the package does not need to
	#- updated, ignore it and his dependancies.
	foreach (@packages_installed) {
	    my $pkg = $urpm->{params}{info}{$_->{name}}; $pkg or next; #- TODO error
	    my $cmp = rpmtools::version_compare($pkg->{version}, $_->{version});
	    $installed{$pkg->{id}} = !($cmp > 0 || $cmp == 0 && rpmtools::version_compare($pkg->{release}, $_->{release}) > 0)
	      and delete $packages->{$pkg->{id}};
	}
    }

    #- select first level of packages, as in packages list will only be
    #- examined deps of each.
    #- at this level, compute global closure of what is requested, regardless of
    #- choices for which all package in the choices are taken and their dependancies.
    #- allow iteration over a modifying list.
    @closures{keys %$packages} = ();
    $urpm->compute_closure(\%closures, undef, sub { my ($urpm, @l) = @_; @l });

    #- closures has been done so that its keys are the package that may be examined.
    #- according to number of keys, get all package installed or only the necessary
    #- packages.
    #- do not take care of already examined packages.
    delete @closures{keys %installed};
    if (scalar(keys %closures) < 100) {
	rpmtools::get_packages_installed('', \@packages_installed,
					 [ map { $urpm->{params}{depslist}[$_]{name} } keys %closures ]);
    } else {
	rpmtools::get_all_packages_installed('', \@packages_installed);
    }

    #- packages installed that may be upgraded have to be examined now.
    foreach (@packages_installed) {
	my $pkg = $urpm->{params}{info}{$_->{name}}; $pkg or next; #- TODO error
	exists $closures{$pkg->{id}} or next;
	my $cmp = rpmtools::version_compare($pkg->{version}, $_->{version});
	$installed{$pkg->{id}} = !($cmp > 0 || $cmp == 0 && rpmtools::version_compare($pkg->{release}, $_->{release}) > 0)
	  and delete $packages->{$pkg->{id}};
    }

    #- recompute closure but ask for which package to select on a choices.
    #- this is necessary to have the result before the end else some dependancy may
    #- be losed or added.
    #- accept no choice allow to browse list, and to compute it with more iteration.
    %closures = (); @closures{keys %$packages} = ();
    $urpm->compute_closure(\%closures, \%installed, $select_choices);

    #- restore package to match selection done, update the values according to
    #- need upgrade (0), requested (undef), already installed (not present) or
    #- newly added (1).
    #- choices if not chosen are present as ref.
    my @packages = keys %$packages;
    %$packages = %closures;
    @{$packages}{@packages} = ();

    $packages;
}

#- select source for package selected.
#- according to keys given in the packages hash.
#- return a list of list containing the source description for each rpm,
#- match exactly the number of medium registered, ignored medium always
#- have a null list.
sub get_source_packages {
    my ($urpm, $packages) = @_;
    my ($error, @local_sources, @list, %select);
    local (*D, *F, $_);

    #- examine the local repository, which is trusted.
    opendir D, "$urpm->{cachedir}/rpms";
    while (defined($_ = readdir D)) {
	if (/([^\/]*)-([^-]*)-([^-]*)\.([^\.]*)\.rpm/) {
	    my $pkg = $urpm->{params}{info}{$1};

	    #- check version, release and id selected.
	    #- TODO arch is not checked at this point.
	    $pkg->{version} eq $2 && $pkg->{release} eq $3 or next;
	    exists $packages->{$pkg->{id}} or next;

	    #- make sure only the first matching is taken...
	    exists $select{$pkg->{id}} and next; $select{$pkg->{id}} = undef;

	    #- we have found one source for id.
	    push @local_sources, "$urpm->{cachedir}/rpms/$1-$2-$3.$4.rpm";
	} else {
	    -d "$urpm->{cachedir}/rpms/$_" and next;
	    $error = 1;
	    $urpm->{error}("unable to determine rpms cache directory $urpm->{cachedir}/rpms");
	}
    }
    closedir D;

    #- examine each medium to search for packages.
    foreach my $medium (@{$urpm->{media} || []}) {
	my @sources;

	if (-r "$urpm->{statedir}/$medium->{hdlist}" && -r "$urpm->{statedir}/$medium->{list}" && !$medium->{ignore}) {
	    open F, "$urpm->{statedir}/$medium->{list}";
	    while (<F>) {
		if (/(.*)\/([^\/]*)-([^-]*)-([^-]*)\.([^\.]*)\.rpm/) {
		    my $pkg = $urpm->{params}{info}{$2};

		    #- check version, release and id selected.
		    #- TODO arch is not checked at this point.
		    $pkg->{version} eq $3 && $pkg->{release} eq $4 or next;
		    exists $packages->{$pkg->{id}} or next;

		    #- make sure only the first matching is taken...
		    exists $select{$pkg->{id}} and next; $select{$pkg->{id}} = undef;

		    #- we have found one source for id.
		    push @sources, "$1/$2-$3-$4.$5.rpm";
		} else {
		    $error = 1;
		    $urpm->{error}("unable to parse correctly $urpm->{statedir}/$medium->{list}");
		    last;
		}
	    }
	    close F;
	}
	push @list, \@sources;
    }

    #- examine package list to see if a package has not been found.
    foreach (keys %$packages) {
	exists $select{$_} and next;

	#- try to find which one.
	my $pkg = $urpm->{params}{depslist}[$_];
	if ($pkg) {
	    if ($pkg->{source}) {
		push @local_sources, $pkg->{source};
	    } else {
		$error = 1;
		$urpm->{error}("package $pkg->{name}-$pkg->{version}-$pkg->{release} is not found, ids=($_,$pkg->{id})");
	    }
	} else {
	    $error = 1;
	    $urpm->{error}("internal error for selecting unknown package for id=$_");
	}
    }

    $error ? () : ( \@local_sources, \@list );
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
		    $ask_for_medium->($medium->{name}, $medium->{removable}) or last;
		}
	    }
	    if (-e $dir) {
		my @removable_sources;
		foreach (@{$list->[$id]}) {
		    /^(removable_[^:]*|file):\/(.*\/([^\/]*))/ or next;
		    -r $2 or $urpm->{error}("unable to read rpm file [$2] from medium \"$medium->{name}\"");
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
		$urpm->{error}("medium \"$medium->{name}\" is not selected");
	    }
	} else {
	    #- we have a removable device that is not removable, well...
	    $urpm->{error}("incoherent medium \"$medium->{name}\" marked removable but not really");
	}
    };
    foreach (0..$#$list) {
	@{$list->[$_]} or next;
	my $medium = $urpm->{media}[$_];
	#- examine non removable device but that may be mounted.
	if ($medium->{removable}) {
	    push @{$removables{$medium->{removable}} ||= []}, $_;
	} elsif (my ($prefix, $dir) = $medium->{url} =~ /^(removable_[^:]*|file):\/(.*)/) {
	    -e $dir || $urpm->try_mounting($dir, 'mount') or $urpm->{error}("unable to access medium \"$medium->{name}\""), next;
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
		$urpm->{error}("malformed input: [$_]");
	    }
	}
    }
    if (@distant_sources) {
	local *F;
	open F, "| wget -NP $urpm->{cachedir}/rpms -i -";
	foreach (@distant_sources) {
	    print F "$_\n";
	}
	close F or $urpm->{error}("cannot get distant rpms files (maybe wget is missing?)");
    }

    #- return the list of rpm file that have to be installed, they are all local now.
    @$local_sources, @sources;
}


1;
