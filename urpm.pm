package urpm;

use strict;
use vars qw($VERSION @ISA);

$VERSION = '4.0';
@ISA = qw(URPM);

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
        push @names, $urpm->register_rpms(@files);
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

perl-URPM (obsolete rpmtools) package is used to manipulate at a lower
level hdlist and rpm files.

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

use URPM;
use POSIX;
use Locale::gettext();

#- I18N.
setlocale (LC_ALL, "");
Locale::gettext::textdomain ("urpmi");

sub _ {
    my ($format, @params) = @_;
    sprintf(Locale::gettext::gettext($format), @params);
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

	   provides   => {},
	   depslist   => [],

	   sync       => \&sync_webfetch, #- first argument is directory, others are url to fetch.
	   proxy      => get_proxy(),

	   fatal      => sub { printf STDERR "%s\n", $_[1]; exit($_[0]) },
	   error      => sub { printf STDERR "%s\n", $_[0] },
	   log        => sub { printf STDERR "%s\n", $_[0] },
	  }, $class;
}

sub get_proxy {
    my $proxy = {
		 http_proxy => undef ,
		 ftp_proxy => undef ,
		 user => undef,
		 pwd => undef
		};
    local (*F, $_);
    open F, "/etc/urpmi/proxy.cfg" or return undef;
    while (<F>) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	/^http_proxy\s*=\s*(.*)$/ and $proxy->{http_proxy} = $1, next;
	/^ftp_proxy\s*=\s*(.*)$/ and $proxy->{ftp_proxy} = $1, next;
	/^proxy_user\s*=\s*(.*):(.*)$/ and do {
	    $proxy->{user} = $1;
	    $proxy->{pwd} = $2;
	    next;
	};
	next;
    }
    close F;
    $proxy;
}

sub set_proxy {
    my $proxy = shift @_;
    my @res;
    if (defined $proxy->{proxy}->{http_proxy} or defined $proxy->{proxy}->{ftp_proxy}) {
	for ($proxy->{type}) {
	    /wget/ && do {
		for ($proxy->{proxy}) {
		    $ENV{http_proxy} = $_->{http_proxy} if defined $_->{http_proxy};
		    $ENV{ftp_proxy} = $_->{ftp_proxy} if defined $_->{ftp_proxy};
		    @res = ("--proxy-user=$_->{user}", "--proxy-passwd=$_->{pwd}") if defined $_->{user} && defined $_->{pwd};
		}
		last;
	    };
	    /curl/ && do {
		for ($proxy->{proxy}) {
		    push @res, "-x $_->{http_proxy}" if defined $_->{http_proxy};
		    push @res, "-x $_->{ftp_proxy}" if defined $_->{ftp_proxy};
		    push @res, "-U $_->{user}:$_->{pwd}" if defined $_->{user} && defined $_->{pwd};
		}
		last;
	    };
	    die _("Unknown webfetch `%s' !!!\n",$proxy->{type});
	}
    }
    return @res;
}

#- quoting/unquoting a string that may be containing space chars.
sub quotespace { local $_ = $_[0]; s/(\s)/\\$1/g; $_ }
sub unquotespace { local $_ = $_[0]; s/\\(\s)/$1/g; $_ }

