package urpm;

use strict;
use vars qw($VERSION @ISA);
use Fcntl ':flock';

$VERSION = '3.3';

=head1 NAME

urpm - Mandrake perl tools to handle urpmi database

=head1 SYNOPSYS

    require urpm;

    my $urpm = new urpm;
    $urpm->read_config();
    $urpm->add_medium('medium_ftp',
                      'ftp://ftp.mirror/pub/linux/distributions/mandrake-devel/cooker/i586/Mandrake/RPMS',
                      'synthesis.hdlist.cz',
                      update => 0);
    $urpm->add_distrib_media('stable', 'removable://mnt/cdrom',
                             update => 1);
    $urpm->select_media('contrib', 'update');
    $urpm->update_media(%options);
    $urpm->write_config();

    my $urpm = new urpm;
    $urpm->read_config(nocheck_access => $uid > 0);
    foreach (grep { !$_->{ignore} } @{$urpm->{media} || []}) {
        $urpm->parse_synthesis($_);
    }
    if (@files) {
        push @names, $urpm->register_local_packages(@files);
    }
    $urpm->relocate_depslist_provides();

    my %packages;
    @names and $urpm->search_packages(\%packages, [ @names],
                                      use_provides => 1);
    if ($auto_select) {
        my (%to_remove, %keep_files);

        $urpm->select_packages_to_upgrade('', \%packages,
                                          \%to_remove, \%keep_files,
                                          use_parsehdlist => $complete);
    }
    $urpm->filter_packages_to_upgrade(\%packages,
                                      $ask_choice);
    $urpm->deselect_unwanted_packages(\%packages);

    my ($local_sources,
        $list,
        $local_to_removes) = $urpm->get_source_packages(\%packages);
    my %sources = $urpm->download_source_packages($local_sources,
                                                  $list,
                                                  'force_local',
                                                  $ask_medium_change);
    my @rpms_install = grep { $_ !~ /\.src.\.rpm/ } values %{
                         $urpm->extract_packages_to_install(\%sources)
                       || {}};
    my @rpms_upgrade = grep { $_ !~ /\.src.\.rpm/ } values %sources;


=head1 DESCRIPTION

C<urpm> is used by urpmi executables to manipulate packages and media
on a Linux-Mandrake distribution.

=head1 SEE ALSO

rpmtools package is used to manipulate at a lower level hdlist and rpm
files.

=head1 COPYRIGHT

Copyright (C) 2000,2001,2002 MandrakeSoft <fpons@mandrakesoft.com>

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
	   instlist   => "/etc/urpmi/inst.list",
	   statedir   => "/var/lib/urpmi",
	   cachedir   => "/var/cache/urpmi",
	   media      => undef,
	   params     => new rpmtools('sense', 'conflicts', 'obsoletes'),

	   sync       => \&sync_webfetch, #- first argument is directory, others are url to fetch.

	   fatal      => sub { printf STDERR "%s\n", $_[1]; exit($_[0]) },
	   error      => sub { printf STDERR "%s\n", $_[0] },
	   log        => sub { printf STDERR "%s\n", $_[0] },
	  }, $class;
}

#- quoting/unquoting a string that may be containing space chars.
sub quotespace { local $_ = $_[0]; s/(\s)/\\$1/g; $_ }
sub unquotespace { local $_ = $_[0]; s/\\(\s)/$1/g; $_ }