#- syncing algorithms, currently is implemented wget and curl methods,
#- webfetch is trying to find the best (and one which will work :-)
sub sync_webfetch {
    my $options = shift @_;
    my %files;
    #- extract files according to protocol supported.
    #- currently ftp and http protocol are managed by curl or wget,
    #- ssh and rsync protocol are managed by rsync *AND* ssh.
    foreach (@_) {
	/^([^:]*):/ or die _("unknown protocol defined for %s", $_);
	push @{$files{$1}}, $_;
    }
    if ($files{ftp} || $files{http}) {
	if (-x "/usr/bin/curl" && (! ref $options || $options->{prefer} ne 'wget' || ! -x "/usr/bin/wget")) {
	    sync_curl($options, @{$files{ftp} || []}, @{$files{http} || []});
	} elsif (-x "/usr/bin/wget") {
	    sync_wget($options, @{$files{ftp} || []}, @{$files{http} || []});
	} else {
	    die _("no webfetch (curl or wget currently) found\n");
	}
	delete @files{qw(ftp http)};
    }
    if ($files{rsync} || $files{ssh}) {
	my @rsync_files = @{$files{rsync} || []};
	foreach (@{$files{ssh} || []}) {
	    /^ssh:\/\/([^\/]*)(.*)/ and push @rsync_files, "$1:$2";
	}
	sync_rsync($options, @rsync_files);
	delete @files{qw(rsync ssh)};
    }
    %files and die _("unable to handle protocol: %s", join ', ', keys %files);
}
sub sync_wget {
    -x "/usr/bin/wget" or die _("wget is missing\n");
    my $options = shift @_;
    system "/usr/bin/wget",
    	(ref $options && set_proxy({type => "wget", proxy => $options->{proxy}})),
    	(ref $options && $options->{quiet} ? ("-q") : ()), "-NP",
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
	open CURL, "/usr/bin/curl" .
		" " . (ref $options && set_proxy({type => "curl", proxy => $options->{proxy}})) .
		" " . (ref $options && $options->{quiet} ? ("-s") : ()) .
		" -I " . join(" ", map { "'$_'" } @ftp_files) . " |";
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
	system "/usr/bin/curl",
		(ref $options && set_proxy({type => "curl", proxy => $options->{proxy}})),
		(ref $options && $options->{quiet} ? ("-s") : ()), "-R", "-f",
		@all_files;
	$? == 0 or die _("curl failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
    }
}
sub sync_rsync {
    -x "/usr/bin/rsync" or die _("rsync is missing\n");
    -x "/usr/bin/ssh" or die _("ssh is missing\n");
    my $options = shift @_;
    foreach (@_) {
	my $count = 10; #- retry count on error (if file exists).
	my $basename = (/^.*\/([^\/]*)$/ && $1) || $_;
	do {
	    system "/usr/bin/rsync", (ref $options && $options->{quiet} ? ("-q") : ("--progress", "-v")), "--partial", "-e", "ssh",
	      $_, (ref $options ? $options->{dir} : $options);
	} while ($? != 0 && --$count > 0 && (-e (ref $options ? $options->{dir} : $options) . "/$basename"));
    }
    $? == 0 or die _("rsync failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
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
		/^modified\s*$/ and next; # IGNORED TO AVOID EXCESIVE REMOVE $medium->{modified} = 1, next;
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
	  $_->{ignore} = 1, $urpm->{error}(_("medium \"%s\" trying to use an already used hdlist, medium ignored", $_->{name}));
	$hdlists{$_->{hdlist}} = undef;
	exists $lists{$_->{list}} and
	  $_->{ignore} = 1, $urpm->{error}(_("medium \"%s\" trying to use an already used list, medium ignored", $_->{name}));
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

#- read urpmi.cfg file as well as synthesis file needed.
sub configure {
    my ($urpm, %options) = @_;

    $urpm->clean;

    if ($options{parallel}) {
	my ($parallel_options, $parallel_handler);
	#- handle parallel configuration, examine all module available that
	#- will handle the parallel mode (configuration is /etc/urpmi/parallel.cfg).
	local ($_, *PARALLEL);
	open PARALLEL, "/etc/urpmi/parallel.cfg";
	while (<PARALLEL>) {
	    chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	    /\s*([^:]*):(.*)/ or $urpm->{error}(_("unable to parse \"%s\" in file [%s]", $_, "/etc/urpmi/parallel.cfg")), next;
	    $1 eq $options{parallel} and $parallel_options = ($parallel_options && "\n") . $2;
	}
	close PARALLEL;
	#- if a configuration options has been found, use it else fatal error.
	if ($parallel_options) {
	    foreach my $dir (grep { -d $_ } map { "$_/urpm" } @INC) {
		local *DIR;
		opendir DIR, $dir;
		while ($_ = readdir DIR) {
		    -f "$dir/$_" or next;
		    $urpm->{log}->(_("examining parallel handler in file [%s]", "$dir/$_"));
		    eval { require "$dir/$_"; $parallel_handler = $urpm->handle_parallel_options($parallel_options) };
		    $parallel_handler and last;
		}
		closedir DIR;
		$parallel_handler and last;
	    }
	}
	if ($parallel_handler) {
	    if ($parallel_handler->{nodes}) {
		$urpm->{log}->(_("found parallel handler for nodes: %s", join(', ', keys %{$parallel_handler->{nodes}})));
	    }
	    if (!$options{media} && $parallel_handler->{media}) {
		$options{media} = $parallel_handler->{media};
		$urpm->{log}->(_("using associated media for parallel mode : %s", $options{media}));
	    }
	    $urpm->{parallel_handler} = $parallel_handler;
	} else {
	    $urpm->{fatal}(1, _("unable to use parallel option \"%s\"", $options{parallel}));
	}
    } else {
	#- parallel is exclusive against root options.
	$urpm->{root} = $options{root};
    }

    if ($options{synthesis}) {
	#- synthesis take precedence over media, update options.
	$options{media} || $options{update} || $options{parallel} and
	  $urpm->{fatal}(1, _("--synthesis cannot be used with --media, --update or --parallel"));
	$urpm->parse_synthesis($options{synthesis});
    } else {
	$urpm->read_config(%options);
	if ($options{media}) {
	    $urpm->select_media(split ',', $options{media});
	    foreach (grep { !$_->{modified} } @{$urpm->{media} || []}) {
		#- this is only a local ignore that will not be saved.
		$_->{ignore} = 1;
	    }
	}
	$options{parallel} and unlink "$urpm->{cachedir}/partial/parallel.cz";
	foreach (grep { !$_->{ignore} && (!$options{update} || $_->{update}) } @{$urpm->{media} || []}) {
	    delete @{$_}{qw(start end)};
	    if ($options{callback}) {
		if (-s "$urpm->{statedir}/$_->{hdlist}" > 32) {
		    $urpm->{log}(_("examining hdlist file [%s]", "$urpm->{statedir}/$_->{hdlist}"));
		    eval { ($_->{start}, $_->{end}) = $urpm->parse_hdlist("$urpm->{statedir}/$_->{hdlist}", 0) };
		}
		unless (defined $_->{start} && defined $_->{end}) {
		    $urpm->{error}(_("problem reading hdlist file of medium \"%s\"", $_->{name}));
		    $_->{ignore} = 1;
		} else {
		    #- medium has been read correclty, now call the callback for each packages.
		    #- it is the responsability of callback to pack the header.
		    foreach ($_->{start} .. $_->{end}) {
			$options{callback}->($urpm, $_, %options);
		    }
		}
	    } else {
		if (-s "$urpm->{statedir}/synthesis.$_->{hdlist}" > 32) {
		    $urpm->{log}(_("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$_->{hdlist}"));
		    eval { ($_->{start}, $_->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$_->{hdlist}") };
		}
		unless (defined $_->{start} && defined $_->{end}) {
		    $urpm->{error}(_("problem reading synthesis file of medium \"%s\"", $_->{name}));
		    $_->{ignore} = 1;
		} else {
		    $options{parallel} and system "cat '$urpm->{statedir}/synthesis.$_->{hdlist}' >> $urpm->{cachedir}/partial/parallel.cz";
		}
	    }
	}
    }
    if ($options{bug}) {
	#- and a dump of rpmdb itself as synthesis file.
	my $db = URPM::DB::open($options{root});
	my $sig_handler = sub { undef $db; exit 3 };
	local $SIG{INT} = $sig_handler;
	local $SIG{QUIT} = $sig_handler;
	local *RPMDB;
	open RPMDB, "| " . ($ENV{LD_LOADER} || '') . " gzip -9 >'$options{bug}/rpmdb.cz'";
	$db->traverse(sub{
			  my ($p) = @_;
			  #- this is not right but may be enough.
			  my $files = join '@', grep { exists $urpm->{provides}{$_} } $p->files;
			  $p->pack_header;
			  $p->build_info(fileno *RPMDB, $files);
		      });
	close RPMDB;
    }
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
	    $urpm->{sync}({dir => "$urpm->{cachedir}/partial", quiet => 0, proxy => $urpm->{proxy}}, reduce_pathname("$url/Mandrake/base/hdlists"));
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
	    m/^\s*(?:noauto:)?(hdlist\S*\.cz2?)\s+(\S+)\s*(.*)$/ or $urpm->{error}(_("invalid hdlist description \"%s\" in hdlists file"), $_);
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
		$urpm->{log}(_("selecting multiple media: %s", join(", ", map { _("\"%s\"", $_->{name}) }
								    (@found ? @found : @foundi))));
		#- changed behaviour to select all occurence by default.
		foreach (@found ? @found : @foundi) {
		    $_->{modified} = 1;
		}
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

#- update urpmi database regarding the current configuration.
#- take care of modification and try some trick to bypass
#- computational of base files.
#- allow options :
#-   all               -> all medium are rebuilded.
#-   force             -> try to force rebuilding base files (1) or hdlist from rpm files (2).
#-   probe_with_hdlist -> probe synthesis or hdlist.
#-   ratio             -> use compression ratio (with gzip, default is 4)
#-   noclean           -> keep header directory cleaned.
sub update_media {
    my ($urpm, %options) = @_; #- do not trust existing hdlist and try to recompute them.
    my ($cleaned_cache);

    #- take care of some options.
    $cleaned_cache = !$options{noclean};

    #- avoid trashing existing configuration in this case.
    $urpm->{media} or return;

    #- now we need additional methods not defined by default in URPM.
    require URPM::Build;

    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my ($LOCK_EX, $LOCK_NB, $LOCK_UN) = (2, 4, 8);

    #- lock urpmi database.
    local (*LOCK_FILE);
    open LOCK_FILE, $urpm->{statedir};
    flock LOCK_FILE, $LOCK_EX|$LOCK_NB or $urpm->{fatal}(7, _("urpmi database locked"));

    #- examine each medium to see if one of them need to be updated.
    #- if this is the case and if not forced, try to use a pre-calculated
    #- hdlist file else build it from rpm files.
    $urpm->clean;
    foreach my $medium (@{$urpm->{media}}) {
	#- take care of modified medium only or all if all have to be recomputed.
	$medium->{ignore} and next;

	#- and create synthesis file associated if it does not already exists...
	-s "$urpm->{statedir}/synthesis.$medium->{hdlist}" > 32 or $medium->{modified_synthesis} = 1;

	#- but do not take care of removable media for all.
	$medium->{modified} ||= $options{all} && $medium->{url} !~ /removable/;
	unless ($medium->{modified}) {
	    #- the medium is not modified, but for computing dependencies,
	    #- we still need to read it and all synthesis will be written if
	    #- a unresolved provides is found.
	    #- to speed up the process, we only read the synthesis at the begining.
	    $urpm->{log}(_("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
	    ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
	    unless (defined $medium->{start} && defined $medium->{end}) {
		#- this is almost a fatal error, ignore it by default?
		$urpm->{error}(_("problem reading synthesis file of medium \"%s\"", $medium->{name}));
		$medium->{ignore} = 1;
	    }
	    next;
	}

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
		unless ($error || $options{force} || ! -e "$urpm->{statedir}/synthesis.$medium->{hdlist}") {
		    my @sstat = stat "$urpm->{cachedir}/partial/$medium->{hdlist}";
		    my @lstat = stat "$urpm->{statedir}/$medium->{hdlist}";
		    if ($sstat[7] == $lstat[7] && $sstat[9] == $lstat[9]) {
			#- the two files are considered equal here, the medium is so not modified.
			$medium->{modified} = 0;
			unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
			#- as previously done, just read synthesis file here, this is enough, but only
			#- if synthesis exists, else it need to be recomputed.
			$urpm->{log}(_("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
			($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
			unless (defined $medium->{start} && defined $medium->{end}) {
			    $urpm->{error}(_("problem reading synthesis file of medium \"%s\"", $medium->{name}));
			    $medium->{ignore} = 1;
			}
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
			$urpm->{log}(_("reading rpm files from [%s]", $dir));
			my @unresolved_before = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};
			$medium->{start} = @{$urpm->{depslist}};
			$medium->{headers} = [ $urpm->parse_rpms_build_headers(dir   => "$urpm->{cachedir}/headers",
									       rpms  => \@files,
									       clean => $cleaned_cache,
									      ) ];
			$medium->{end} = $#{$urpm->{depslist}};
			if ($medium->{start} > $medium->{end}) {
			    #- an error occured (provided there are files in input.
			    delete $medium->{start};
			    delete $medium->{end};
			    die "no rpms read\n";
			} else {
			    $cleaned_cache = 0; #- make sure the headers will not be removed for another media.
			    my @unresolved_after = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};
			    @unresolved_before == @unresolved_after or $urpm->{second_pass} = 1;
			}
		    };
		    $@ and $error = 1, $urpm->{error}(_("unable to read rpm files from [%s]: %s", $dir, $@));
		    $error and delete $medium->{headers}; #- do not propagate these.
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
		$urpm->{sync}({ dir => "$urpm->{cachedir}/partial", quiet => 1, proxy => $urpm->{proxy} },
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
			$urpm->{sync}({ dir => "$urpm->{cachedir}/partial", quiet => 1, proxy => $urpm->{proxy} }, reduce_pathname("$medium->{url}/$_"));
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
		    $urpm->{sync}({ dir => "$urpm->{cachedir}/partial", quiet => 0, proxy => $urpm->{proxy}}, reduce_pathname("$medium->{url}/$medium->{with_hdlist}"));
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
			#- as previously done, just read synthesis file here, this is enough.
			$urpm->{log}(_("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
			eval { ($medium->{start}, $medium->{end}) =
				 $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}") };
			unless (defined $medium->{start} && defined $medium->{end}) {
			    $urpm->{error}(_("problem reading synthesis file of medium \"%s\"", $medium->{name}));
			    $medium->{ignore} = 1;
			}
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
			$urpm->{sync}({ dir => "$urpm->{cachedir}/partial", quiet => 1, proxy => $urpm->{proxy}},
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
	unless ($medium->{headers} || -s "$urpm->{cachedir}/partial/$medium->{hdlist}" > 32) {
	    $error = 1;
	    $urpm->{error}(_("no hdlist file found for medium \"%s\"", $medium->{name}));
	}

	#- make sure group and other does not have any access to this file.
	unless ($error) {
	    #- sort list file contents according to id.
	    my %list;
	    if ($medium->{headers}) {
		#- rpm files have already been read (first pass), there is just a need to
		#- build list hash.
		foreach (@files) {
		    /\/([^\/]*\.rpm)$/ or next;
		    $list{$1} and $urpm->{error}(_("file [%s] already used in the same medium \"%s\"", $1, $medium->{name})), next;
		    $list{$1} = "$prefix:/$_\n";
		}
	    } else {
		#- read first pass hdlist or synthesis, try to open as synthesis, if file
		#- is larger than 1MB, this is problably an hdlist else a synthesis.
		#- anyway, if one tries fails, try another mode.
		my @unresolved_before = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};
		if (!$medium->{synthesis} || -s "$urpm->{cachedir}/partial/$medium->{hdlist}" > 262144) {
		    $urpm->{log}(_("examining hdlist file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
		    ($medium->{start}, $medium->{end}) = $urpm->parse_hdlist("$urpm->{cachedir}/partial/$medium->{hdlist}", 1);
		    if (defined $medium->{start} && defined $medium->{end}) {
			delete $medium->{synthesis};
		    } else {
			$urpm->{log}(_("examining synthesis file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
			($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{cachedir}/partial/$medium->{hdlist}");
			defined $medium->{start} && defined $medium->{end} and $medium->{synthesis} = 1;
		    }
		} else {
		    $urpm->{log}(_("examining synthesis file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
		    ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{cachedir}/partial/$medium->{hdlist}");
		    if (defined $medium->{start} && defined $medium->{end}) {
			$medium->{synthesis} = 1;
		    } else {
			$urpm->{log}(_("examining hdlist file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
			($medium->{start}, $medium->{end}) = $urpm->parse_hdlist("$urpm->{cachedir}/partial/$medium->{hdlist}", 1);
			defined $medium->{start} && defined $medium->{end} and delete $medium->{synthesis};
		    }
		}
		unless (defined $medium->{start} && defined $medium->{end}) {
		    $error = 1;
		    $urpm->{error}(_("unable to parse hdlist file of \"%s\"", $medium->{name}));
		    #- we will have to read back the current synthesis file unmodified.
		}

		unless ($error) {
		    my @unresolved_after = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};
		    @unresolved_before == @unresolved_after or $urpm->{second_pass} = 1;

		    if ($medium->{hdlist} ne 'list' && -s "$urpm->{cachedir}/partial/list") {
			local (*F, $_);
			open F, "$urpm->{cachedir}/partial/list";
			while (<F>) {
			    /\/([^\/]*\.rpm)$/ or next;
			    $list{$1} and $urpm->{error}(_("file [%s] already used in the same medium \"%s\"", $1, $medium->{name})), next;
			    $list{$1} = "$medium->{url}/$_";
			}
			close F;
		    } else {
			foreach ($medium->{start} .. $medium->{end}) {
			    my $filename = $urpm->{depslist}[$_]->filename;
			    $list{$filename} = "$medium->{url}/$filename\n";
			}
		    }
		}
	    }

	    #- check there is something found.
	    %list or $error = 1, $urpm->{error}(_("nothing to write in list file for \"%s\"", $medium->{name}));

	    unless ($error) {
		#- write list file.
		local *LIST;
		my $mask = umask 077;
		open LIST, ">$urpm->{cachedir}/partial/$medium->{list}"
		  or $error = 1, $urpm->{error}(_("unable to write list file of \"%s\"", $medium->{name}));
		umask $mask;
		print LIST values %list;
		close LIST;

		#- check if at least something has been written into list file.
		-s "$urpm->{cachedir}/partial/$medium->{list}" > 32 or
		  $error = 1, $urpm->{error}(_("nothing written in list file for \"%s\"", $medium->{name}));
	    }
	}

	if ($error) {
	    #- an error has occured for updating the medium, we have to remove tempory files.
	    unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
	    unlink "$urpm->{cachedir}/partial/$medium->{list}";
	    #- read default synthesis (we have to make sure nothing get out of depslist).
	    $urpm->{log}(_("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
	    eval { ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}") };
	    unless (defined $medium->{start} && defined $medium->{end}) {
		$urpm->{error}(_("problem reading synthesis file of medium \"%s\"", $medium->{name}));
		$medium->{ignore} = 1;
	    }
	} else {
	    #- make sure to rebuild base files and clean medium modified state.
	    $medium->{modified} = 0;
	    $urpm->{modified} = 1;

	    #- but use newly created file.
	    unlink "$urpm->{statedir}/$medium->{hdlist}";
	    $medium->{synthesis} and unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
	    unlink "$urpm->{statedir}/$medium->{list}";
	    unless ($medium->{headers}) {
		rename("$urpm->{cachedir}/partial/$medium->{hdlist}", $medium->{synthesis} ?
		       "$urpm->{statedir}/synthesis.$medium->{hdlist}" : "$urpm->{statedir}/$medium->{hdlist}") or
			 system("mv", "$urpm->{cachedir}/partial/$medium->{hdlist}", $medium->{synthesis} ?
				"$urpm->{statedir}/synthesis.$medium->{hdlist}" :
				"$urpm->{statedir}/$medium->{hdlist}");
	    }
	    rename("$urpm->{cachedir}/partial/$medium->{list}", "$urpm->{statedir}/$medium->{list}") or
	      system("mv", "$urpm->{cachedir}/partial/$medium->{list}", "$urpm->{statedir}/$medium->{list}");

	    #- and create synthesis file associated.
	    $medium->{modified_synthesis} = !$medium->{synthesis};
	}
    }

    #- some unresolved provides may force to rebuild all synthesis,
    #- a second pass will be necessary.
    if ($urpm->{second_pass}) {
	$urpm->{log}(_("performing second pass to compute dependencies\n"));
	$urpm->unresolved_provides_clean;
    }

    #- second pass consist of reading again synthesis or hdlist.
    foreach my $medium (@{$urpm->{media}}) {
	#- take care of modified medium only or all if all have to be recomputed.
	$medium->{ignore} and next;

	#- a modified medium is an invalid medium, we have to read back the previous hdlist
	#- or synthesis which has not been modified by first pass above.
	if ($medium->{headers} && !$medium->{modified}) {
	    if ($urpm->{second_pass}) {
		$urpm->{log}(_("reading headers from medium \"%s\"", $medium->{name}));
		($medium->{start}, $medium->{end}) = $urpm->parse_headers(dir     => "$urpm->{cachedir}/headers",
									  headers => $medium->{headers},
									 );
	    }
	    $urpm->{log}(_("building hdlist [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
	    #- finish building operation of hdlist.
	    $urpm->build_hdlist(start  => $medium->{start},
				end    => $medium->{end},
				dir    => "$urpm->{cachedir}/headers",
				hdlist => "$urpm->{statedir}/$medium->{hdlist}",
			       );
	    #- synthesis need to be created for sure, since the medium has been built from rpm files.
	    $urpm->build_synthesis(start     => $medium->{start},
				   end       => $medium->{end},
				   synthesis => "$urpm->{statedir}/synthesis.$medium->{hdlist}",
				  );
	    $urpm->{log}(_("built hdlist synthesis file for medium \"%s\"", $medium->{name}));
	    #- keep in mind we have modified database, sure at this point.
	    $urpm->{modified} = 1;
	} elsif ($medium->{synthesis}) {
	    if ($urpm->{second_pass}) {
		$urpm->{log}(_("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
		($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
	    }
	} else {
	    if ($urpm->{second_pass}) {
		$urpm->{log}(_("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
		($medium->{start}, $medium->{end}) = $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", 1);
	    }
	    #- check if synthesis file can be built.
	    if (($urpm->{second_pass} || $medium->{modified_synthesis}) && !$medium->{modified}) {
		$urpm->build_synthesis(start     => $medium->{start},
				       end       => $medium->{end},
				       synthesis => "$urpm->{statedir}/synthesis.$medium->{hdlist}",
				      );
		$urpm->{log}(_("built hdlist synthesis file for medium \"%s\"", $medium->{name}));
		#- keep in mind we have modified database, sure at this point.
		$urpm->{modified} = 1;
	    }
	}
    }

    #- clean headers cache directory to remove everything that is no more
    #- usefull according to depslist used.
    if ($urpm->{modified}) {
	if ($options{noclean}) {
	    local (*D, $_);
	    my %headers;
	    opendir D, "$urpm->{cachedir}/headers";
	    while (defined($_ = readdir D)) {
		/^([^\/]*-[^-]*-[^-]*\.[^\.]*)(?::\S*)?$/ and $headers{$1} = $_;
	    }
	    closedir D;
	    $urpm->{log}(_("found %d headers in cache", scalar(keys %headers)));
	    foreach (@{$urpm->{depslist}}) {
		delete $headers{$_->fullname};
	    }
	    $urpm->{log}(_("removing %d obsolete headers in cache", scalar(keys %headers)));
	    foreach (values %headers) {
		unlink "$urpm->{cachedir}/headers/$_";
	    }
	}

	#- this file is written in any cases.
	$urpm->write_config();
    }

    #- now everything is finished.
    system("sync");

    #- release lock on database.
    flock LOCK_FILE, $LOCK_UN;
    close LOCK_FILE;
}

#- clean params and depslist computation zone.
sub clean {
    my ($urpm) = @_;

    $urpm->{depslist} = [];
    $urpm->{provides} = {};

    foreach (@{$urpm->{media} || []}) {
	delete $_->{start};
	delete $_->{end};
    }
}

#- check if supermount is used.
sub is_using_supermount {
    my ($urpm, $device_mntpoint) = @_;
    local (*F, $_);

    #- read /etc/fstab and check for existing mount point.
    open F, "/etc/fstab";
    while (<F>) {
	my ($device, $mntpoint, $fstype, $options) = /^\s*(\S+)\s+(\/\S+)\s+(\S+)\s+(\S+)/ or next;
	$mntpoint =~ s,/+,/,g; $mntpoint =~ s,/$,,;
	if ($fstype eq 'supermount') {
	    $device_mntpoint eq $mntpoint and return 1;
	    $options =~ /^(?:.*[\s,])?dev=([^\s,]+)/ && $device_mntpoint eq $1 and return 1;
	}
    }
    return 0;
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
    my $relocated_entries = $urpm->relocate_depslist;

    $urpm->{log}($relocated_entries ?
		 _("relocated %s entries in depslist", $relocated_entries) :
		 _("no entries relocated in depslist"));
    $relocated_entries;
}

#- register local packages for being installed, keep track of source.
sub register_rpms {
    my ($urpm, @files) = @_;
    my ($start, $id, $error, %requested);

    #- examine each rpm and build the depslist for them using current
    #- depslist and provides environment.
    $start = @{$urpm->{depslist}};
    foreach (@files) {
	/(.*\/)?[^\/]*\.rpm$/ or $error = 1, $urpm->{error}(_("invalid rpm file name [%s]", $_)), next;
	-r $_ or $error = 1, $urpm->{error}(_("unable to access rpm file [%s]", $_)), next;

	($id, undef) = $urpm->parse_rpm($_);
	my $pkg = $urpm->{depslist}[$id];
	$pkg or $urpm->{error}(_("unable to register rpm file")), next;
	$urpm->{source}{$id} = $1 ? $_ :  "./$_";
    }
    $error and $urpm->{fatal}(1, _("error registering local packages"));
    $start <= $id and @requested{($start .. $id)} = (1) x ($id-$start+1);

    %requested;
}

#- search packages registered by their name by storing their id into packages hash.
sub search_packages {
    my ($urpm, $packages, $names, %options) = @_;
    my (%exact, %exact_a, %exact_ra, %found, %foundi);

    foreach my $v (@$names) {
	my $qv = quotemeta $v;

	if ($options{use_provides}) {
	    unless ($options{fuzzy}) {
		#- try to search through provides.
		if (my @l = grep { defined $_ } map { $_ && ($options{src} ? $_->arch eq 'src' : $_->is_arch_compat) ?
							$_->id : undef } map { $urpm->{depslist}[$_] }
		    keys %{$urpm->{provides}{$v} || {}}) {
		    #- we assume that if the there is at least one package providing the resource exactly,
		    #- this should be the best ones that is described.
		    $exact{$v} = join '|',  @l;
		    next;
		}
	    }

	    foreach (keys %{$urpm->{provides}}) {
		#- search through provides to find if a provide match this one.
		#- but manages choices correctly (as a provides may be virtual or
		#- multiply defined.
		if (/$qv/) {
		    my @list = grep { defined $_ }
		      map { my $pkg = $urpm->{depslist}[$_];
			    $pkg && ($options{src} ? $pkg->arch eq 'src' : $pkg->arch ne 'src') ? $pkg->id : undef }
			keys %{$urpm->{provides}{$_} || {}};
		    @list > 0 and push @{$found{$v}}, join '|', @list;
		}
		if (/$qv/i) {
		    my @list = grep { defined $_ }
		      map { my $pkg = $urpm->{depslist}[$_];
			    $pkg && ($options{src} ? $pkg->arch eq 'src' : $pkg->arch ne 'src') ? $pkg->id : undef }
			keys %{$urpm->{provides}{$_} || {}};
		    @list > 0 and push @{$found{$v}}, join '|', @list;
		}
	    }
	}

	foreach my $id (0 .. $#{$urpm->{depslist}}) {
	    my $pkg = $urpm->{depslist}[$id];

	    ($options{src} ? $pkg->arch eq 'src' : $pkg->is_arch_compat) or next;

	    my $pack_ra = $pkg->name . '-' . $pkg->version;
	    my $pack_a = "$pack_ra-" . $pkg->release;
	    my $pack = "$pack_a." . $pkg->arch;

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
	    $packages->{$exact{$_}} = 1;
	} else {
	    #- at this level, we need to search the best package given for a given name,
	    #- always prefer already found package.
	    my %l;
	    foreach (@{$exact_a{$_} || $exact_ra{$_} || $found{$_} || $foundi{$_} || []}) {
		my $pkg = $urpm->{depslist}[$_];
		push @{$l{$pkg->name}}, $pkg;
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
			if ($best && $best != $_) {
			    $_->compare_pkg($best) > 0 and $best = $_;
			} else {
			    $best = $_;
			}
		    }
		    $packages->{$best->id} = 1;
		}
	    }
	}
    }

    #- return true if no error have been encoutered, else false.
    $result;
}

#- do the resolution of dependencies.
sub resolve_dependencies {
    my ($urpm, $state, $requested, %options) = @_;

    if ($urpm->{parallel_handler}) {
	#- let each node determine what is requested, according to handler given.
	$urpm->{parallel_handler}->parallel_resolve_dependencies("$urpm->{cachedir}/partial/parallel.cz", @_);
    } else {
	my $db;

	if ($options{rpmdb}) {
	    $db = new URPM;
	    $db->parse_synthesis($options{rpmdb});
	} else {
	    $db = URPM::DB::open($urpm->{root});
	}

	my $sig_handler = sub { undef $db; exit 3 };
	local $SIG{INT} = $sig_handler;
	local $SIG{QUIT} = $sig_handler;

	require URPM::Resolve;
	#- auto select package for upgrading the distribution.
	$options{auto_select} and $urpm->request_packages_to_upgrade($db, $state, $requested, requested => undef);

	$urpm->resolve_requested($db, $state, $requested, %options);
    }
}

#- get out of package that should not be upgraded.
sub deselect_unwanted_packages {
    my ($urpm, $packages, %options) = @_;
    my (%skip, %remove);

    local ($_, *F);
    open F, $urpm->{skiplist};
    while (<F>) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	if (my ($n, $s) = /^([^\s\[]+)(?:\[\*\])?\[?\s*([^\s\]]*\s*[^\s\]]*)/) {
 	    $skip{$n}{$s} = undef;
	}
    }
    close F;

    %skip or return;
    foreach (grep { $options{force} || (exists $packages->{$_} && ! defined $packages->{$_}) } keys %$packages) {
	my $pkg = $urpm->{depslist}[$_] or next;
	my $remove_it;

	#- check if fullname is matching a regexp.
	if (grep { exists $skip{$_}{''} && /^\/(.*)\/$/ && $pkg->fullname =~ /$1/ } keys %skip) {
	    delete $packages->{$pkg->id};
	} else {
	    #- check if a provides match at least one package.
	    foreach ($pkg->provides) {
		if (my ($n, $s) = /^([^\s\[]*)(?:\[\*\])?\[?([^\s\]]*\s*[^\s\]]*)/) {
		    foreach my $sn ($n, grep { /^\/(.*)\/$/ && $n =~ /$1/ } keys %skip) {
			foreach (keys %{$skip{$sn} || {}}) {
			    URPM::ranges_overlap($_, $s) and delete $packages->{$pkg->id};
			}
		    }
		}
	    }
	}
    }
    1;
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
	my $p = $urpm->{depslist}[$_];
	if ($urpm->{source}{$_}) {
	    $local_sources{$_} = $urpm->{source}{$_};
	} else {
	    $fullname2id{$p->fullname} = $_;
	}
    }

    #- examine each medium to search for packages.
    #- now get rpm file name in hdlist to match list file.
    foreach my $pkg (@{$urpm->{depslist} || []}) {
	$file2fullnames{($pkg->filename =~ /(.*)\.rpm$/ && $1) || $pkg->fullname}{$pkg->fullname} = undef;
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
		    $urpm->{error}(_("unable to correctly parse [%s] on value \"%s\"", "$urpm->{statedir}/$medium->{list}", $_));
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
    @{$urpm->{media} || []} == @$list or return;

    #- examine if given medium is already inside a removable device.
    my $check_notfound = sub {
	my ($id, $dir) = @_;
	$dir and $urpm->try_mounting($dir);
	if (!$dir || -e $dir) {
	    foreach (values %{$list->[$id]}) {
		/^(removable_?[^_:]*|file):\/(.*\/([^\/]*))/ or next;
		unless ($dir) {
		    $dir = $2;
		    $urpm->try_mounting($dir);
		}
		-r $2 or return 1;
	    }
	} else {
	    return 2;
	}
	return 0;
    };
    #- removable media have to be examined to keep mounted the one that has
    #- more package than other (size is better ?).
    my $examine_removable_medium = sub {
	my ($id, $device, $copy) = @_;
	my $medium = $urpm->{media}[$id];
	$media{$id} = undef;
	if (my ($prefix, $dir) = $medium->{url} =~ /^(removable[^:]*|file):\/(.*)/) {
	    #- the directory given does not exist or may be accessible
	    #- by mounting some other. try to figure out these directory and
	    #- mount everything necessary.
	    while ($check_notfound->($id, $dir)) {
		$ask_for_medium or $urpm->{fatal}(4, _("medium \"%s\" is not selected", $medium->{name}));
		$urpm->try_umounting($dir); system("eject", $device);
		$ask_for_medium->($medium->{name}, $medium->{removable}) or
		  $urpm->{fatal}(4, _("medium \"%s\" is not selected", $medium->{name}));
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
	#- needed package to copy first the needed rpm files.
	if (@{$removables{$device}} > 1) {
	    my @sorted_media = sort { values %{$list->[$a]} <=> values %{$list->[$b]} } @{$removables{$device}};

	    #- check if a removable device is already mounted (and files present).
	    if (my ($already_mounted_medium) = grep { !$check_notfound->($_) } @sorted_media) {
		@sorted_media = grep { $_ ne $already_mounted_medium } @sorted_media;
		unshift @sorted_media, $already_mounted_medium;
	    }

	    #- mount all except the biggest one.
	    foreach (@sorted_media[0 .. $#sorted_media-1]) {
		$examine_removable_medium->($_, $device, 'copy');
	    }
	    #- now mount the last one...
	    $removables{$device} = [ $sorted_media[-1] ];
	}

	#- mount the removable device, only one or the important one.
	#- if supermount is used on the device, it is preferable to copy
	#- the file instead (because it is so slooooow).
	$examine_removable_medium->($removables{$device}[0], $device, $urpm->is_using_supermount($device) && 'copy');
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
		if ($force_local || $1 ne 'ftp' && $1 ne 'http') { #- only ftp and http protocol supported.
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
	$urpm->{log}(_("retrieving rpm files..."));
	foreach (map { m|([^:]*://[^/:\@]*:)[^/:\@]*(\@.*)| ? "$1xxxx$2" : $_ } @distant_sources) {
	    $urpm->{log}("    $_") ;
	}
	$urpm->{sync}({dir => "$urpm->{cachedir}/rpms", quiet => 0, proxy => $urpm->{proxy}}, @distant_sources);
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
	foreach (keys %{$urpm->{provides}{$_} || {}}) {
	    my $pkg = $urpm->{depslist}[$_] or next;

	    #- some package with specific naming convention to avoid upgrade problem
	    #- should not be taken into account here.
	    #- these package have version=1 and release=1mdk, and name contains version and release.
	    $pkg->version eq '1' && $pkg->release eq '1mdk' && $pkg->name =~ /^.*-[^\-]*mdk$/ and next;

	    exists $sources->{$pkg->id} and $inst{$pkg->id} = delete $sources->{$pkg->id};
	}
    }
    close F;

    \%inst;
}

#- install logger (ala rpm)
sub install_logger {
    my ($urpm, $type, $id, $subtype, $amount, $total) = @_;
    my $pkg = defined $id && $urpm->{depslist}[$id];
    my $progress_size = 50;

    if ($subtype eq 'start') {
	$urpm->{logger_progress} = 0;
	if ($type eq 'trans') {
	    $urpm->{logger_id} = 0;
	    printf "%-28s", _("Preparing...");
	} else {
	    printf "%4d:%-23s", ++$urpm->{logger_id}, ($pkg && $pkg->name);
	}
    } elsif ($subtype eq 'stop') {
	if ($urpm->{logger_progress} < $progress_size) {
	    print '#' x ($progress_size - $urpm->{logger_progress});
	    print "\n";
	}
    } elsif ($subtype eq 'progress') {
	my $new_progress = $total > 0 ? int($progress_size * $amount / $total) : $progress_size;
	if ($new_progress > $urpm->{logger_progress}) {
	    print '#' x ($new_progress - $urpm->{logger_progress});
	    $urpm->{logger_progress} = $new_progress;
	    $urpm->{logger_progress} == $progress_size and print "\n";
	}
    }
}

#- install packages according to each hashes (install or upgrade).
sub install {
    my ($urpm, $remove, $install, $upgrade, %options) = @_;
    my $db = URPM::DB::open($urpm->{root}, !$options{test}); #- open in read/write mode unless testing installation.
    my $trans = $db->create_transaction($urpm->{root});
    my @l;
    local *F;

    foreach (@$remove) {
	$trans->remove($_) or $urpm->{error}(_("unable to remove package %s", $_));
    }
    foreach (keys %$install) {
	my $pkg = $urpm->{depslist}[$_];
	$pkg->update_header($install->{$_});
	$trans->add($pkg, 0) or $urpm->{error}(_("unable to install package %s", $install->{$_}));
    }
    foreach (keys %$upgrade) {
	my $pkg = $urpm->{depslist}[$_];
	$pkg->update_header($upgrade->{$_});
	$trans->add($pkg, 1) or $urpm->{error}(_("unable to install package %s", $upgrade->{$_}));
    }
    if (!$options{nodeps} and @l = $trans->check) {
	if ($options{translate_message}) {
	    foreach (@l) {
		my ($type, $needs, $conflicts) = split '@', $_;
		$_ = ($type eq 'requires' ?
		      _("%s is needed by %s", $needs, $conflicts) :
		      _("%s conflicts with %s", $needs, $conflicts));
	    }
	}
	return @l;
    }
    !$options{noorder} and @l = $trans->order and return @l;

    #- assume default value for some parameter.
    $options{delta} ||= 1000;
    $options{callback_open} ||= sub {
	my ($data, $type, $id) = @_;
	open F, $install->{$id} || $upgrade->{$id} or
	  $urpm->{error}(_("unable to access rpm file [%s]", $install->{$id} || $upgrade->{$id}));
	return fileno F;
    };
    $options{callback_close} ||= sub { close F };
    if (keys %$install || keys %$upgrade) {
	$options{callback_inst}  ||= \&install_logger;
	$options{callback_trans} ||= \&install_logger;
    }
    @l = $trans->run($urpm, %options);
}

#- install all files to node as remembered according to resolving done.
sub parallel_install {
    my ($urpm, $remove, $install, $upgrade, %options) = @_;
    $urpm->{parallel_handler}->parallel_install(@_);
}

1;