#- syncing algorithms, currently is implemented wget and curl methods,
#- webfetch is trying to find the best (and one which will work :-)
sub sync_webfetch {
    -x "/usr/bin/curl" and return &sync_curl;
    -x "/usr/bin/wget" and return &sync_wget;
    die _("no webfetch (curl or wget currently) found\n");
}
sub sync_wget {
    -x "/usr/bin/wget" or die _("wget is missing\n");
    my $options = shift @_;
    system "/usr/bin/wget", (ref $options && $options->{quiet} ? ("-q") : ()), "-NP",
      (ref $options ? $options->{dir} : $options), @_;
    $? == 0 or die _("wget failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
}
sub sync_curl {
    -x "/usr/bin/curl" or die _("curl is missing\n");
    my $options = shift @_;
    chdir (ref $options ? $options->{dir} : $options);
    my (@ftp_files, @other_files);
    foreach (@_) {
	/^ftp:\/\/.*\/([^\/]*)$/ && -s $1 > 8192 and do { push @ftp_files, $_; next }; #- manage time stamp for large file only.
	push @other_files, $_;
    }
    if (@ftp_files) {
	my ($cur_ftp_file, %ftp_files_info);

	require Date::Manip;

	#- prepare to get back size and time stamp of each file.
	local *CURL;
	open CURL, "/usr/bin/curl -I " . join(" ", map { "'$_'" } @ftp_files) . " |";
	while (<CURL>) {
	    if (/Content-Length:\s*(\d+)/) {
		!$cur_ftp_file || exists $ftp_files_info{$cur_ftp_file}{size} and $cur_ftp_file = shift @ftp_files;
		$ftp_files_info{$cur_ftp_file}{size} = $1;
	    }
	    if (/Last-Modified:\s*(.*)/) {
		!$cur_ftp_file || exists $ftp_files_info{$cur_ftp_file}{time} and $cur_ftp_file = shift @ftp_files;
		$ftp_files_info{$cur_ftp_file}{time} = Date::Manip::ParseDate($1);
		$ftp_files_info{$cur_ftp_file}{time} =~ s/(\d{6}).{4}(.*)/$1$2/; #- remove day and hour.
	    }
	}
	close CURL;

	#- now analyse size and time stamp according to what already exists here.
	if (@ftp_files) {
	    #- re-insert back shifted element of ftp_files, because curl output above
	    #- have not been parsed correctly, in doubt download them all.
	    push @ftp_files, keys %ftp_files_info;
	} else {
	    #- for that, it should be clear ftp_files is empty... else a above work is
	    #- use less.
	    foreach (keys %ftp_files_info) {
		my ($lfile) = /\/([^\/]*)$/ or next; #- strange if we can't parse it correctly.
		my $ltime = Date::Manip::ParseDate(scalar gmtime((stat $1)[9]));
		$ltime =~ s/(\d{6}).{4}(.*)/$1$2/; #- remove day and hour.
		-s $lfile == $ftp_files_info{$_}{size} && $ftp_files_info{$_}{time} eq $ltime or
		  push @ftp_files, $_;
	    }
	}
    }
    #- http files (and other files) are correctly managed by curl to conditionnal download.
    #- options for ftp files, -R (-O <file>)*
    #- options for http files, -R (-z file -O <file>)*
    if (my @all_files = ((map { ("-O", $_ ) } @ftp_files), (map { /\/([^\/]*)$/ ? ("-z", $1, "-O", $_) : () } @other_files))) {
	system "/usr/bin/curl", (ref $options && $options->{quiet} ? ("-s") : ()), "-R", "-f", @all_files;
	$? == 0 or die _("curl failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
    }
}

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
		/^synthesis\s*$/ and $medium->{synthesis} = 1, next;
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
	  $_->{ignore} = 1, $urpm->{error}(_("medium \"%s\" tries to use an already used hdlist, medium ignored", $_->{name}));
	$hdlists{$_->{hdlist}} = undef;
	exists $lists{$_->{list}} and
	  $_->{ignore} = 1, $urpm->{error}(_("medium \"%s\" tries to use an already used list, medium ignored", $_->{name}));
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
		    $medium and $urpm->{error}(_("unable to use name \"%s\" for unnamed medium because it is already used",
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
    unless ($options{nocheck_access}) {
	foreach (@{$urpm->{media}}) {
	    $_->{ignore} and next;
	    -r "$urpm->{statedir}/$_->{hdlist}" || -r "$urpm->{statedir}/synthesis.$_->{hdlist}" && $_->{synthesis} or
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
	    #- /./ is end of url marker in list file (typically generated by a
	    #- find . -name "*.rpm" > list
	    #- for exportable list file.
	    /^(.*)\/\.\// and $probe{$1} = undef;
	    /^(.*)\/[^\/]*$/ and $probe{$1} = undef;
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

    #- probe removable device.
    $urpm->probe_removable_device($medium);

    #- clear URLs for trailing /es.
    $medium->{url} =~ s|(.*?)/*$|$1|;
    $medium->{clear_url} =~ s|(.*?)/*$|$1|;

    $medium;
}

#- probe device associated with a removable device.
sub probe_removable_device {
    my ($urpm, $medium) = @_;

    if ($medium->{url} =~ /^removable_?([^_:]*)(?:_[^:]*)?:/) {
	$medium->{removable} ||= $1 && "/dev/$1";
    } else {
	delete $medium->{removable};
    }

    #- try to find device to open/close for removable medium.
    if (exists $medium->{removable}) {
	if (my ($dir) = $medium->{url} =~ /(?:file|removable)[^:]*:\/(.*)/) {
	    my @mntpoints2devices = $urpm->find_mntpoints($dir, 'device');
	    if (@mntpoints2devices > 2) { #- return value is suitable for an hash.
		$urpm->{log}(_("too many mount points for removable medium \"%s\"", $medium->{name}));
		$urpm->{log}(_("taking removable device as \"%s\"", $mntpoints2devices[-1]));  #- take the last one.
	    }
	    if (@mntpoints2devices) {
		if ($medium->{removable} && $medium->{removable} ne $mntpoints2devices[-1]) {
		    $urpm->{log}(_("using different removable device [%s] for \"%s\"", $mntpoints2devices[-1], $medium->{name}));
		}
		$medium->{removable} = $mntpoints2devices[-1];
	    } else {
		$urpm->{error}(_("unable to retrieve pathname for removable medium \"%s\"", $medium->{name}));
	    }
	} else {
	    $urpm->{error}(_("unable to retrieve pathname for removable medium \"%s\"", $medium->{name}));
	}
    }
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
	foreach (qw(update ignore synthesis modified)) {
	    $medium->{$_} and printf F "  %s\n", $_;
	}
	printf F "}\n\n";
    }
    close F;
    $urpm->{log}(_("write config file [%s]", $urpm->{config}));

    #- everything should be synced now.
    delete $urpm->{modified};
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
	$_->{name} eq $name and $medium = $_;
    }
    $medium and $urpm->{fatal}(5, _("medium \"%s\" already exists", $medium->{name}));

    #- clear URLs for trailing /es.
    $url =~ s|(.*?)/*$|$1|;

    #- creating the medium info.
    $medium = { name     => $name,
		url      => $url,
		hdlist   => "hdlist.$name.cz",
		list     => "list.$name",
		update   => $options{update},
		modified => 1,
	      };

    #- check to see if the medium is using file protocol or removable medium.
    if (my ($prefix, $dir) = $url =~ /^(removable[^:]*|file):\/(.*)/) {
	#- add some more flags for this type of medium.
	$medium->{clear_url} = $url;

	#- try to find device associated.
	$urpm->probe_removable_device($medium);
    }

    #- all flags once everything has been computed.
    $with_hdlist and $medium->{with_hdlist} = $with_hdlist;

    #- create an entry in media list.
    push @{$urpm->{media}}, $medium;

    #- keep in mind the database has been modified and base files need to be updated.
    #- this will be done automatically by transfering modified flag from medium to global.
    $urpm->{log}(_("added medium %s", $name));
}

#- add distribution media, according to url given.
sub add_distrib_media {
    my ($urpm, $name, $url, %options) = @_;
    my ($hdlists_file);

    #- make sure configuration has been read.
    $urpm->{media} or $urpm->read_config();

    #- try to copy/retrive Mandrake/basehdlists file.
    if (my ($dir) = $url =~ /^(?:removable[^:]*|file):\/(.*)/) {
	$hdlists_file = reduce_pathname("$dir/Mandrake/base/hdlists");

	$urpm->try_mounting($hdlists_file) or $urpm->{error}(_("unable to access first installation medium")), return;

	if (-e $hdlists_file) {
	    unlink "$urpm->{cachedir}/partial/hdlists";
	    $urpm->{log}(_("copying hdlists file..."));
	    system("cp", "-a", $hdlists_file, "$urpm->{cachedir}/partial/hdlists") ?
	      $urpm->{log}(_("...copying failed")) : $urpm->{log}(_("...copying done"));
	} else {
	    $urpm->{error}(_("unable to access first installation medium (no Mandrake/base/hdlists file found)")), return;
	}
    } else {
	#- try to get the description if it has been found.
	unlink "$urpm->{cachedir}/partial/hdlists";
	eval {
	    $urpm->{log}(_("retrieving hdlists file..."));
	    $urpm->{sync}("$urpm->{cachedir}/partial", reduce_pathname("$url/Mandrake/base/hdlists"));
	    $urpm->{log}(_("...retrieving done"));
	};
	$@ and $urpm->{log}(_("...retrieving failed: %s", $@));
	if (-e "$urpm->{cachedir}/partial/hdlists") {
	    $hdlists_file = "$urpm->{cachedir}/partial/hdlists";
	} else {
	    $urpm->{error}(_("unable to access first installation medium (no Mandrake/base/hdlists file found)")), return;
	}
    }

    #- cosmetic update of name if it contains blank char.
    $name =~ /\s/ and $name .= ' ';

    #- at this point, we have found an hdlists file, so parse it
    #- and create all necessary medium according to it.
    local *HDLISTS;
    if (open HDLISTS, $hdlists_file) {
	my $medium = 1;
	foreach (<HDLISTS>) {
	    chomp;
	    s/\s*#.*$//;
	    /^\s*$/ and next;
	    m/^\s*(hdlist\S*\.cz2?)\s+(\S+)\s*(.*)$/ or $urpm->{error}(_("invalid hdlist description \"%s\" in hdlists file"), $_);
	    my ($hdlist, $rpmsdir, $descr) = ($1, $2, $3);

	    $urpm->add_medium($name ? "$descr ($name$medium)" : $descr, "$url/$rpmsdir", "../base/$hdlist", %options);

	    ++$medium;
	}
	close HDLISTS;
    } else {
	$urpm->{error}(_("unable to access first installation medium (no Mandrake/base/hdlists file found)")), return;
    }
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
    #- in such case, try to find the unique medium (or list candidate
    #- media found).
    foreach (keys %media) {
	unless ($media{$_}) {
	    my $q = quotemeta;
	    my (@found, @foundi);
	    foreach my $medium (@{$urpm->{media}}) {
		$medium->{name} =~ /$q/ and push @found, $medium;
		$medium->{name} =~ /$q/i and push @foundi, $medium;
	    }
	    if (@found == 1) {
		$found[0]{modified} = 1;
	    } elsif (@foundi == 1) {
		$foundi[0]{modified} = 1;
	    } elsif (@found == 0 && @foundi == 0) {
		$urpm->{error}(_("trying to select inexistent medium \"%s\"", $_));
	    } else { #- multiple element in found or foundi list.
		$urpm->{error}(_("trying to select multiple medium: %s", join(", ", map { _("\"%s\"", $_->{name}) }
									      (@found ? @found : @foundi))));
	    }
	}
    }
}

sub remove_selected_media {
    my ($urpm) = @_;
    my @result;
    
    foreach (@{$urpm->{media}}) {
	if ($_->{modified}) {
	    $urpm->{log}(_("removing medium \"%s\"", $_->{name}));

	    #- mark to re-write configuration.
	    $urpm->{modified} = 1;

	    #- remove file associated with this medium.
	    foreach ($_->{hdlist}, $_->{list}, "synthesis.$_->{hdlist}", "descriptions.$_->{name}", "$_->{name}.cache") {
		unlink "$urpm->{statedir}/$_";
	    }
	} else {
	    push @result, $_; #- not removed so keep it
	}
    }

    #- restore newer media list.
    $urpm->{media} = \@result;
}

sub build_synthesis_hdlist {
    my ($urpm, $medium, $use_parsehdlist) = @_;

    unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
    unless ($use_parsehdlist) {
	#- building synthesis file using internal params.
	local *F;
	open F, "| gzip >'$urpm->{statedir}/synthesis.$medium->{hdlist}'";
	foreach my $p (@{$medium->{depslist}}) {
	    foreach (qw(provides requires conflicts obsoletes)) {
		@{$p->{$_} || []} and print F join('@', $p->{name}, $_, @{$p->{$_} || []}) . "\n";
	    }
	    print F join('@',
			 $p->{name}, 'info', "$p->{name}-$p->{version}-$p->{release}.$p->{arch}",
			 $p->{serial} || 0, $p->{size} || 0, $p->{group}, $p->{file} ? ($p->{file}) : ()). "\n";
	}
	close F or unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
    }
    if (-s "$urpm->{statedir}/synthesis.$medium->{hdlist}" <= 32) {
	#- building synthesis file using parsehdlist output, need 4.0-1mdk or above.
	$use_parsehdlist or $urpm->{error}(_("unable to build hdlist synthesis, using parsehdlist method"));
	if (system "parsehdlist --synthesis '$urpm->{statedir}/$medium->{hdlist}' | gzip >'$urpm->{statedir}/synthesis.$medium->{hdlist}'") {
	    unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
	    $urpm->{error}(_("unable to build synthesis file for medium \"%s\"", $medium->{name}));
	    return;
	}
    }
    $urpm->{log}(_("built hdlist synthesis file for medium \"%s\"", $medium->{name}));
    delete $medium->{modified_synthesis};
    1;
}

#- update urpmi database regarding the current configuration.
#- take care of modification and try some trick to bypass
#- computational of base files.
#- allow options :
#-   all               -> all medium are rebuilded.
#-   force             -> try to force rebuilding base files (1) or hdlist from rpms files (2).
#-   probe_with_hdlist -> probe synthesis or hdlist.
#-   ratio             -> use compression ratio (with gzip, default is 4)
#-   noclean           -> keep header directory cleaned.
sub update_media {
    my ($urpm, %options) = @_; #- do not trust existing hdlist and try to recompute them.

    #- avoid trashing existing configuration in this case.
    $urpm->{media} or return;

    #- lock urpmi database.
    local (*LOCK_FILE);
    open LOCK_FILE, $urpm->{statedir};
    flock LOCK_FILE, LOCK_EX|LOCK_NB or $urpm->{fatal}(7, _("urpmi database locked"));

    #- examine each medium to see if one of them need to be updated.
    #- if this is the case and if not forced, try to use a pre-calculated
    #- hdlist file else build it from rpms files.
    foreach my $medium (@{$urpm->{media}}) {
	#- take care of modified medium only or all if all have to be recomputed.
	$medium->{ignore} and next;

	#- and create synthesis file associated if it does not already exists...
	-s "$urpm->{statedir}/synthesis.$medium->{hdlist}" > 32 or $medium->{modified_synthesis} = 1;

	#- but do not take care of removable media for all.
	$medium->{modified} ||= $options{all} && $medium->{url} !~ /removable/ or next;

	#- list of rpm files for this medium, only available for local medium where
	#- the source hdlist is not used (use force).
	my ($prefix, $dir, $error, @files);

	#- check to see if the medium is using file protocol or removable medium.
	if (($prefix, $dir) = $medium->{url} =~ /^(removable[^:]*|file):\/(.*)/) {
	    #- try to figure a possible hdlist_path (or parent directory of searched directory.
	    #- this is used to probe possible hdlist file.
	    my $with_hdlist_dir = reduce_pathname($dir . ($medium->{with_hdlist} ? "/$medium->{with_hdlist}" : "/.."));
	    
	    #- the directory given does not exist and may be accessible
	    #- by mounting some other. try to figure out these directory and
	    #- mount everything necessary.
	    if ($options{force} < 2 && ($options{probe_with_hdlist} || $medium->{with_hdlist})) {
		$urpm->try_mounting($with_hdlist_dir) or $urpm->{log}(_("unable to access medium \"%s\"", $medium->{name})), next;
	    } else {
		$urpm->try_mounting($dir) or $urpm->{log}(_("unable to access medium \"%s\"", $medium->{name})), next;
	    }

	    #- try to probe for possible with_hdlist parameter, unless
	    #- it is already defined (and valid).
	    if ($options{probe_with_hdlist} && (!$medium->{with_hdlist} || ! -e "$dir/$medium->{with_hdlist}")) {
		my ($suffix) = $dir =~ /RPMS([^\/]*)\/*$/;
		if (-s "$dir/synthesis.hdlist.cz" > 32) {
		    $medium->{with_hdlist} = "./synthesis.hdlist.cz";
		} elsif (-s "$dir/synthesis.hdlist$suffix.cz" > 32) {
		    $medium->{with_hdlist} = "./synthesis.hdlist$suffix.cz";
		} elsif (defined $suffix && !$suffix && -s "$dir/synthesis.hdlist1.cz" > 32) {
		    $medium->{with_hdlist} = "./synthesis.hdlist1.cz";
		} elsif (defined $suffix && !$suffix && -s "$dir/synthesis.hdlist2.cz" > 32) {
		    $medium->{with_hdlist} = "./synthesis.hdlist2.cz";
		} elsif (-s "$dir/../synthesis.hdlist$suffix.cz" > 32) {
		    $medium->{with_hdlist} = "../synthesis.hdlist$suffix.cz";
		} elsif (defined $suffix && !$suffix && -s "$dir/../synthesis.hdlist1.cz" > 32) {
		    $medium->{with_hdlist} = "../synthesis.hdlist1.cz";
		} elsif (-s "$dir/../base/hdlist$suffix.cz" > 32) {
		    $medium->{with_hdlist} = "../base/hdlist$suffix.cz";
		} elsif (defined $suffix && !$suffix && -s "$dir/../base/hdlist1.cz" > 32) {
		    $medium->{with_hdlist} = "../base/hdlist1.cz";
		}
		#- redo...
		$with_hdlist_dir = reduce_pathname($dir . ($medium->{with_hdlist} ? "/$medium->{with_hdlist}" : "/.."));
	    }

	    #- try to get the description if it has been found.
	    unlink "$urpm->{statedir}/descriptions.$medium->{name}";
	    if (-e "$dir/../descriptions") {
		$urpm->{log}(_("copying description file of \"%s\"...", $medium->{name}));
		system("cp", "-a", "$dir/../descriptions", "$urpm->{statedir}/descriptions.$medium->{name}") ?
		  $urpm->{log}(_("...copying failed")) : $urpm->{log}(_("...copying done"));
	    }

	    #- if the source hdlist is present and we are not forcing using rpms file
	    if ($options{force} < 2 && $medium->{with_hdlist} && -e $with_hdlist_dir) {
		unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
		$urpm->{log}(_("copying source hdlist (or synthesis) of \"%s\"...", $medium->{name}));
		system("cp", "-a", "$with_hdlist_dir", "$urpm->{cachedir}/partial/$medium->{hdlist}") ?
		  $urpm->{log}(_("...copying failed")) : $urpm->{log}(_("...copying done"));

		-s "$urpm->{cachedir}/partial/$medium->{hdlist}" > 32 or
		  $error = 1, $urpm->{error}(_("copy of [%s] failed", "$with_hdlist_dir"));

		#- check if the file are equals... and no force copy...
		unless ($error || $options{force}) {
		    my @sstat = stat "$urpm->{cachedir}/partial/$medium->{hdlist}";
		    my @lstat = stat "$urpm->{statedir}/$medium->{hdlist}";
		    if ($sstat[7] == $lstat[7] && $sstat[9] == $lstat[9]) {
			#- the two files are considered equal here, the medium is so not modified.
			$medium->{modified} = 0;
			unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
			next;
		    }
		}

		#- examine if a local list file is available (always probed according to with_hdlist
		#- and check hdlist has not be named very strangely...
		if ($medium->{hdlist} ne 'list') {
		    unlink "$urpm->{cachedir}/partial/list";
		    my $local_list = $medium->{with_hdlist} =~ /hd(list.*)\.cz$/ ? $1 : 'list';
		    if (-s "$dir/$local_list") {
			$urpm->{log}(_("copying source list of \"%s\"...", $medium->{name}));
			system("cp", "-a", "$dir/$local_list", "$urpm->{cachedir}/partial/list") ?
			  $urpm->{log}(_("...copying failed")) : $urpm->{log}(_("...copying done"));
		    }
		}
	    } else {
		#- try to find rpm files, use recursive method, added additional
		#- / after dir to make sure it will be taken into account if this
		#- is a symlink to a directory.
		#- make sure rpm filename format is correct and is not a source rpm
		#- which are not well managed by urpmi.
		@files = split "\n", `find '$dir/' -name "*.rpm" -print`;

		#- check files contains something good!
		if (@files > 0) {
		    #- we need to rebuild from rpm files the hdlist.
		    eval {
			$urpm->{log}(_("building hdlist [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
			$urpm->{params}->build_hdlist($options{noclean}, $options{ratio} || 4, "$urpm->{cachedir}/headers",
						      "$urpm->{cachedir}/partial/$medium->{hdlist}", @files);
		    };
		    $@ and $error = 1, $urpm->{error}(_("unable to build hdlist: %s", $@));
		    $error or delete $medium->{synthesis}; #- when building hdlist by ourself, drop synthesis property.
		} else {
		    $error = 1;
		    $urpm->{error}(_("no rpm files found from [%s]", $dir));
		}
	    }
	} else {
	    my $basename;

	    #- try to get the description if it has been found.
	    unlink "$urpm->{cachedir}/partial/descriptions";
	    if (-e "$urpm->{statedir}/descriptions.$medium->{name}") {
		rename("$urpm->{statedir}/descriptions.$medium->{name}", "$urpm->{cachedir}/partial/descriptions") or 
		  system("mv", "$urpm->{statedir}/descriptions.$medium->{name}", "$urpm->{cachedir}/partial/descriptions");
	    }
	    eval {
		$urpm->{log}(_("retrieving description file of \"%s\"...", $medium->{name}));
		$urpm->{sync}({ dir => "$urpm->{cachedir}/partial", quiet => 1 },
			      reduce_pathname("$medium->{url}/../descriptions"));
		$urpm->{log}(_("...retrieving done"));
	    };
	    if (-e "$urpm->{cachedir}/partial/descriptions") {
		rename("$urpm->{cachedir}/partial/descriptions", "$urpm->{statedir}/descriptions.$medium->{name}") or
		  system("mv", "$urpm->{cachedir}/partial/descriptions", "$urpm->{statedir}/descriptions.$medium->{name}");
	    }

	    #- try to probe for possible with_hdlist parameter, unless
	    #- it is already defined (and valid).
	    $urpm->{log}(_("retrieving source hdlist (or synthesis) of \"%s\"...", $medium->{name}));
	    if ($options{probe_with_hdlist}) {
		my ($suffix) = $dir =~ /RPMS([^\/]*)\/*$/;

		foreach ($medium->{with_hdlist} ? ($medium->{with_hdlist}) : (),
			 "synthesis.hdlist.cz", "synthesis.hdlist$suffix.cz",
			 !$suffix ? ("synthesis.hdlist1.cz", "synthesis.hdlist2.cz") : (),
			 "../synthesis.hdlist$suffix.cz", !$suffix ? ("../synthesis.hdlist1.cz") : (),
			 "../base/hdlist$suffix.cz", !$suffix ? ("../base/hdlist1.cz") : (),
			) {
		    $basename = (/^.*\/([^\/]*)$/ && $1) || $_;

		    unlink "$urpm->{cachedir}/partial/$basename";
		    eval {
			$urpm->{sync}({ dir => "$urpm->{cachedir}/partial", quiet => 1 }, reduce_pathname("$medium->{url}/$_"));
		    };
		    if (!$@ && -s "$urpm->{cachedir}/partial/$basename" > 32) {
			$medium->{with_hdlist} = $_;
			$urpm->{log}(_("found probed hdlist (or synthesis) as %s", $basename));
			last; #- found a suitable with_hdlist in the list above.
		    }
		}
	    } else {
		$basename = ($medium->{with_hdlist} =~ /^.*\/([^\/]*)$/ && $1) || $medium->{with_hdlist};

		#- try to sync (copy if needed) local copy after restored the previous one.
		unlink "$urpm->{cachedir}/partial/$basename";
		if ($medium->{synthesis}) {
		    $options{force} || ! -e "$urpm->{statedir}/synthesis.$medium->{hdlist}" or
		      system("cp", "-a", "$urpm->{statedir}/synthesis.$medium->{hdlist}", "$urpm->{cachedir}/partial/$basename");
		} else {
		    $options{force} || ! -e "$urpm->{statedir}/$medium->{hdlist}" or
		      system("cp", "-a", "$urpm->{statedir}/$medium->{hdlist}", "$urpm->{cachedir}/partial/$basename");
		}
		eval {
		    $urpm->{sync}("$urpm->{cachedir}/partial", reduce_pathname("$medium->{url}/$medium->{with_hdlist}"));
		};
		if ($@) {
		    $urpm->{log}(_("...retrieving failed: %s", $@));
		    unlink "$urpm->{cachedir}/partial/$basename";
		}
	    }
	    if (-s "$urpm->{cachedir}/partial/$basename" > 32) {
		$urpm->{log}(_("...retrieving done"));

		unless ($options{force}) {
		    my @sstat = stat "$urpm->{cachedir}/partial/$basename";
		    my @lstat = stat "$urpm->{statedir}/$medium->{hdlist}";
		    if ($sstat[7] == $lstat[7] && $sstat[9] == $lstat[9]) {
			#- the two files are considered equal here, the medium is so not modified.
			$medium->{modified} = 0;
			unlink "$urpm->{cachedir}/partial/$basename";
			next;
		    }
		}

		#- the file are different, update local copy.
		rename("$urpm->{cachedir}/partial/$basename", "$urpm->{cachedir}/partial/$medium->{hdlist}");

		#- retrieve of hdlist (or synthesis has been successfull, check if a list file is available.
		#- and check hdlist has not be named very strangely...
		if ($medium->{hdlist} ne 'list') {
		    unlink "$urpm->{cachedir}/partial/list";
		    my $local_list = $medium->{with_hdlist} =~ /hd(list.*)\.cz$/ ? $1 : 'list';
		    eval {
			$urpm->{sync}({ dir => "$urpm->{cachedir}/partial", quiet => 1},
				      reduce_pathname("$medium->{url}/$local_list"));
			$local_list ne 'list' and
			  rename("$urpm->{cachedir}/partial/$local_list", "$urpm->{cachedir}/partial/list");
		    };
		    $@ and unlink "$urpm->{cachedir}/partial/list";
		}
	    } else {
		$error = 1;
		$urpm->{error}(_("retrieve of source hdlist (or synthesis) failed"));
	    }
	}

	#- build list file according to hdlist used.
	unless (-s "$urpm->{cachedir}/partial/$medium->{hdlist}" > 32) {
	    $error = 1;
	    $urpm->{error}(_("no hdlist file found for medium \"%s\"", $medium->{name}));
	}

	#- make sure group and other does not have any access to this file.
	unless ($error) {
	    #- sort list file contents according to id.
	    my %list;
	    if (@files) {
		foreach (@files) {
		    /\/([^\/]*)-[^-\/]*-[^-\/]*\.[^\/]*\.rpm/;
		    $list{"$prefix:/$_\n"} = ($urpm->{params}{names}{$1} || { id => 1000000000 })->{id};
		}
	    } else {
		local (*F, $_);
		my %filename2pathname;
		if ($medium->{hdlist} ne 'list' && -s "$urpm->{cachedir}/partial/list") {
		    open F, "$urpm->{cachedir}/partial/list";
		    while (<F>) {
			/\/([^\/]*)\.rpm$/ and $filename2pathname{$1} = "$medium->{url}/$_";
		    }
		    close F;
		}
		unless ($medium->{synthesis}) {
		    open F, "parsehdlist --silent --name '$urpm->{cachedir}/partial/$medium->{hdlist}' |";
		    while (<F>) {
			/^([^\/]*):name:([^\/\s:]*)(?::(.*)\.rpm)?$/ or next;
			$list{$filename2pathname{$3 || $2} ||
			      "$medium->{url}/". ($3 || $2) .".rpm\n"} = ($urpm->{params}{names}{$1} ||
									  { id => 1000000000 })->{id};
		    }
		    close F or $medium->{synthesis} = 1; #- try hdlist as a synthesis (for probe)
		}
		if ($medium->{synthesis}) {
		    if (my @founds = $urpm->parse_synthesis($medium, filename => "$urpm->{cachedir}/partial/$medium->{hdlist}")) {
			#- it appears hdlist file is a synthesis one in fact.
			#- parse_synthesis returns all full name of package read from it.
			foreach (@founds) {
			    my $fullname = "$_->{name}-$_->{version}-$_->{release}.$_->{arch}";
			    $list{$filename2pathname{$_->{file} || $fullname} ||
				  "$medium->{url}/". ($_->{file} || $fullname) .".rpm\n"} = ($urpm->{params}{names}{$_->{name}} ||
											     { id => 1000000000 })->{id};
			}
		    } else {
			$error = 1, $urpm->{error}(_("unable to parse hdlist file of \"%s\"", $medium->{name}));
			delete $medium->{synthesis}; #- make sure synthesis property is no more set.
		    }
		}
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
	    -s "$urpm->{cachedir}/partial/$medium->{list}" > 32 or
	      $error = 1, $urpm->{error}(_("nothing written in list file for \"%s\"", $medium->{name}));
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
	    $medium->{synthesis} and unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
	    unlink "$urpm->{statedir}/$medium->{list}";
	    rename("$urpm->{cachedir}/partial/$medium->{hdlist}", $medium->{synthesis} ?
		   "$urpm->{statedir}/synthesis.$medium->{hdlist}" : "$urpm->{statedir}/$medium->{hdlist}") or
		     system("mv", "$urpm->{cachedir}/partial/$medium->{hdlist}", $medium->{synthesis} ?
			    "$urpm->{statedir}/synthesis.$medium->{hdlist}" :
			    "$urpm->{statedir}/$medium->{hdlist}");
	    rename("$urpm->{cachedir}/partial/$medium->{list}", "$urpm->{statedir}/$medium->{list}") or
	      system("mv", "$urpm->{cachedir}/partial/$medium->{list}", "$urpm->{statedir}/$medium->{list}");

	    #- and create synthesis file associated.
	    $medium->{modified_synthesis} = !$medium->{synthesis};
	    #$medium->{synthesis} or $medium->{modified_synthesis} = 1;
	}
    }

    #- build synthesis files once requires/files have been matched by rpmtools::read_hdlists.
    if (my @rebuild_synthesis = grep { $_->{modified_synthesis} && !$_->{modified} } @{$urpm->{media}}) {
	#- cleaning whole data structures (params and per media).
	$urpm->{log}(_("examining whole urpmi database"));
	$urpm->clean;

	foreach my $medium (@{$urpm->{media} || []}) {
	    $medium->{ignore} || $medium->{modified} and next;
	    if ($medium->{synthesis}) {
		#- reading the synthesis allow to propagate requires to files, so that if an hdlist can have them...
		$urpm->{log}(_("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
		$urpm->parse_synthesis($medium, examine_requires => 1);
	    } else {
		$urpm->{log}(_("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
		$urpm->{params}->read_hdlists("$urpm->{statedir}/$medium->{hdlist}");
	    }
	}

	$urpm->{log}(_("keeping only files referenced in provides"));
	$urpm->{params}->keep_only_cleaned_provides_files();
	foreach my $medium (@{$urpm->{media} || []}) {
	    $medium->{ignore} || $medium->{modified} and next;
	    unless ($medium->{synthesis}) {
		$urpm->{log}(_("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
		my @fullnames = $urpm->{params}->read_hdlists("$urpm->{statedir}/$medium->{hdlist}");
		while (!@fullnames) {
		    $urpm->{error}(_("problem reading hdlist file, trying again"));
		    @fullnames = $urpm->{params}->read_hdlists("$urpm->{statedir}/$medium->{hdlist}");
		}
		$medium->{depslist} = [];
		push @{$medium->{depslist}}, $urpm->{params}{info}{$_} foreach @fullnames;
	    }
	}

	#- restore provided file in each packages.
	#- this is the only operation not done by reading hdlist.
	foreach my $file (keys %{$urpm->{params}{provides}}) {
	    $file =~ /^\// or next;
	    foreach (keys %{$urpm->{params}{provides}{$file} || {}}) {
		eval { push @{$urpm->{params}{info}{$_}{provides}}, $file };
	    }
	}

	#- this is necessary to give id at least.
	$urpm->{params}->compute_id;

	#- rebuild all synthesis hdlist which need to be updated.
	foreach (@rebuild_synthesis) {
	    $urpm->build_synthesis_hdlist($_);
	}

	#- keep in mind we have modified database, sure at this point.
	$urpm->{modified} = 1;
    }

    #- clean headers cache directory to remove everything that is no more
    #- usefull according to depslist used.
    if ($urpm->{modified}) {
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
    }

    #- now everything is finished.
    system("sync");

    #- release lock on database.
    flock LOCK_FILE, LOCK_UN;
    close LOCK_FILE;
}

#- clean params and depslist computation zone.
sub clean {
    my ($urpm) = @_;

    $urpm->{params}->clean();
    foreach (@{$urpm->{media} || []}) {
	$_->{depslist} = [];
    }
}

#- find used mount point from a pathname, use a optional mode to allow
#- filtering according the next operation (mount or umount).
sub find_mntpoints {
    my ($urpm, $dir, $mode) = @_;

    #- fast mode to check according to next operation.
    $mode eq 'mount' && -e $dir and return;
    $mode eq 'umount' && ! -e $dir and return;

    #- really check and find mount points here.
    my ($fdir, $pdir, $v, %fstab, @mntpoints) = $dir;
    local (*F, $_);

    #- read /etc/fstab and check for existing mount point.
    open F, "/etc/fstab";
    while (<F>) {
	my ($device, $mntpoint, $fstype, $options) = /^\s*(\S+)\s+(\/\S+)\s+(\S+)\s+(\S+)/ or next;
	$mntpoint =~ s,/+,/,g; $mntpoint =~ s,/$,,;
	$fstab{$mntpoint} =  0;
	if ($mode eq 'device') {
	    if ($fstype eq 'supermount') {
		$options =~ /^(?:.*[\s,])?dev=([^\s,]+)/ and $fstab{$mntpoint} = $1;
	    } elsif ($device eq 'none') {
		next;
	    } else {
		$fstab{$mntpoint} = $device;
	    }
	}
    }
    open F, "/etc/mtab";
    while (<F>) {
	my ($device, $mntpoint, $fstype, $options) = /^\s*(\S+)\s+(\/\S+)\s+(\S+)\s+(\S+)/ or next;
	$mntpoint =~ s,/+,/,g; $mntpoint =~ s,/$,,;
	$fstab{$mntpoint} = 1;
	if ($mode eq 'device') {
	    if ($fstype eq 'supermount') {
		$options =~ /^(?:.*[\s,])?dev=([^\s,]+)/ and $fstab{$mntpoint} = $1;
	    } elsif ($device eq 'none') {
		next;
	    } else {
		$fstab{$mntpoint} = $device;
	    }
	}
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
	$pdir =~ s,/+,/,g; $pdir =~ s,/$,,;
	if (exists $fstab{$pdir}) {
	    $mode eq 'mount' && ! $fstab{$pdir} and push @mntpoints, $pdir;
	    $mode eq 'umount' && $fstab{$pdir} and unshift @mntpoints, $pdir;
	    $mode eq 'device' and push @mntpoints, $pdir, $fstab{$pdir};
	}
    }

    @mntpoints;
}

#- reduce pathname by removing <something>/.. each time it appears (or . too).
sub reduce_pathname {
    my ($url) = @_;

    #- take care if this is a true url and not a simple pathname.
    my ($host, $dir) = $url =~ /([^:\/]*:\/\/[^\/]*\/)?(.*)/;

    #- remove any multiple /s or trailing /.
    #- then split all components of pathname.
    $dir =~ s/\/+/\//g; $dir =~ s/\/$//;
    my @paths = split '/', $dir;

    #- reset $dir, recompose it, and clean trailing / added by algorithm.
    $dir = '';
    foreach (@paths) {
	if ($_ eq '..') {
	    $dir =~ s/([^\/]+)\/$// or $dir .= "../";
	} elsif ($_ ne '.') {
	    $dir .= "$_/";
	}
    }
    $dir =~ s/\/$//;

    $host . $dir;
}

#- check for necessity of mounting some directory to get access
sub try_mounting {
    my ($urpm, $dir) = @_;

    $dir = reduce_pathname($dir);
    foreach ($urpm->find_mntpoints($dir, 'mount')) {
	$urpm->{log}(_("mounting %s", $_));
	`mount '$_' 2>/dev/null`;
    }
    -e $dir;
}

sub try_umounting {
    my ($urpm, $dir) = @_;

    $dir = reduce_pathname($dir);
    foreach ($urpm->find_mntpoints($dir, 'umount')) {
	$urpm->{log}(_("unmounting %s", $_));
	`umount '$_' 2>/dev/null`;
    }
    ! -e $dir;
}

#- relocate depslist array id to use only the most recent packages,
#- reorder info hashes to give only access to best packages.
sub relocate_depslist_provides {
    my ($urpm, %options) = @_;
    my $relocated_entries = 0;

    #- reset names hash now, will be filled after.
    $urpm->{params}{names} = {};

    foreach (@{$urpm->{params}{depslist} || []}) {
	my $fullname = "$_->{name}-$_->{version}-$_->{release}.$_->{arch}";

	#- remove access to info if arch is incompatible and only
	#- take into account compatible arch to examine.
	#- set names hash by prefering first better version,
	#- then better release, then better arch.
	if (rpmtools::compat_arch($_->{arch})) {
	    my $p = $urpm->{params}{names}{$_->{name}};
	    if ($p) {
		my $cmp_version = $_->{serial} == $p->{serial} && rpmtools::version_compare($_->{version}, $p->{version});
		my $cmp_release = $cmp_version == 0 && rpmtools::version_compare($_->{release}, $p->{release});
		if ($_->{serial} > $p->{serial} || $cmp_version > 0 || $cmp_release > 0 ||
		    ($_->{serial} == $p->{serial} && $cmp_version == 0 && $cmp_release == 0 &&
		     rpmtools::better_arch($_->{arch}, $p->{arch}))) {
		    $urpm->{params}{names}{$_->{name}} = $_;
		    ++$relocated_entries;
		}
	    } else {
		$urpm->{params}{names}{$_->{name}} = $_;
	    }
	} elsif ($_->{arch} ne 'src') {
	    #- the package is removed, make it invisible (remove id).
	    delete $_->{id};

	    #- the architecture is not compatible, this means the package is dropped.
	    #- we have to remove its reference in provides.
	    foreach (@{$_->{provides} || []}) {
		delete $urpm->{provides}{$_}{$fullname};
	    }
	}
    }

    #- relocate id used in depslist array, delete id if the package
    #- should NOT be used.
    #- if no entries have been relocated, we can safely avoid this computation.
    if ($relocated_entries) {
	foreach (@{$urpm->{params}{depslist}}) {
	    unless ($_->{source}) { #- hack to avoid losing local package.
		my $p = $urpm->{params}{names}{$_->{name}} or next;
		$_->{id} = $p->{id};
	    }
	}
    }

    $urpm->{log}($relocated_entries ?
		 _("relocated %s entries in depslist", $relocated_entries) :
		 _("no entries relocated in depslist"));
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

	my ($fullname) = $urpm->{params}->read_rpms($_);
	my $pkg = $urpm->{params}{info}{$fullname};
	$pkg or $urpm->{error}(_("unable to register rpm file")), next;
	$pkg->{source} = $1 ? $_ :  "./$_";
	push @names, $fullname;
    }
    $error and $urpm->{fatal}(1, _("error registering local packages"));

    #- allocate id to each package read.
    $urpm->{params}->compute_id;

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
	unless ($options{fuzzy}) {
	    my $pkg = $urpm->{params}{names}{$v};
	    if (defined $pkg->{id} && ($options{src} ? $pkg->{arch} eq 'src' : $pkg->{arch} ne 'src')) {
		$exact{$v} = $pkg->{id};
		next;
	    }
	}

	my $qv = quotemeta $v;

	if ($options{use_provides}) {
	    unless ($options{fuzzy}) {
		#- try to search through provides.
		if (my @l = grep { defined $_ } map { $_ && ($options{src} ? $_->{arch} eq 'src' : $_->{arch} ne 'src') &&
							$_->{id} || undef } map { $urpm->{params}{info}{$_} }
		    keys %{$urpm->{params}{provides}{$v} || {}}) {
		    #- we assume that if the there is at least one package providing the resource exactly,
		    #- this should be the best ones that is described.
		    $exact{$v} = join '|',  @l;
		    next;
		}
	    }

	    foreach (keys %{$urpm->{params}{provides}}) {
		#- search through provides to find if a provide match this one.
		#- but manages choices correctly (as a provides may be virtual or
		#- multiply defined.
		/$qv/ and push @{$found{$v}}, join '|', grep { defined $_ }
		  map { my $pkg = $urpm->{params}{info}{$_};
			$pkg && ($options{src} ? $pkg->{arch} eq 'src' : $pkg->{arch} ne 'src') && $pkg->{id} || undef }
		    keys %{$urpm->{params}{provides}{$_}};
		/$qv/i and push @{$found{$v}}, join '|', grep { defined $_ }
		  map { my $pkg = $urpm->{params}{info}{$_};
			$pkg && ($options{src} ? $pkg->{arch} eq 'src' : $pkg->{arch} ne 'src') && $pkg->{id} || undef }
		    keys %{$urpm->{params}{provides}{$_}};
	    }
	}

	foreach my $id (0 .. $#{$urpm->{params}{depslist}}) {
	    my $info = $urpm->{params}{depslist}[$id];

	    ($options{src} ? $info->{arch} eq 'src' : rpmtools::compat_arch($info->{arch})) or next;

	    my $pack_ra = "$info->{name}-$info->{version}";
	    my $pack_a = "$pack_ra-$info->{release}";
	    my $pack = "$pack_a.$info->{arch}";

	    unless ($options{fuzzy}) {
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
	    }

	    $pack =~ /$qv/ and push @{$found{$v}}, $id;
	    $pack =~ /$qv/i and push @{$foundi{$v}}, $id;
	}
    }

    my $result = 1;
    foreach (@$names) {
	if (defined $exact{$_}) {
	    $packages->{$exact{$_}} = undef;
	} else {
	    #- at this level, we need to search the best package given for a given name,
	    #- always prefer already found package.
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
					       rpmtools::version_compare($_->{info}{version},
									 $best->{info}{version}));
			    my $cmp_release = ($cmp_version == 0 &&
					       rpmtools::version_compare($_->{info}{release},
									 $best->{info}{release}));
			    if ($_->{info}{serial} > $best->{info}{serial} ||
				$cmp_version > 0 || $cmp_release > 0 ||
				($_->{info}{serial} == $best->{info}{serial} &&
				 $cmp_version == 0 && $cmp_release == 0 &&
				 rpmtools::better_arch($_->{info}{arch}, $best->{info}{arch}))) {
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

#- parse synthesis file to retrieve information stored inside.
sub parse_synthesis {
    my ($urpm, $medium, %options) = @_;
    local (*F, $_);
    my ($error, $last_name, @founds, %info);

    #- check with provides that version and release are matching else ignore safely.
    #- simply ignore src rpm, which does not have any provides.
    my $update_info = sub {
	my ($found, $fullname, $serial, $size, $group, $file);

	#- search important information.
	$info{info} and ($fullname, $serial, $size, $group, $file) = @{$info{info}};
	$fullname or $info{name} and ($fullname, $file) = @{$info{name}};

	#- no fullname means no information have been found, this is really problematic here!
	$fullname or return;

	#- search an existing entry or create it.
	unless ($found = $urpm->{params}{info}{$fullname}) {
	    #- the entry does not exists *AND* should be created (in info, names and provides hashes)
	    if ($fullname =~ /^(.*?)-([^-]*)-([^-]*)\.([^\-\.]*)$/) {
		$found = $urpm->{params}{info}{$fullname} = $urpm->{params}{names}{$1} =
		  { name => $1, version => $2, release => $3, arch => $4,
		    id => scalar @{$urpm->{params}{depslist}},
		  };

		#- update global depslist, medium depslist and provides.
		push @{$urpm->{params}{depslist}}, $found;
		push @{$medium->{depslist}}, $found;

		if ($options{examine_requires}) {
		    foreach (@{$info{requires} || []}) {
			/([^\s\[]*)/ and $urpm->{params}{provides}{$1} ||= undef;  #- do not delete, but keep in mind.
		    }
		}
		$urpm->{params}{provides}{$found->{name}}{$fullname} = undef;
		foreach (@{$info{provides} || []}) {
		    defined $serial or
		      /([^\s\[]*)(?:\s+|\[)?==\s*(?:(\d+):)?[^\-]*-/ && $found->{name} eq $1 && $2 > 0 and $serial = $2;
		    /([^\s\[]*)/ and $urpm->{params}{provides}{$1}{$fullname} = undef;
		}
	    }
	}
	if ($found) {
	    #- an already existing entries has been found, so
	    #- add additional information (except name or info).
	    foreach my $tag (keys %info) {
		$tag ne 'name' && $tag ne 'info' and $found->{$tag} ||= $info{$tag};
	    }
	    $serial and $found->{serial} ||= $serial;
	    $size and $found->{size} ||= $size;
	    $group and $found->{group} ||= $group;
	    $file and $found->{file} ||= $file;

	    #- keep track of package found.
	    push @founds, $found;
	} else {
	    #- fullname is incoherent or not found (and not created).
	    $urpm->{log}(_("unknown data associated with %s", $fullname));
	}
	$found;
    };

    #- keep track of filename used for the medium.
    my $filename = $options{filename} || "$urpm->{statedir}/synthesis.$medium->{hdlist}";

    open F, "gzip -dc '$filename' |";
    while (<F>) {
	chomp;
	my ($name, $tag, @data) = split '@';
	if ($name ne $last_name) {
	    !%info || $update_info->() or
	      $urpm->{log}(_("unable to analyse synthesis data of %s",
			     $last_name =~ /^[[:print:]]*$/ ? $last_name : _("<non printable chars>")));
	    $last_name = $name;
	    %info = ();
	}
	$info{$tag} = \@data;
    }
    !%info || $update_info->() or $urpm->{log}(_("unable to analyse synthesis data of %s", $last_name));
    close F or $urpm->{error}(_("unable to parse correctly [%s]", $filename)), return;
    $urpm->{log}(_("read synthesis file [%s]", $filename));

    @founds;
}

#- filter minimal list, upgrade packages only according to rpm requires
#- satisfied, remove upgrade for package already installed or with a better
#- version, try to upgrade to minimize upgrade errors.
#- all additional package selected have a true value.
sub filter_packages_to_upgrade {
    my ($urpm, $packages, $select_choices, %options) = @_;
    my ($id, %installed, %selected, %conflicts);
    my ($db, @packages) = (rpmtools::db_open(''), keys %$packages);
    my $sig_handler = sub { rpmtools::db_close($db); exit 3 };
    local $SIG{INT} = $sig_handler;
    local $SIG{QUIT} = $sig_handler;

    #- common routines that are called at different points.
    my $check_installed = sub {
	my ($pkg) = @_;
	$pkg->{src} eq 'src' and return;
	$options{keep_alldeps} || exists $installed{$pkg->{id}} and return 0;
	rpmtools::db_traverse_tag($db, 'name', [ $pkg->{name} ],
				  [ qw(name version release serial) ], sub {
				      my ($p) = @_;
				      my $vc = rpmtools::version_compare($pkg->{version}, $p->{version});
				      $installed{$pkg->{id}} ||=
					!($pkg->{serial} > $p->{serial} || $pkg->{serial} == $p->{serial} &&
					  ($vc > 0 || $vc == 0 && rpmtools::version_compare($pkg->{release}, $p->{release}) > 0));
				  });
    };

    #- at this level, compute global closure of what is requested, regardless of
    #- choices for which all package in the choices are taken and their dependencies.
    #- allow iteration over a modifying list.
    while (defined($id = shift @packages)) {
	$id =~ /\|/ and delete $packages->{$id}, $id = [ split '\|', $id ]; #- get back choices...
	if (ref $id) {
	    my (@forced_selection, @selection);

	    #- at this point we have almost only choices to resolves.
	    #- but we have to check if one package here is already selected
	    #- previously, if this is the case, use it instead.
	    #- if a choice is proposed with package already installed (this is the case for
	    #- a provide with a lot of choices, we have to filter according to those who
	    #- are installed).
	    foreach (@$id) {
		my $pkg = $urpm->{params}{depslist}[$_];
		if (exists $packages->{$_} || $check_installed->($pkg) > 0) {
		    $installed{$pkg->{id}} or push @forced_selection, $_;
		} else {
		    push @selection, $_;
		}
	    }

	    #- propose the choice to the user now, or select the best one (as it is supposed to be).
	    @selection = @forced_selection ? @forced_selection :
	      $select_choices ? (@selection > 1 ? ($select_choices->($urpm, undef, @selection)) : ($selection[0])) :
		(join '|', @selection);
	    foreach (@selection) {
		unless (exists $packages->{$_}) {
		    /\|/ or unshift @packages, $_;
		    $packages->{$_} = 1;
		}
	    }
	    next;
	}
	my $pkg = $urpm->{params}{depslist}[$id];
	defined $pkg->{id} or next; #- id has been removed for package that only exists on some arch.

	#- search for package that will be upgraded, and check the difference
	#- of provides to see if something will be altered and need to be upgraded.
	#- this is bogus as it only take care of == operator if any.
	#- defining %provides here could slow the algorithm but it solves multi-pass
	#- where a provides is A and after A == version-release, when A is already
	#- installed.
	my (%diff_provides, %provides);

	if ($pkg->{arch} ne 'src') {
	    rpmtools::db_traverse_tag($db,
				      'name', [ $pkg->{name}, @{$pkg->{obsoletes} || []} ],
				      [ qw(name version release sense provides) ], sub {
					  my ($p) = @_;
					  foreach (@{$p->{provides}}) {
					      s/\[\*\]//;
					      s/\[([^\]]*)\]/ $1/;
					      $diff_provides{$_} = "$p->{name}-$p->{version}-$p->{release}";
					  }
				      });

	    foreach (@{$pkg->{provides} || []}) {
		s/\[\*\]//;
		s/\[([^\]]*)\]/ $1/;
		delete $diff_provides{$_};
	    }

	    foreach (keys %diff_provides) {
		#- analyse the difference in provide and select other package.
		if (my ($n, $o, $e, $v, $r) = /^(\S*)\s*(\S*)\s*(\d+:)?([^\s-]*)-?(\S*)/) {
		    my $check = sub {
			my ($p) = @_;
			my ($needed, $satisfied) = (0, 0);
			foreach (@{$p->{requires}}) {
			    if (my ($pn, $po, $pv, $pr) =
				/^([^\s\[]*)(?:\[\*\])?(?:\s+|\[)?([^\s\]]*)\s*([^\s\-\]]*)-?([^\s\]]*)/) {
				$pn eq $n && $pn eq $pkg->{name} or next;
				++$needed;
				(!$pv || eval(rpmtools::version_compare($pkg->{version}, $pv) . $po . 0)) &&
				  (!$pr || rpmtools::version_compare($pkg->{version}, $pv) != 0 ||
				   eval(rpmtools::version_compare($pkg->{release}, $pr) . $po . 0)) or next;
				#- an existing provides (propably the one examined) is satisfying the underlying.
				++$satisfied;
			    }
			}
			#- check if the package need to be updated because it
			#- losts some of its requires regarding the current diff_provides.
			$needed > $satisfied and $selected{$p->{name}} ||= undef;
		    };
		    rpmtools::db_traverse_tag($db, 'whatrequires', [ $n ], [ qw(name version release sense requires) ], $check);
		}
	    }

	    $provides{$pkg->{name}} = undef; #"$pkg->{name}-$pkg->{version}-$pkg->{release}";
	}

	#- iterate over requires of the packages, register them.
	foreach (@{$pkg->{requires} || []}) {
	    if (my ($n, $o, $v, $r) = /^([^\s\[]*)(?:\[\*\])?(?:\s+|\[)?([^\s\]]*)\s*([^\s\-\]]*)-?([^\s\]]*)/) {
		exists $provides{$_} and next;
		#- if the provides is not found, it will be resolved at next step, else
		#- it will be resolved by searching the rpm database.
		$provides{$_} ||= undef;
		unless ($options{keep_alldeps}) {
		    my $check_pkg = sub {
			$o and $n eq $_[0]{name} || return;
			(!$v || eval(rpmtools::version_compare($_[0]{version}, $v) . $o . 0)) &&
			  (!$r || rpmtools::version_compare($_[0]{version}, $v) != 0 ||
			   eval(rpmtools::version_compare($_[0]{release}, $r) . $o . 0)) or return;
			$provides{$_} = "$_[0]{name}-$_[0]{version}-$_[0]{release}";
		    };
		    rpmtools::db_traverse_tag($db, $n =~ m|^/| ? 'path' : 'whatprovides', [ $n ],
					      [ qw (name version release) ], $check_pkg);
		}
	    }
	}

	#- examine conflicts and try to resolve them.
	#- if there is a conflicts with a too old version, it need to be upgraded.
	#- if there is a provides (by using a obsoletes on it too), examine obsolete (provides) too.
	foreach (@{$pkg->{conflicts} || []}) {
	    if (my ($n, $o, $v, $r) = /^([^\s\[]*)(?:\[\*\])?(?:\s+|\[)?([^\s\]]*)\s*([^\s\-\]]*)-?([^\s\]]*)/) {
		my $check_pkg = sub {
		    my ($p) = @_;
		    $o and $n eq $p->{name} || return;
		    (!$v || eval(rpmtools::version_compare($p->{version}, $v) . $o . 0)) &&
		      (!$r || rpmtools::version_compare($p->{version}, $v) != 0 ||
		       eval(rpmtools::version_compare($p->{release}, $r) . $o . 0)) or return;
		    $conflicts{"$p->{name}-$p->{version}-$p->{release}.$p->{arch}"} = 1;
		    $selected{$_[0]{name}} ||= undef;
		};
		rpmtools::db_traverse_tag($db, $n =~ m|^/| ? 'path' : 'whatprovides', [ $n ],
					  [ qw (name version release arch) ], $check_pkg);
		foreach my $fullname (keys %{$urpm->{params}{provides}{$n} || {}}) {
		    my $p = $urpm->{params}{info}{$fullname};
		    $p->{arch} eq 'src' and next;
		    $o and $n eq $p->{name} || next;
		    (!$v || eval(rpmtools::version_compare($p->{version}, $v) . $o . 0)) &&
		      (!$r || rpmtools::version_compare($p->{version}, $v) != 0 ||
		       eval(rpmtools::version_compare($p->{release}, $r) . $o . 0)) or next;
		    $conflicts{"$p->{name}-$p->{version}-$p->{release}.$p->{arch}"} ||= 0;
		}
	    }
	}

	#- at this point, all unresolved provides (requires) should be fixed by
	#- provides files, try to minimize choice at this level.
	foreach (keys %provides, grep { !$selected{$_} } keys %selected) {
	    my (%pre_choices, @pre_choices, @choices, @upgradable_choices, %choices_id);
	    if (my ($n, $o, $v, $r) = /^([^\s\[]*)(?:\[\*\])?(?:\s+|\[)?([^\s\]]*)\s*([^\s\-\]]*)-?([^\s\]]*)/) {
		$provides{$_} and next;

		foreach my $fullname (keys %{$urpm->{params}{provides}{$n} || {}}) {
		    exists $conflicts{$fullname} and next;
		    my $pkg = $urpm->{params}{info}{$fullname};
		    $pkg->{arch} eq 'src' and next;
		    $selected{$n} || $selected{$pkg->{name}} and %pre_choices=(), last;
		    #- check if a unsatisfied selection on a package is needed,
		    #- which need a obsolete on a package with different name or
		    #- a package with the given name.
		    #- if an obsolete is given, it will be satisfied elsewhere. CHECK TODO
		    if ($n ne $pkg->{name}) {
			exists $selected{$n} and next;
			#- a virtual provides exists with a specific version and maybe release.
			#- try to resolve.
			foreach (@{$pkg->{provides}}) {
			    if (my ($pn, $po, $pv, $pr) =
				/^([^\s\[]*)(?:\[\*\])?(?:\s+|\[)?([^\s\]]*)\s*([^\s\-\]]*)-?([^\s\]]*)/) {
				$pn eq $n or next;
				my $no = $po eq '==' ? $o : $po; #- CHECK TODO ?
				(!$pv || eval(rpmtools::version_compare($pv, $v) . $no . 0)) &&
				  (!$pr || rpmtools::version_compare($pv, $v) != 0 ||
				   eval(rpmtools::version_compare($pr, $r) . $no . 0)) or next;
				push @{$pre_choices{$pkg->{name}}}, $pkg;
			    }
			}
		    } else {
			(!$v || eval(rpmtools::version_compare($pkg->{version}, $v) . $o . 0)) &&
			  (!$r || rpmtools::version_compare($pkg->{version}, $v) != 0 ||
			   eval(rpmtools::version_compare($pkg->{release}, $r) . $o . 0)) or next;
			push @{$pre_choices{$pkg->{name}}}, $pkg;
		    }
		}
	    }
	    foreach (values %pre_choices) {
		#- there is at least one element in each list of values.
		if (@$_ == 1) {
		    push @pre_choices, $_->[0];
		} else {
		    #- take the best one, according to id used.
		    my $chosen_pkg;
		    foreach my $id (%$packages) {
			my $candidate_pkg = $urpm->{params}{depslist}[$id];
			$candidate_pkg->{name} eq $pkg->{name} or next;
			foreach my $pkg (@$_) {
			    $pkg == $candidate_pkg and $chosen_pkg = $pkg, last;
			}
		    }
		    $chosen_pkg ||= $urpm->{params}{names}{$_->[0]{name}}; #- at least take the best normally used.
		    push @pre_choices, $chosen_pkg;
		}
	    }
	    foreach my $pkg (@pre_choices) {
		push @choices, $pkg;

		$check_installed->($pkg);
		$installed{$pkg->{id}} and delete $packages->{$pkg->{id}};
		exists $installed{$pkg->{id}} and push @upgradable_choices, $pkg;
	    }
	    foreach my $pkg (@pre_choices) {
		if (exists $packages->{$pkg->{id}} || $installed{$pkg->{id}}) {
		    #- the package is already selected, or installed with a better version and release.
		    @choices = @upgradable_choices = ();
		    last;
		}
	    }
	    @upgradable_choices > 0 and @choices = @upgradable_choices;
	    $choices_id{$_->{id}} = $_ foreach @choices;
	    if (keys(%choices_id) == 1) {
		my ($id) = keys(%choices_id);
		$selected{$choices_id{$id}{name}} = 1;
		exists $packages->{$id} or $packages->{$id} = 1;
		unshift @packages, $id;
	    } elsif (keys(%choices_id) > 1) {
		push @packages, [ sort { $a <=> $b } keys %choices_id ];
	    }
	}
    }

    rpmtools::db_close($db);
}

#- get out of package that should not be upgraded.
sub deselect_unwanted_packages {
    my ($urpm, $packages, %options) = @_;

    local ($_, *F);
    open F, $urpm->{skiplist};
    while (<F>) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	foreach (keys %{$urpm->{params}{provides}{$_} || {}}) {
	    my $pkg = $urpm->{params}{info}{$_} or next;
	    $pkg->{arch} eq 'src' and next; #- never ignore source package.
	    $options{force} || (exists $packages->{$pkg->{id}} && defined $packages->{$pkg->{id}})
	      and delete $packages->{$pkg->{id}};
	}
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
    my ($id, $error, %local_sources, @list, @local_to_removes, %fullname2id, %file2fullnames);
    local (*D, *F, $_);

    #- build association hash to retrieve id and examine all list files.
    foreach (keys %$packages) {
	my $p = $urpm->{params}{depslist}[$_];
	if ($p->{source}) {
	    $local_sources{$_} = $p->{source};
	} else {
	    $fullname2id{"$p->{name}-$p->{version}-$p->{release}.$p->{arch}"} = $_;
	}
    }

    #- examine each medium to search for packages.
    #- now get rpm file name in hdlist to match list file.
    foreach my $medium (@{$urpm->{media} || []}) {
	foreach (@{$medium->{depslist} || []}) {
	    my $fullname = "$_->{name}-$_->{version}-$_->{release}.$_->{arch}";
	    $file2fullnames{($_->{file} =~ /(.*)\.rpm$/ && $1) || $fullname}{$fullname} = undef;
	}
    }

    #- examine the local repository, which is trusted.
    opendir D, "$urpm->{cachedir}/rpms";
    while (defined($_ = readdir D)) {
	if (/([^\/]*)\.rpm/) {
	    if (-s "$urpm->{cachedir}/rpms/$1.rpm") {
		if (keys(%{$file2fullnames{$1} || {}}) > 1) {
		    $urpm->{error}(_("there are multiple packages with the same rpm filename \"%s\""), $1);
		    next;
		} elsif (keys(%{$file2fullnames{$1} || {}}) == 1) {
		    my ($fullname) = keys(%{$file2fullnames{$1} || {}});
		    if (defined($id = delete $fullname2id{$fullname})) {
			$local_sources{$id} = "$urpm->{cachedir}/rpms/$1.rpm";
		    } else {
			push @local_to_removes, "$urpm->{cachedir}/rpms/$1.rpm";
		    }
		}
	    } else {
		#- this is an invalid file in cache, remove it and ignore it.
		unlink "$urpm->{cachedir}/rpms/$1.rpm";
	    }
	} #- no error on unknown filename located in cache (because .listing)
    }
    closedir D;

    foreach my $medium (@{$urpm->{media} || []}) {
	my %sources;

	if (-r "$urpm->{statedir}/$medium->{list}" && !$medium->{ignore}) {
	    open F, "$urpm->{statedir}/$medium->{list}";
	    while (<F>) {
		if (/(.*)\/([^\/]*)\.rpm$/) {
		    if (keys(%{$file2fullnames{$2} || {}}) > 1) {
			$urpm->{error}(_("there are multiple packages with the same rpm filename \"%s\""), $2);
			next;
		    } elsif (keys(%{$file2fullnames{$2} || {}}) == 1) {
			my ($fullname) = keys(%{$file2fullnames{$2} || {}});
			defined($id = delete $fullname2id{$fullname}) and $sources{$id} = "$1/$2.rpm";
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
	push @list, \%sources;
    }

    #- examine package list to see if a package has not been found.
    foreach (keys %fullname2id) {
	$error = 1;
	$urpm->{error}(_("package %s is not found.", $_));
    }	

    $error ? () : ( \%local_sources, \@list, \@local_to_removes );
}

#- download package that may need to be downloaded.
#- make sure header are available in the appropriate directory.
#- change location to find the right package in the local
#- filesystem for only one transaction.
#- try to mount/eject removable media here.
#- return a list of package ready for rpm.
sub download_source_packages {
    my ($urpm, $local_sources, $list, $force_local, $ask_for_medium) = @_;
    my (%sources, @distant_sources, %media, %removables);

    #- make sure everything is correct on input...
    @{$urpm->{media}} == @$list or return;

    #- removable media have to be examined to keep mounted the one that has
    #- more package than other (size is better ?).
    my $examine_removable_medium = sub {
	my ($id, $device, $copy) = @_;
	my $medium = $urpm->{media}[$id];
	$media{$id} = undef;
	if (my ($prefix, $dir) = $medium->{url} =~ /^(removable[^:]*|file):\/(.*)/) {
	    my $check_notfound = sub {
		if (-e $dir) {
		    foreach (values %{$list->[$id]}) {
			/^(removable_?[^_:]*|file):\/(.*\/([^\/]*))/ or next;
			-r $2 or return 1;
		    }
		} else {
		    return 2;
		}
		return 0;
	    };
	    #- the directory given does not exist or may be accessible
	    #- by mounting some other. try to figure out these directory and
	    #- mount everything necessary.
	    $urpm->try_mounting($dir);
	    while ($check_notfound->()) {
		$ask_for_medium or $urpm->{fatal}(4, _("medium \"%s\" is not selected", $medium->{name}));
		$urpm->try_umounting($dir); system("eject", $device);
		$ask_for_medium->($medium->{name}, $medium->{removable}) or
		  $urpm->{fatal}(4, _("medium \"%s\" is not selected", $medium->{name}));
		$urpm->try_mounting($dir);
	    }
	    if (-e $dir) {
		my @removable_sources;
		while (my ($i, $url) = each %{$list->[$id]}) {
		    $url =~ /^(removable[^:]*|file):\/(.*\/([^\/]*))/ or next;
		    -r $2 or $urpm->{error}(_("unable to read rpm file [%s] from medium \"%s\"", $2, $medium->{name}));
		    if ($copy) {
			push @removable_sources, $2;
			$sources{$i} = "$urpm->{cachedir}/rpms/$3";
		    } else {
			$sources{$i} = $2;
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
	values %{$list->[$_]} or next;
	my $medium = $urpm->{media}[$_];
	#- examine non removable device but that may be mounted.
	if ($medium->{removable}) {
	    push @{$removables{$medium->{removable}} ||= []}, $_;
	} elsif (my ($prefix, $dir) = $medium->{url} =~ /^(removable[^:]*|file):\/(.*)/) {
	    -e $dir || $urpm->try_mounting($dir) or
	      $urpm->{error}(_("unable to access medium \"%s\"", $medium->{name})), next;
	}
    }
    foreach my $device (keys %removables) {
	#- here we have only removable device.
	#- if more than one media use this device, we have to sort
	#- needed package to copy first the needed rpms files.
	if (@{$removables{$device}} > 1) {
	    my @sorted_media = sort { values %{$list->[$a]} <=> values %{$list->[$b]} } @{$removables{$device}};

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
    foreach (0..$#$list) {
	exists $media{$_} and next;
	values %{$list->[$_]} or next;
	while (my ($i, $url) = each %{$list->[$_]}) {
	    if ($url =~ /^(removable[^:]*|file):\/(.*)/) {
		$sources{$i} = $2;
	    } elsif ($url =~ /^([^:]*):\/(.*\/([^\/]*))/) {
		if ($force_local) {
		    push @distant_sources, $url;
		    $sources{$i} = "$urpm->{cachedir}/rpms/$3";
		} else {
		    $sources{$i} = $url;
		}
	    } else {
		$urpm->{error}(_("malformed input: [%s]", $url));
	    }
	}
    }
    @distant_sources and eval {
	$urpm->{log}(_("retrieving rpms files..."));
	foreach (map { m|([^:]*://[^/:\@]*:)[^/:\@]*(\@.*)| ? "$1xxxx$2" : $_ } @distant_sources) {
	    $urpm->{log}("    $_") ;
	}
	$urpm->{sync}("$urpm->{cachedir}/rpms", @distant_sources);
	$urpm->{log}(_("...retrieving done"));
    };
    $@ and $urpm->{log}(_("...retrieving failed: %s", $@));

    #- return the hash of rpm file that have to be installed, they are all local now.
    %$local_sources, %sources;
}

#- extract package that should be installed instead of upgraded,
#- sources is a hash of id -> source rpm filename.
sub extract_packages_to_install {
    my ($urpm, $sources) = @_;

    my %inst;
    local ($_, *F);
    open F, $urpm->{instlist};
    while (<F>) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	foreach (keys %{$urpm->{params}{provides}{$_} || {}}) {
	    my $pkg = $urpm->{params}{info}{$_} or next;

	    #- some package with specific naming convention to avoid upgrade problem
	    #- should not be taken into account here.
	    #- these package have version=1 and release=1mdk, and name contains version and release.
	    $pkg->{version} eq '1' && $pkg->{release} eq '1mdk' && $pkg->{name} =~ /^.*-[^\-]*mdk$/ and next;

	    exists $sources->{$pkg->{id}} and $inst{$pkg->{id}} = delete $sources->{$pkg->{id}};
	}
    }
    close F;

    \%inst;
}

sub select_packages_to_upgrade {
    my ($urpm, $prefix, $packages, $remove_packages, $keep_files, %options) = @_;
    my $db = rpmtools::db_open($prefix);
    my $sig_handler = sub { rpmtools::db_close($db); exit 3 };
    local $SIG{INT} = $sig_handler;
    local $SIG{QUIT} = $sig_handler;

    #- used for package that are not correctly updated.
    #- should only be used when nothing else can be done correctly.
    my %upgradeNeedRemove = (
			     #'libstdc++' => 1,
			     #'compat-glibc' => 1,
			     #'compat-libs' => 1,
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
    if (my $pid = $options{use_parsehdlist} ? fork() : 1) {
	close INPUT_CHILD;
	close OUTPUT_CHILD;
	#- check if there is a parsehdlist running in the background.
	if ($pid == 1) {
	    close INPUT;
	    close OUTPUT;
	} else {
	    select((select(OUTPUT), $| = 1)[0]);
	}

	#- internal reading from interactive mode of parsehdlist.
	#- takes a code to call with the line read, this avoid allocating
	#- memory for that.
	my $ask_child = sub {
	    my ($pkg, $tag, $code) = @_;
	    $code or die "no callback code for parsehdlist output";
	    #- check if what is requested is not already available locally (because
	    #- the hdlist does not exists and the medium is marked as using a
	    #- synthesis file).
	    if ($pid == 1 || $pkg && @{$pkg->{$tag} || []}) {
		foreach (@{$pkg->{$tag} || []}) {
		    $code->($_);
		}
	    } else {
		print OUTPUT "$pkg->{name}-$pkg->{version}-$pkg->{release}.$pkg->{arch}:$tag\n";

		local $_;
		while (<INPUT>) {
		    chomp;
		    /^\s*$/ and last;
		    $code->($_);
		}
	    }
	};

	#- select packages which obseletes other package, obselete package are not removed,
	#- should we remove them ? this could be dangerous !
	foreach my $pkg (values %{$urpm->{params}{info}}) {
	    defined $pkg->{id} && $pkg->{arch} ne 'src' or next;
	    $ask_child->($pkg, "obsoletes", sub {
			     #- take care of flags and version and release if present
			     local ($_) = @_;
			     if (my ($n,$o,$v,$r) = /^([^\s\[]*)(?:\[\*\])?(?:\s+|\[)?([^\s\]]*)\s*([^\s\-\]]*)-?([^\s\]]*)/) {
				 my $obsoleted = 0;
				 my $check_obsoletes = sub {
				     my ($p) = @_;
				     (!$v || eval(rpmtools::version_compare($p->{version}, $v) . $o . 0)) &&
				       (!$r || rpmtools::version_compare($p->{version}, $v) != 0 ||
					eval(rpmtools::version_compare($p->{release}, $r) . $o . 0)) or return;
				     ++$obsoleted;
				 };
				 rpmtools::db_traverse_tag($db, "name", [ $n ], [ qw(name version release) ], $check_obsoletes);
				 if ($obsoleted > 0) {
				     $urpm->{log}(_("selecting %s using obsoletes",
						    "$pkg->{name}-$pkg->{version}-$pkg->{release}"));
				     $obsoletedPackages{$n} = undef;
				     $pkg->{selected} = 1;
				 }
			     }
			 });
	}

	#- mark all files which are not in /dev or /etc/rc.d/ for packages which are already installed
	#- but which are not in the packages list to upgrade.
	#- the 'installed' property will make a package unable to be selected, look at select.
	rpmtools::db_traverse($db, [ qw(name version release serial files) ], sub {
				  my ($p) = @_;
				  my $otherPackage = $p->{release} !~ /mdk\w*$/ && "$p->{name}-$p->{version}-$p->{release}";
				  my $pkg = $urpm->{params}{names}{$p->{name}};

				  if ($pkg) {
				      my $version_cmp = rpmtools::version_compare($p->{version}, $pkg->{version});
				      if ($p->{serial} > $pkg->{serial} || $p->{serial} == $pkg->{serial} &&
					  ($version_cmp > 0 ||
					   $version_cmp == 0 &&
					   rpmtools::version_compare($p->{release}, $pkg->{release}) >= 0)) {
					  if ($otherPackage && $version_cmp <= 0) {
					      $toRemove{$otherPackage} = 0;
					      $pkg->{selected} = 1;
					      $urpm->{log}(_("removing %s to upgrade to %s ...
  since it will not be updated otherwise", $otherPackage, "$pkg->{name}-$pkg->{version}-$pkg->{release}"));
					  } else {
					      $pkg->{installed} = 1;
					  }
				      } elsif ($upgradeNeedRemove{$pkg->{name}}) {
					  my $otherPackage = "$p->{name}-$p->{version}-$p->{release}";
					  $toRemove{$otherPackage} = 0;
					  $pkg->{selected} = 1;
					  $urpm->{log}(_("removing %s to upgrade to %s ...
  since it will not upgrade correctly!", $otherPackage, "$pkg->{name}-$pkg->{version}-$pkg->{release}"));
				      }
				  } else {
				      if (exists $obsoletedPackages{$p->{name}}) {
					  @installedFilesForUpgrade{grep { ($_ !~ m|^/dev/| && $_ !~ m|^/etc/rc.d/| &&
									    $_ !~ m|\.la$| &&
									    ! -d "$prefix/$_" && ! -l "$prefix/$_") }
								      @{$p->{files}}} = ();
				      }
				  }
			      });

	#- find new packages to upgrade.
	foreach my $pkg (values %{$urpm->{params}{info}}) {
	    defined $pkg->{id} && $pkg->{arch} ne 'src' or next;

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
					      @installedFilesForUpgrade{grep { ($_ !~ m|^/dev/| && $_ !~ m|^/etc/rc.d/| &&
										$_ !~ m|\.la$| &&
										! -d "$prefix/$_" && ! -l "$prefix/$_") }
									  @{$p->{files}}} = ();
					  });

		$ask_child->($pkg, "files", sub {
				 delete $installedFilesForUpgrade{$_[0]};
			     });
	    }
	}

	#- unmark all files for all packages marked for upgrade. it may not have been done above
	#- since some packages may have been selected by depsList.
	foreach my $pkg (values %{$urpm->{params}{info}}) {
	    defined $pkg->{id} && $pkg->{arch} ne 'src' or next;
	    if ($pkg->{selected}) {
		$ask_child->($pkg, "files", sub {
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
	    defined $pkg->{id} && $pkg->{arch} ne 'src' or next;
	    unless ($pkg->{selected}) {
		my $toSelect = 0;
		$ask_child->($pkg, "files", sub {
				 if ($_[0] !~ m|^/dev/| && $_[0] !~ m|^/etc/rc.d/| &&
				     $_ !~ m|\.la$| && exists $installedFilesForUpgrade{$_[0]}) {
				     ++$toSelect if ! -d "$prefix/$_[0]" && ! -l "$prefix/$_[0]";
				 }
				 delete $installedFilesForUpgrade{$_[0]};
			     });
		if ($toSelect) {
		    if ($toSelect <= 1 && $pkg->{name} =~ /-devel/) {
			$urpm->{log}(_("avoid selecting %s as not enough files will be updated",
				       "$pkg->{name}-$pkg->{version}-$pkg->{release}"));
		    } else {
			#- default case is assumed to allow upgrade.
			my @deps = map { /\|/ and next; #- do not inspect choice
					 my $p = $urpm->{params}{depslist}[$_];
					 $p && $p->{name} =~ /locales-/ ? ($p) : () } split ' ', $pkg->{deps};
			if (@deps == 0 ||
			    @deps > 0 && (grep { !$_->{selected} && !$_->{installed} } @deps) == 0) {
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
	#- but only if a child has really been used.
	if ($pid != 1) {
	    close OUTPUT;
	    close INPUT;
	    waitpid $pid, 0;
	}
    } else {
	close INPUT;
	close OUTPUT;
	open STDIN, "<&INPUT_CHILD";
	open STDOUT, ">&OUTPUT_CHILD";
	exec "parsehdlist", "--interactive", (map { "$urpm->{statedir}/$_->{hdlist}" }
					      grep { ! $_->{synthesis} && ! $_->{ignore} } @{$urpm->{media} || []})
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
