package urpm;

use strict;
use vars qw($VERSION @ISA @EXPORT);

$VERSION = '4.4';
@ISA = qw(Exporter URPM);
@EXPORT = qw(*N);

use URPM;
use URPM::Resolve;
use POSIX;
use Locale::gettext();

#- I18N.
setlocale(LC_ALL, "");
Locale::gettext::textdomain("urpmi");

sub N {
    my ($format, @params) = @_;
    sprintf(Locale::gettext::gettext($format || ''), @params);
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
	   options    => {},

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
    if (defined $proxy->{proxy}{http_proxy} or defined $proxy->{proxy}{ftp_proxy}) {
	for ($proxy->{type}) {
	    /wget/ && do {
		for ($proxy->{proxy}) {
		    if (defined $_->{http_proxy}) {
			$ENV{http_proxy} = $_->{http_proxy} =~ /^http:/ ? $_->{http_proxy} : "http://$_->{http_proxy}";
		    }
		    $ENV{ftp_proxy} = $_->{ftp_proxy} if defined $_->{ftp_proxy};
		    @res = ("--proxy-user=$_->{user}", "--proxy-passwd=$_->{pwd}") if defined $_->{user} && defined $_->{pwd};
		}
		last;
	    };
	    /curl/ && do {
		for ($proxy->{proxy}) {
		    push @res, ('-x', $_->{http_proxy}) if defined $_->{http_proxy};
		    push @res, ('-x', $_->{ftp_proxy}) if defined $_->{ftp_proxy};
		    push @res, ('-U', "$_->{user}:$_->{pwd}") if defined $_->{user} && defined $_->{pwd};
		}
		last;
	    };
	    die N("Unknown webfetch `%s' !!!\n", $proxy->{type});
	}
    }
    return @res;
}

#- quoting/unquoting a string that may be containing space chars.
sub quotespace { local $_ = $_[0] || ''; s/(\s)/\\$1/g; $_ }
sub unquotespace { local $_ = $_[0] || ''; s/\\(\s)/$1/g; $_ }

#- syncing algorithms, currently is implemented wget and curl methods,
#- webfetch is trying to find the best (and one which will work :-)
sub sync_webfetch {
    my $options = shift @_;
    my %files;
    #- extract files according to protocol supported.
    #- currently ftp and http protocol are managed by curl or wget,
    #- ssh and rsync protocol are managed by rsync *AND* ssh.
    foreach (@_) {
	/^([^:_]*)[^:]*:/ or die N("unknown protocol defined for %s", $_);
	push @{$files{$1}}, $_;
    }
    if ($files{removable} || $files{file}) {
	sync_file($options, @{$files{removable} || []}, @{$files{file} || []});
	delete @files{qw(removable file)};
    }
    if ($files{ftp} || $files{http} || $files{https}) {
	if (-x "/usr/bin/curl" && (! ref($options) || $options->{prefer} ne 'wget' || ! -x "/usr/bin/wget")) {
	    sync_curl($options, @{$files{ftp} || []}, @{$files{http} || []}, @{$files{https} || []});
	} elsif (-x "/usr/bin/wget") {
	    sync_wget($options, @{$files{ftp} || []}, @{$files{http} || []}, @{$files{https} || []});
	} else {
	    die N("no webfetch (curl or wget currently) found\n");
	}
	delete @files{qw(ftp http https)};
    }
    if ($files{rsync}) {
	sync_rsync($options, @{$files{rsync} || []});
	delete $files{rsync};
    }
    if ($files{ssh}) {
	my @ssh_files;
	foreach (@{$files{ssh} || []}) {
	    /^ssh:\/\/([^\/]*)(.*)/ and push @ssh_files, "$1:$2";
	}
	sync_ssh($options, @ssh_files);
	delete $files{ssh};
    }
    %files and die N("unable to handle protocol: %s", join ', ', keys %files);
}
sub propagate_sync_callback {
    my $options = shift @_;
    if (ref($options) && $options->{callback}) {
	my $mode = shift @_;
	if ($mode =~ /^(start|progress|end)$/) {
	    my $file = shift @_;
	    $file =~ s|([^:]*://[^/:\@]*:)[^/:\@]*(\@.*)|$1xxxx$2|; #- if needed...
	    $options->{callback}($mode, $file, @_);
	} else {
	    $options->{callback}($mode, @_);
	}
    }
}
sub sync_file {
    my $options = shift @_;
    foreach (@_) {
	my ($in) = /^(?:removable[^:]*|file):\/(.*)/;
	propagate_sync_callback($options, 'start', $_);
	system("cp", "--preserve=mode", "--preserve=timestamps", "-R", $in || $_, ref($options) ? $options->{dir} : $options) or
	  die N("copy failed: %s", $@);
	propagate_sync_callback($options, 'end', $_);
    }
}
sub sync_wget {
    -x "/usr/bin/wget" or die N("wget is missing\n");
    local *WGET;
    my $options = shift @_;
    my ($buf, $total, $file) = ('', undef, undef);
    open WGET, join(" ", map { "'$_'" } "/usr/bin/wget",
		    (ref($options) && $options->{limit_rate} ? "--limit-rate=$options->{limit_rate}" : ()),
		    (ref($options) && $options->{proxy} ? set_proxy({ type => "wget", proxy => $options->{proxy} }) : ()),
		    (ref($options) && $options->{callback} ? ("--progress=bar:force", "-o", "-") :
		     ref($options) && $options->{quiet} ? "-q" : @{[]}),
		    "--retr-symlinks", "-NP",
		    (ref($options) ? $options->{dir} : $options), @_) . " |";
    local $/ = \1; #- read input by only one char, this is slow but very nice (and it works!).
    while (<WGET>) {
	$buf .= $_;
	if ($_ eq "\r" || $_ eq "\n") {
	    if (ref($options) && $options->{callback}) {
		if ($buf =~ /^--\d\d:\d\d:\d\d--\s+(\S.*)\n/ms) {
		    $file && $file ne $1 and propagate_sync_callback($options, 'end', $file);
		    ! defined $file and propagate_sync_callback($options, 'start', $file = $1);
		} elsif (defined $file && ! defined $total && $buf =~ /==>\s+RETR/) {
		    $total = '';
		} elsif (defined $total && $total eq '' && $buf =~ /^[^:]*:\s+(\d\S*)/) {
		    $total = $1;
		} elsif (my ($percent, $speed, $eta) = $buf =~ /^\s*(\d+)%.*\s+(\S+)\s+ETA\s+(\S+)\s*[\r\n]$/ms) {
		    propagate_sync_callback($options, 'progress', $file, $percent, $total, $eta, $speed);
		    if ($_ eq "\n") {
			propagate_sync_callback($options, 'end', $file);
			($total, $file) = (undef, undef);
		    }
		}
	    } else {
		ref($options) && $options->{quiet} or print STDERR $buf;
	    }
	    $buf = '';
	}
    }
    $file and propagate_sync_callback($options, 'end', $file);
    close WGET or die N("wget failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
}
sub sync_curl {
    -x "/usr/bin/curl" or die N("curl is missing\n");
    local *CURL;
    my $options = shift @_;
    my $cwd = `pwd`; chomp $cwd;
    chdir(ref($options) ? $options->{dir} : $options);
    my (@ftp_files, @other_files);
    foreach (@_) {
	/^ftp:\/\/.*\/([^\/]*)$/ && -s $1 > 8192 and do { push @ftp_files, $_; next }; #- manage time stamp for large file only.
	push @other_files, $_;
    }
    if (@ftp_files) {
	my ($cur_ftp_file, %ftp_files_info);

	eval { require Date::Manip };

	#- prepare to get back size and time stamp of each file.
	open CURL, join(" ", map { "'$_'" } "/usr/bin/curl",
			(ref($options) && $options->{limit_rate} ? ("--limit-rate", $options->{limit_rate}) : ()),
			(ref($options) && $options->{proxy} ? set_proxy({ type => "curl", proxy => $options->{proxy} }) : ()) .
			"--stderr", "-", "-s", "-I", @ftp_files) . " |";
	while (<CURL>) {
	    if (/Content-Length:\s*(\d+)/) {
		!$cur_ftp_file || exists($ftp_files_info{$cur_ftp_file}{size}) and $cur_ftp_file = shift @ftp_files;
		$ftp_files_info{$cur_ftp_file}{size} = $1;
	    }
	    if (/Last-Modified:\s*(.*)/) {
		!$cur_ftp_file || exists($ftp_files_info{$cur_ftp_file}{time}) and $cur_ftp_file = shift @ftp_files;
		eval {
		    $ftp_files_info{$cur_ftp_file}{time} = Date::Manip::ParseDate($1);
		    $ftp_files_info{$cur_ftp_file}{time} =~ s/(\d{6}).{4}(.*)/$1$2/; #- remove day and hour.
		};
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
		my $ltime = eval { Date::Manip::ParseDate(scalar gmtime((stat $1)[9])) };
		$ltime =~ s/(\d{6}).{4}(.*)/$1$2/; #- remove day and hour.
		-s $lfile == $ftp_files_info{$_}{size} && $ftp_files_info{$_}{time} eq $ltime or
		  push @ftp_files, $_;
	    }
	}
    }
    #- http files (and other files) are correctly managed by curl to conditionnal download.
    #- options for ftp files, -R (-O <file>)*
    #- options for http files, -R (-z file -O <file>)*
    if (my @all_files = ((map { ("-O", $_) } @ftp_files), (map { /\/([^\/]*)$/ ? ("-z", $1, "-O", $_) : @{[]} } @other_files))) {
	my @l = (@ftp_files, @other_files);
	my ($buf, $file) = ('', undef);
	open CURL, join(" ", map { "'$_'" } "/usr/bin/curl",
			(ref($options) && $options->{limit_rate} ? ("--limit-rate", $options->{limit_rate}) : ()),
			(ref($options) && $options->{proxy} ? set_proxy({ type => "curl", proxy => $options->{proxy} }) : ()),
			(ref($options) && $options->{quiet} && !$options->{verbose} ? "-s" : @{[]}),
			"-k", `curl -h` =~ /location-trusted/ ? "--location-trusted" : @{[]},
                        "-R", "-f", "--stderr", "-",
			@all_files) . " |";
	local $/ = \1; #- read input by only one char, this is slow but very nice (and it works!).
	while (<CURL>) {
	    $buf .= $_;
	    if ($_ eq "\r" || $_ eq "\n") {
		if (ref($options) && $options->{callback}) {
		    unless (defined $file) {
			$file = shift @l;
			propagate_sync_callback($options, 'start', $file);
		    }
		    if (my ($percent, $total, $eta, $speed) = $buf =~ /^\s*(\d+)\s+(\S+)[^\r\n]*\s+(\S+)\s+(\S+)[\r\n]$/ms) {
			propagate_sync_callback($options, 'progress', $file, $percent, $total, $eta, $speed);
			if ($_ eq "\n") {
			    propagate_sync_callback($options, 'end', $file);
			    $file = undef;
			}
		    }
		} else {
		    ref($options) && $options->{quiet} or print STDERR $buf;
		}
		$buf = '';
	    }
	}
	chdir $cwd;
	close CURL or die N("curl failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
    } else {
	chdir $cwd;
    }
}
sub sync_rsync {
    -x "/usr/bin/rsync" or die N("rsync is missing\n");
    my $options = shift @_;
    my $limit_rate = ref($options) && $options->{limit_rate};
    for ($limit_rate) {
	/^(\d+)$/     and $limit_rate = $1/1024;
	/^(\d+)[kK]$/ and $limit_rate = $1;
	/^(\d+)[mM]$/ and $limit_rate = 1024*$1;
	/^(\d+)[gG]$/ and $limit_rate = 1024*1024*$1;
    }
    foreach (@_) {
	my $count = 10; #- retry count on error (if file exists).
	my $basename = /^.*\/([^\/]*)$/ && $1 || $_;
	my ($file) = /^rsync:\/\/(.*)/ or next;	$file =~ /::/ or $file = $_;
	propagate_sync_callback($options, 'start', $file);
	do {
	    local (*RSYNC, $_);
	    my $buf = '';
	    open RSYNC, join(" ", map { "'$_'" } "/usr/bin/rsync",
			     ($limit_rate ? "--bwlimit=$limit_rate" : ()),
			     (ref($options) && $options->{quiet} ? qw(-q) : qw(--progress -v)),
			     qw(--partial --no-whole-file), $file, (ref($options) ? $options->{dir} : $options)) . " |";
	    local $/ = \1; #- read input by only one char, this is slow but very nice (and it works!).
	    while (<RSYNC>) {
		$buf .= $_;
		if ($_ eq "\r" || $_ eq "\n") {
		    if (ref($options) && $options->{callback}) {
			if (my ($percent, $speed) = $buf =~ /^\s*\d+\s+(\d+)%\s+(\S+)\s+/) {
			    propagate_sync_callback($options, 'progress', $file, $percent, undef, undef, $speed);
			}
		    } else {
			ref($options) && $options->{quiet} or print STDERR $buf;
		    }
		    $buf = '';
		}
	    }
	    close RSYNC;
	} while ($? != 0 && --$count > 0 && -e (ref($options) ? $options->{dir} : $options) . "/$basename");
	propagate_sync_callback($options, 'end', $file);
    }
    $? == 0 or die N("rsync failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
}
sub sync_ssh {
    -x "/usr/bin/rsync" or die N("rsync is missing\n");
    -x "/usr/bin/ssh" or die N("ssh is missing\n");
    my $options = shift @_;
    my $limit_rate = ref($options) && $options->{limit_rate};
    for ($limit_rate) {
	/^(\d+)$/     and $limit_rate = $1/1024;
	/^(\d+)[kK]$/ and $limit_rate = $1;
	/^(\d+)[mM]$/ and $limit_rate = 1024*$1;
	/^(\d+)[gG]$/ and $limit_rate = 1024*1024*$1;
    }
    foreach my $file (@_) {
	my $count = 10; #- retry count on error (if file exists).
	my $basename = $file =~ /^.*\/([^\/]*)$/ && $1 || $file;
	propagate_sync_callback($options, 'start', $file);
	do {
	    local (*RSYNC, $_);
	    my $buf = '';
	    open RSYNC, join(" ", map { "'$_'" } "/usr/bin/rsync",
			     ($limit_rate ? "--bwlimit=$limit_rate" : ()),
			     (ref($options) && $options->{quiet} ? qw(-q) : qw(--progress -v)),
			     qw(--partial -e ssh), $file, (ref($options) ? $options->{dir} : $options)) . " |";
	    local $/ = \1; #- read input by only one char, this is slow but very nice (and it works!).
	    while (<RSYNC>) {
		$buf .= $_;
		if ($_ eq "\r" || $_ eq "\n") {
		    if (ref($options) && $options->{callback}) {
			if (my ($percent, $speed) = $buf =~ /^\s*\d+\s+(\d+)%\s+(\S+)\s+/) {
			    propagate_sync_callback($options, 'progress', $file, $percent, undef, undef, $speed);
			}
		    } else {
			ref($options) && $options->{quiet} or print STDERR $buf;
		    }
		    $buf = '';
		}
	    }
	    close RSYNC;
	} while ($? != 0 && --$count > 0 && -e (ref($options) ? $options->{dir} : $options) . "/$basename");
	propagate_sync_callback($options, 'end', $file);
    }
    $? == 0 or die N("rsync failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
}
#- default logger suitable for sync operation on STDERR only.
sub sync_logger {
    my ($mode, $file, $percent, $total, $eta, $speed) = @_;
    if ($mode eq 'start') {
	print STDERR "    $file\n";
    } elsif ($mode eq 'progress') {
	if (defined $total && defined $eta) {
	    print STDERR N("        %s%% of %s completed, ETA = %s, speed = %s", $percent, $total, $eta, $speed) . "\r";
	} else {
	    print STDERR N("        %s%% completed, speed = %s", $percent, $speed) . "\r";
	}
    } elsif ($mode eq 'end') {
	print STDERR " " x 79, "\r";
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
	$_ eq '{' and do { #- urpmi.cfg global options extension
	    while (<F>) {
		chomp; s/#.*$//; s/^\s*//; s/\s*$//;
		$_ eq '}' and last;
		#- check for boolean variables first, and after that valued variables.
		my ($no, $k, $v);
		if (($no, $k, $v) = /^(no-)?(verify-rpm|fuzzy|allow-(?:force|nodeps)|(?:pre|post)-clean|excludedocs)(?:\s*:\s*(.*))?$/) {
		    unless (exists($urpm->{options}{$k})) {
			$urpm->{options}{$k} = $v eq '' || $v =~ /^(yes|on|1)$/i || 0;
			$no and $urpm->{options}{$k} = ! $urpm->{options}{$k} || 0;
		    }
		    next;
		} elsif (($k, $v) = /^(limit-rate|excludepath|key[\-_]ids|split-(?:level|length))\s*:\s*(.*)$/) {
		    unless (exists($urpm->{options}{$k})) {
			$v =~ /^'([^']*)'$/ and $v = $1; $v =~ /^"([^"]*)"$/ and $v = $1;
			$urpm->{options}{$k} = $v;
		    }
		    next;
		}
		$_ and $urpm->{error}(N("syntax error in config file at line %s", $.));
	    }
	    exists $urpm->{options}{key_ids} && ! exists $urpm->{options}{'key-ids'} and
	      $urpm->{options}{'key-ids'} = delete $urpm->{options}{key_ids};
	    next };
	/^(.*?[^\\])\s+(?:(.*?[^\\])\s+)?{$/ and do { #- urpmi.cfg format extention
	    my $medium = { name => unquotespace($1), clear_url => unquotespace($2) };
	    while (<F>) {
		chomp; s/#.*$//; s/^\s*//; s/\s*$//;
		$_ eq '}' and last;
		/^(hdlist|list|with_hdlist|removable|md5sum|key[\-_]ids)\s*:\s*(.*)$/ and $medium->{$1} = $2, next;
		/^(update|ignore|synthesis|virtual)\s*$/ and $medium->{$1} = 1, next;
		/^modified\s*$/ and next;
		$_ and $urpm->{error}(N("syntax error in config file at line %s", $.));
	    }
	    exists $medium->{key_ids} && ! exists $medium->{'key-ids'} and $medium->{'key-ids'} = delete $medium->{key_ids};
	    $urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
	    next };
	/^(.*?[^\\])\s+(.*?[^\\])\s+with\s+(.*)$/ and do { #- urpmi.cfg old format for ftp
	    my $medium = { name => unquotespace($1), clear_url => unquotespace($2), with_hdlist => unquotespace($3) };
	    $urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
	    next };
	/^(.*?[^\\])\s+(?:(.*?[^\\])\s*)?$/ and do { #- urpmi.cfg old format (assume hdlist.<name>.cz2?)
	    my $medium = { name => unquotespace($1), clear_url => unquotespace($2) };
	    $urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
	    next };
	$_ and $urpm->{error}(N("syntax error in config file at line %s", $.));
    }
    close F;

    #- keep in mind when an hdlist/list file is used, really usefull for
    #- the next probe.
    my (%hdlists, %lists);
    foreach (@{$urpm->{media}}) {
	if ($_->{hdlist}) {
	    exists($hdlists{$_->{hdlist}}) and
	      $_->{ignore} = 1,
		$urpm->{error}(N("medium \"%s\" trying to use an already used hdlist, medium ignored", $_->{name}));
	    $hdlists{$_->{hdlist}} = undef;
	}
	if ($_->{list}) {
	    exists($lists{$_->{list}}) and
	      $_->{ignore} = 1,
		$urpm->{error}(N("medium \"%s\" trying to use an already used list, medium ignored", $_->{name}));
	    $lists{$_->{list}} = undef;
	}
    }

    #- urpmi.cfg if old is not enough to known the various media, track
    #- directly into /var/lib/urpmi,
    foreach (glob("$urpm->{statedir}/hdlist.*")) {
	if (/\/hdlist\.((.*)\.cz2?)$/) {
	    #- check if it has already been detected above.
	    exists($hdlists{"hdlist.$1"}) and next;

	    #- if not this is a new media to take care if
	    #- there is a list file.
	    if (-s "$urpm->{statedir}/list.$2") {
		if (exists($lists{"list.$2"})) {
		    $urpm->{error}(N("unable to take care of medium \"%s\" as list file is already used by another medium", $2));
		} else {
		    my $medium;
		    foreach (@{$urpm->{media}}) {
			$_->{name} eq $2 and $medium = $_, last;
		    }
		    $medium and $urpm->{error}(N("unable to use name \"%s\" for unnamed medium because it is already used",
						 $2)), next;

		    $medium = { name => $2, hdlist => "hdlist.$1", list => "list.$2" };
		    $urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
		}
	    } else {
		$urpm->{error}(N("unable to take medium \"%s\" into account as no list file [%s] exists",
				 $2, "$urpm->{statedir}/list.$2"));
	    }
	} else {
	    $urpm->{error}(N("unable to determine medium of this hdlist file [%s]", $_));
	}
    }

    #- check the presence of hdlist file and list file if necessary.
    unless ($options{nocheck_access}) {
	foreach (@{$urpm->{media}}) {
	    $_->{ignore} and next;
	    -r "$urpm->{statedir}/$_->{hdlist}" || -r "$urpm->{statedir}/synthesis.$_->{hdlist}" && $_->{synthesis} or
	      $_->{ignore} = 1, $urpm->{error}(N("unable to access hdlist file of \"%s\", medium ignored", $_->{name}));
	    $_->{list} && -r "$urpm->{statedir}/$_->{list}" || defined $_->{url} or
	      $_->{ignore} = 1, $urpm->{error}(N("unable to access list file of \"%s\", medium ignored", $_->{name}));
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
    $existing_medium and $urpm->{error}(N("trying to bypass existing medium \"%s\", avoiding", $medium->{name})), return;
    
    $medium->{url} ||= $medium->{clear_url};

    if ($medium->{virtual}) {
	#- a virtual medium need to have an url available without using a list file.
	if ($medium->{hdlist} || $medium->{list}) {
	    $medium->{ignore} = 1;
	    $urpm->{error}(N("virtual medium \"%s\" should not have defined hdlist or list file, medium ignored",
			     $medium->{name}));
	}
	unless ($medium->{url}) {
	    $medium->{ignore} = 1;
	    $urpm->{error}(N("virtual medium \"%s\" should have a clear url, medium ignored",
			     $medium->{name}));
	}
    } else {
	unless ($medium->{ignore} || $medium->{hdlist}) {
	    $medium->{hdlist} = "hdlist.$medium->{name}.cz";
	    -e "$urpm->{statedir}/$medium->{hdlist}" or $medium->{hdlist} = "hdlist.$medium->{name}.cz2";
	    -e "$urpm->{statedir}/$medium->{hdlist}" or
	      $medium->{ignore} = 1,
		$urpm->{error}(N("unable to find hdlist file for \"%s\", medium ignored", $medium->{name}));
	}
	unless ($medium->{ignore} || $medium->{list}) {
	    unless (defined $medium->{url}) {
		$medium->{list} = "list.$medium->{name}";
		unless (-e "$urpm->{statedir}/$medium->{list}") {
		    $medium->{ignore} = 1,
		      $urpm->{error}(N("unable to find list file for \"%s\", medium ignored", $medium->{name}));
		}
	    }
	}

	#- there is a little more to do at this point as url is not known, inspect directly list file for it.
	unless ($medium->{url}) {
	    my %probe;
	    if (-r "$urpm->{statedir}/$medium->{list}") {
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
	    }
	    foreach (sort { length($a) <=> length($b) } keys %probe) {
		if ($medium->{url}) {
		    $medium->{url} eq substr($_, 0, length($medium->{url})) or
		      $medium->{ignore} || $urpm->{error}(N("incoherent list file for \"%s\", medium ignored", $medium->{name})),
			$medium->{ignore} = 1, last;
		} else {
		    $medium->{url} = $_;
		}
	    }
	    unless ($options{nocheck_access}) {
		$medium->{url} or
		  $medium->{ignore} || $urpm->{error}(N("unable to inspect list file for \"%s\", medium ignored",
							$medium->{name})),
							  $medium->{ignore} = 1;
	    }
	}
    }

    #- probe removable device.
    $urpm->probe_removable_device($medium);

    #- clear URLs for trailing /es.
    $medium->{url} and $medium->{url} =~ s|(.*?)/*$|$1|;
    $medium->{clear_url} and $medium->{clear_url} =~ s|(.*?)/*$|$1|;

    $medium;
}

#- probe device associated with a removable device.
sub probe_removable_device {
    my ($urpm, $medium) = @_;

    if ($medium->{url} && $medium->{url} =~ /^removable_?([^_:]*)(?:_[^:]*)?:/) {
	$medium->{removable} ||= $1 && "/dev/$1";
    } else {
	delete $medium->{removable};
    }

    #- try to find device to open/close for removable medium.
    if (exists($medium->{removable})) {
	if (my ($dir) = $medium->{url} =~ /(?:file|removable)[^:]*:\/(.*)/) {
	    my %infos;
	    my @mntpoints = $urpm->find_mntpoints($dir, \%infos);
	    if (@mntpoints > 1) { #- return value is suitable for an hash.
		$urpm->{log}(N("too many mount points for removable medium \"%s\"", $medium->{name}));
		$urpm->{log}(N("taking removable device as \"%s\"", join ',', map { $infos{$_}{device} } @mntpoints));
	    }
	    if (@mntpoints) {
		if ($medium->{removable} && $medium->{removable} ne $infos{$mntpoints[-1]}{device}) {
		    $urpm->{log}(N("using different removable device [%s] for \"%s\"",
				   $infos{$mntpoints[-1]}{device}, $medium->{name}));
		}
		$medium->{removable} = $infos{$mntpoints[-1]}{device};
	    } else {
		$urpm->{error}(N("unable to retrieve pathname for removable medium \"%s\"", $medium->{name}));
	    }
	} else {
	    $urpm->{error}(N("unable to retrieve pathname for removable medium \"%s\"", $medium->{name}));
	}
    }
}

#- write back urpmi.cfg code to allow modification of medium listed.
sub write_config {
    my ($urpm) = @_;

    #- avoid trashing exiting configuration in this case.
    $urpm->{media} or return;

    local *F;
    open F, ">$urpm->{config}" or $urpm->{fatal}(6, N("unable to write config file [%s]", $urpm->{config}));
    if (%{$urpm->{options} || {}}) {
	printf F "{\n";
	while (my ($k, $v) = each %{$urpm->{options}}) {
	    printf F "  %s: %s\n", $k, $v;
	}
	printf F "}\n\n";
    }
    foreach my $medium (@{$urpm->{media}}) {
	printf F "%s %s {\n", quotespace($medium->{name}), quotespace($medium->{clear_url});
	foreach (qw(hdlist with_hdlist list removable md5sum key-ids)) {
	    $medium->{$_} and printf F "  %s: %s\n", $_, $medium->{$_};
	}
	foreach (qw(update ignore synthesis modified virtual)) {
	    $medium->{$_} and printf F "  %s\n", $_;
	}
	printf F "}\n\n";
    }
    close F;
    $urpm->{log}(N("write config file [%s]", $urpm->{config}));

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
	    /\s*([^:]*):(.*)/ or $urpm->{error}(N("unable to parse \"%s\" in file [%s]", $_, "/etc/urpmi/parallel.cfg")), next;
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
		    $urpm->{log}->(N("examining parallel handler in file [%s]", "$dir/$_"));
		    eval { require "$dir/$_"; $parallel_handler = $urpm->handle_parallel_options($parallel_options) };
		    $parallel_handler and last;
		}
		closedir DIR;
		$parallel_handler and last;
	    }
	}
	if ($parallel_handler) {
	    if ($parallel_handler->{nodes}) {
		$urpm->{log}->(N("found parallel handler for nodes: %s", join(', ', keys %{$parallel_handler->{nodes}})));
	    }
	    if (!$options{media} && $parallel_handler->{media}) {
		$options{media} = $parallel_handler->{media};
		$urpm->{log}->(N("using associated media for parallel mode: %s", $options{media}));
	    }
	    $urpm->{parallel_handler} = $parallel_handler;
	} else {
	    $urpm->{fatal}(1, N("unable to use parallel option \"%s\"", $options{parallel}));
	}
    } else {
	#- parallel is exclusive against root options.
	$urpm->{root} = $options{root};
    }

    if ($options{synthesis}) {
	if ($options{synthesis} ne 'none') {
	    #- synthesis take precedence over media, update options.
	    $options{media} || $options{excludemedia} || $options{sortmedia} || $options{update} || $options{parallel} and
	      $urpm->{fatal}(1, N("--synthesis cannot be used with --media, --excludemedia, --sortmedia, --update or --parallel"));
	    $urpm->parse_synthesis($options{synthesis});
	    #- synthesis disable the split of transaction (too risky and not usefull).
	    $urpm->{options}{'split-length'} = 0;
	}
    } else {
	$urpm->read_config(%options);
	if ($options{media}) {
	    delete $_->{modified} foreach @{$urpm->{media} || []};
	    $urpm->select_media(split ',', $options{media});
	    foreach (grep { !$_->{modified} } @{$urpm->{media} || []}) {
		#- this is only a local ignore that will not be saved.
		$_->{ignore} = 1;
	    }
	}
	if ($options{excludemedia}) {
	    delete $_->{modified} foreach @{$urpm->{media} || []};
	    $urpm->select_media(split ',', $options{excludemedia});
	    foreach (grep { $_->{modified} } @{$urpm->{media} || []}) {
		#- this is only a local ignore that will not be saved.
		$_->{ignore} = 1;
	    }
	}
	if ($options{sortmedia}) {
	    delete $_->{modified} foreach @{$urpm->{media} || []};
	    my @oldmedia = @{$urpm->{media} || []};
	    my @newmedia;
	    foreach (split ',', $options{sortmedia}) {
		$urpm->select_media($_);
		push @newmedia, grep { $_->{modified} } @oldmedia;
		@oldmedia = grep { !$_->{modified} } @oldmedia;
	    }
	    #- anything not selected should be added as is after the selected one.
	    $urpm->{media} = [ @newmedia, @oldmedia ];
	    #- clean remaining modified flag.
	    delete $_->{modified} foreach @{$urpm->{media} || []};
	}
	unless ($options{nodepslist}) {
	    foreach (grep { !$_->{ignore} && (!$options{update} || $_->{update}) } @{$urpm->{media} || []}) {
		delete @{$_}{qw(start end)};
		if ($_->{virtual}) {
		    my $path = $_->{url} =~ /^file:\/*(\/[^\/].*[^\/])\/*$/ && $1;
		    if ($path) {
			if ($_->{synthesis}) {
			    $urpm->{log}(N("examining synthesis file [%s]", "$path/$_->{with_hdlist}"));
			    eval { ($_->{start}, $_->{end}) = $urpm->parse_synthesis("$path/$_->{with_hdlist}",
										     callback => $options{callback}) };
			} else {
			    $urpm->{log}(N("examining hdlist file [%s]", "$path/$_->{with_hdlist}"));
			    eval { ($_->{start}, $_->{end}) = $urpm->parse_hdlist("$path/$_->{with_hdlist}",
										  packing => 1, callback => $options{callback}) };
			}
		    } else {
			$urpm->{error}(N("virtual medium \"%s\" is not local, medium ignored", $_->{name}));
			$_->{ignore} = 1;
		    }
		} else {
		    if ($options{hdlist} && -s "$urpm->{statedir}/$_->{hdlist}" > 32) {
			$urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$_->{hdlist}"));
			eval { ($_->{start}, $_->{end}) = $urpm->parse_hdlist("$urpm->{statedir}/$_->{hdlist}",
									      packing => 1, callback => $options{callback}) };
		    } else {
			$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$_->{hdlist}"));
			eval { ($_->{start}, $_->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$_->{hdlist}",
										 callback => $options{callback}) };
			unless (defined $_->{start} && defined $_->{end}) {
			    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$_->{hdlist}"));
			    eval { ($_->{start}, $_->{end}) = $urpm->parse_hdlist("$urpm->{statedir}/$_->{hdlist}",
										  packing => 1, callback => $options{callback}) };
			}
		    }
		}
		unless ($_->{ignore}) {
		    unless (defined $_->{start} && defined $_->{end}) {
			$urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $_->{name}));
			$_->{ignore} = 1;
		    }
		}
	    }
	}
    }
    #- determine package to withdraw (from skip.list file) only if something should be withdrawn.
    unless ($options{noskipping}) {
	$urpm->compute_flags($urpm->get_packages_list($urpm->{skiplist}, $options{skip}), skip => 1, callback => sub {
				 my ($urpm, $pkg) = @_;
				 $urpm->{log}(N("skipping package %s", scalar($pkg->fullname)));
			     });
    }
    unless ($options{noinstalling}) {
	$urpm->compute_flags($urpm->get_packages_list($urpm->{instlist}, $options{inst}), disable_obsolete => 1, callback => sub {
				 my ($urpm, $pkg) = @_;
				 $urpm->{log}(N("would install instead of upgrade package %s", scalar($pkg->fullname)));
			     });
    }
    if ($options{bug}) {
	#- and a dump of rpmdb itself as synthesis file.
	my $db = URPM::DB::open($options{root});
	my $sig_handler = sub { undef $db; exit 3 };
	local $SIG{INT} = $sig_handler;
	local $SIG{QUIT} = $sig_handler;
	local *RPMDB;

	$db or $urpm->{fatal}(9, N("unable to open rpmdb"));
	open RPMDB, "| " . ($ENV{LD_LOADER} || '') . " gzip -9 >'$options{bug}/rpmdb.cz'";
	$db->traverse(sub {
			  my ($p) = @_;
			  #- this is not right but may be enough.
			  my $files = join '@', grep { exists($urpm->{provides}{$_}) } $p->files;
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
    if (defined $options{index_name}) {
	my $i = $options{index_name};
	do {
	    ++$i;
	    undef $medium;
	    foreach (@{$urpm->{media}}) {
		$_->{name} eq $name.$i and $medium = $_;
	    }
	} while $medium;
	$name .= $i;
    } else {
	foreach (@{$urpm->{media}}) {
	    $_->{name} eq $name and $medium = $_;
	}
    }
    $medium and $urpm->{fatal}(5, N("medium \"%s\" already exists", $medium->{name}));

    #- clear URLs for trailing /es.
    $url =~ s|(.*?)/*$|$1|;

    #- creating the medium info.
    if ($options{virtual}) {
	$url =~ m|^file:/*(/[^/].*)/| or $urpm->{fatal}(1, N("virtual medium need to be local"));

	$medium = { name      => $name,
		    url       => $url,
		    update    => $options{update},
		    virtual   => 1,
		    modified  => 1,
		  };
    } else {
	$medium = { name     => $name,
		    url      => $url,
		    hdlist   => "hdlist.$name.cz",
		    list     => "list.$name",
		    update   => $options{update},
		    modified => 1,
		  };

	#- check to see if the medium is using file protocol or removable medium.
	$url =~ /^(removable[^:]*|file):\/(.*)/ and $urpm->probe_removable_device($medium);
    }

    #- check if a password is visible, if not set clear_url.
    $url =~ m|([^:]*://[^/:\@]*:)[^/:\@]*(\@.*)| or $medium->{clear_url} = $url;

    #- all flags once everything has been computed.
    $with_hdlist and $medium->{with_hdlist} = $with_hdlist;

    #- create an entry in media list.
    push @{$urpm->{media}}, $medium;

    #- keep in mind the database has been modified and base files need to be updated.
    #- this will be done automatically by transfering modified flag from medium to global.
    $urpm->{log}(N("added medium %s", $name));
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

	$urpm->try_mounting($hdlists_file) or $urpm->{error}(N("unable to access first installation medium")), return;

	if (-e $hdlists_file) {
	    unlink "$urpm->{cachedir}/partial/hdlists";
	    $urpm->{log}(N("copying hdlists file..."));
	    system("cp", "--preserve=mode", "--preserve=timestamps", "-R", $hdlists_file, "$urpm->{cachedir}/partial/hdlists") ?
	      $urpm->{log}(N("...copying failed")) : $urpm->{log}(N("...copying done"));
	} else {
	    $urpm->{error}(N("unable to access first installation medium (no Mandrake/base/hdlists file found)")), return;
	}
    } else {
	#- try to get the description if it has been found.
	unlink "$urpm->{cachedir}/partial/hdlists";
	eval {
	    $urpm->{log}(N("retrieving hdlists file..."));
	    $urpm->{sync}({ dir => "$urpm->{cachedir}/partial",
			    quiet => 1,
			    limit_rate => $options{limit_rate},
			    proxy => $urpm->{proxy} },
			  reduce_pathname("$url/Mandrake/base/hdlists"));
	    $urpm->{log}(N("...retrieving done"));
	};
	$@ and $urpm->{log}(N("...retrieving failed: %s", $@));
	if (-e "$urpm->{cachedir}/partial/hdlists") {
	    $hdlists_file = "$urpm->{cachedir}/partial/hdlists";
	} else {
	    $urpm->{error}(N("unable to access first installation medium (no Mandrake/base/hdlists file found)")), return;
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
	    m/^\s*(?:noauto:)?(hdlist\S*\.cz2?)\s+(\S+)\s*(.*)$/ or $urpm->{error}(N("invalid hdlist description \"%s\" in hdlists file"), $_);
	    my ($hdlist, $rpmsdir, $descr) = ($1, $2, $3);

	    $urpm->add_medium($name ? "$descr ($name$medium)" : $descr, "$url/$rpmsdir", "../base/$hdlist", %options);

	    ++$medium;
	}
	close HDLISTS;
    } else {
	$urpm->{error}(N("unable to access first installation medium (no Mandrake/base/hdlists file found)")), return;
    }
}

sub select_media {
    my $urpm = shift;
    my %media; @media{@_} = undef;

    foreach (@{$urpm->{media}}) {
	if (exists($media{$_->{name}})) {
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
		$urpm->{error}(N("trying to select nonexistent medium \"%s\"", $_));
	    } else { #- multiple element in found or foundi list.
		$urpm->{log}(N("selecting multiple media: %s", join(", ", map { N("\"%s\"", $_->{name}) } (@found ? @found : @foundi))));
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
	    $urpm->{log}(N("removing medium \"%s\"", $_->{name}));

	    #- mark to re-write configuration.
	    $urpm->{modified} = 1;

	    #- remove file associated with this medium.
	    foreach ($_->{hdlist}, $_->{list}, "synthesis.$_->{hdlist}", "descriptions.$_->{name}", "$_->{name}.cache") {
		$_ and unlink "$urpm->{statedir}/$_";
	    }
	} else {
	    push @result, $_; #- not removed so keep it
	}
    }

    #- restore newer media list.
    $urpm->{media} = \@result;
}

#- return list of synthesis or hdlist reference to probe.
sub probe_with_try_list {
    my ($suffix, $probe_with) = @_;

    my @probe = ("synthesis.hdlist.cz", "synthesis.hdlist$suffix.cz",
		 "../synthesis.hdlist$suffix.cz", "../base/synthesis.hdlist$suffix.cz");

    defined $suffix && !$suffix and push @probe, ("synthesis.hdlist1.cz", "synthesis.hdlist2.cz",
						  "../synthesis.hdlist1.cz", "../synthesis.hdlist2.cz",
						  "../base/synthesis.hdlist1.cz", "../base/synthesis.hdlist2.cz");

    my @probe_hdlist = ("hdlist.cz", "hdlist$suffix.cz", "../hdlist$suffix.cz", "../base/hdlist$suffix.cz");
    defined $suffix && !$suffix and push @probe_hdlist, ("hdlist1.cz", "hdlist2.cz",
							 "../hdlist1.cz", "../hdlist2.cz",
							 "../base/hdlist1.cz", "../base/hdlist2.cz");

    if ($probe_with =~ /synthesis/) {
	push @probe, @probe_hdlist;
    } else {
	unshift @probe, @probe_hdlist;
    }

    @probe;
}

#- update urpmi database regarding the current configuration.
#- take care of modification and try some trick to bypass
#- computational of base files.
#- allow options :
#-   all         -> all medium are rebuilded.
#-   force       -> try to force rebuilding base files (1) or hdlist from rpm files (2).
#-   probe_with  -> probe synthesis or hdlist.
#-   ratio       -> use compression ratio (with gzip, default is 4)
#-   noclean     -> keep header directory cleaned.
sub update_media {
    my ($urpm, %options) = @_; #- do not trust existing hdlist and try to recompute them.
    my ($cleaned_cache);

    #- take care of some options.
    $cleaned_cache = !$options{noclean};

    #- avoid trashing existing configuration in this case.
    $urpm->{media} or return;

    #- now we need additional methods not defined by default in URPM.
    require URPM::Build;
    require URPM::Signature;

    $options{nolock} or $urpm->exlock_urpmi_db;

    #- get gpg-pubkey signature.
    $urpm->{keys} or $urpm->parse_pubkeys(root => $urpm->{root});

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
	    delete @{$medium}{qw(start end)};
	    if ($medium->{virtual}) {
		my ($path) = $medium->{url} =~ /^file:\/*(\/[^\/].*[^\/])\/*$/;
		my $with_hdlist_file = "$path/$medium->{with_hdlist}";
		if ($path) {
		    if ($medium->{synthesis}) {
			$urpm->{log}(N("examining synthesis file [%s]", $with_hdlist_file));
			eval { ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis($with_hdlist_file) };
		    } else {
			$urpm->{log}(N("examining hdlist file [%s]", $with_hdlist_file));
			eval { ($medium->{start}, $medium->{end}) = $urpm->parse_hdlist($with_hdlist_file, packing => 1) };
		    }
		} else {
		    $urpm->{error}(N("virtual medium \"%s\" is not local, medium ignored", $medium->{name}));
		    $_->{ignore} = 1;
		}
	    } else {
		$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
		eval { ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}") };
		unless (defined $medium->{start} && defined $medium->{end}) {
		    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
		    eval { ($medium->{start}, $medium->{end}) = $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1) };
		}
	    }
	    unless ($medium->{ignore}) {
		unless (defined $medium->{start} && defined $medium->{end}) {
		    #- this is almost a fatal error, ignore it by default?
		    $urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $medium->{name}));
		    $medium->{ignore} = 1;
		}
	    }
	    next;
	}

	#- list of rpm files for this medium, only available for local medium where
	#- the source hdlist is not used (use force).
	my ($prefix, $dir, $error, $retrieved_md5sum, @files);

	#- always delete a remaining list file or pubkey file in cache.
	foreach (qw(list pubkey)) {
	    unlink "$urpm->{cachedir}/partial/$_";
	}

	#- check to see if the medium is using file protocol or removable medium.
	if (($prefix, $dir) = $medium->{url} =~ /^(removable[^:]*|file):\/(.*)/) {
	    #- try to figure a possible hdlist_path (or parent directory of searched directory.
	    #- this is used to probe possible hdlist file.
	    my $with_hdlist_dir = reduce_pathname($dir . ($medium->{with_hdlist} ? "/$medium->{with_hdlist}" : "/.."));

	    #- the directory given does not exist and may be accessible
	    #- by mounting some other. try to figure out these directory and
	    #- mount everything necessary.
	    $urpm->try_mounting($options{force} < 2 && ($options{probe_with} || $medium->{with_hdlist}) ?
				$with_hdlist_dir : $dir) or
				  $urpm->{error}(N("unable to access medium \"%s\",
this could happen if you mounted manually the directory when creating the medium.", $medium->{name})), next;

	    #- try to probe for possible with_hdlist parameter, unless
	    #- it is already defined (and valid).
	    if ($options{probe_with} && (!$medium->{with_hdlist} || ! -e "$dir/$medium->{with_hdlist}")) {
		my ($suffix) = $dir =~ /RPMS([^\/]*)\/*$/;

		foreach (probe_with_try_list($suffix, $options{probe_with})) {
		    if (-s "$dir/$_" > 32) {
			$medium->{with_hdlist} = $_;
			last;
		    }
		}
		#- redo...
		$with_hdlist_dir = reduce_pathname($dir . ($medium->{with_hdlist} ? "/$medium->{with_hdlist}" : "/.."));
	    }

	    if ($medium->{virtual}) {
		#- syncing a virtual medium is very simple, just try to read the file in order to
		#- determine its type, once a with_hdlist has been found (but is mandatory).
		if ($medium->{with_hdlist} && -e $with_hdlist_dir) {
		    delete @{$medium}{qw(start end)};
		    if ($medium->{synthesis}) {
			$urpm->{log}(N("examining synthesis file [%s]", $with_hdlist_dir));
			eval { ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis($with_hdlist_dir);
			       delete $medium->{modified};
			       $medium->{synthesis} = 1;
			       $urpm->{modified} = 1 };
			unless (defined $medium->{start} && defined $medium->{end}) {
			    $urpm->{log}(N("examining hdlist file [%s]", $with_hdlist_dir));
			    eval { ($medium->{start}, $medium->{end}) = $urpm->parse_hdlist($with_hdlist_dir, packing => 1);
				   delete @{$medium}{qw(modified synthesis)};
				   $urpm->{modified} = 1 };
			}
		    } else {
			$urpm->{log}(N("examining hdlist file [%s]", $with_hdlist_dir));
			eval { ($medium->{start}, $medium->{end}) = $urpm->parse_hdlist($with_hdlist_dir, packing => 1);
			       delete @{$medium}{qw(modified synthesis)};
			       $urpm->{modified} = 1 };
			unless (defined $medium->{start} && defined $medium->{end}) {
			    $urpm->{log}(N("examining synthesis file [%s]", $with_hdlist_dir));
			    eval { ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis($with_hdlist_dir);
				   delete $medium->{modified};
				   $medium->{synthesis} = 1;
				   $urpm->{modified} = 1 };
			}
		    }
		    unless (defined $medium->{start} && defined $medium->{end}) {
			$urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $medium->{name}));
			$medium->{ignore} = 1;
		    }
		} else {
		    $urpm->{error}(N("virtual medium \"%s\" should have valid source hdlist or synthesis, medium ignored",
				     $medium->{name}));
		    $medium->{ignore} = 1;
		}
		next;
	    }
	    #- try to get the description if it has been found.
	    unlink "$urpm->{statedir}/descriptions.$medium->{name}";
	    if (-e "$dir/../descriptions") {
		$urpm->{log}(N("copying description file of \"%s\"...", $medium->{name}));
		system("cp", "--preserve=mode", "--preserve=timestamps", "-R", "$dir/../descriptions",
		       "$urpm->{statedir}/descriptions.$medium->{name}") ?
			 $urpm->{log}(N("...copying failed")) : $urpm->{log}(N("...copying done"));
	    }

	    #- examine if a distant MD5SUM file is available.
	    #- this will only be done if $with_hdlist is not empty in order to use
	    #- an existing hdlist or synthesis file, and to check if download was good.
	    #- if no MD5SUM are available, do it as before...
	    if ($medium->{with_hdlist}) {
		#- we can assume at this point a basename is existing, but it needs
		#- to be checked for being valid, nothing can be deduced if no MD5SUM
		#- file are present.
		my ($basename) = $with_hdlist_dir =~ /\/([^\/]+)$/;

		if (!$options{nomd5sum} && -s reduce_pathname("$dir/$with_hdlist_dir/../MD5SUM") > 32) {
		    if ($options{force}) {
			#- force downloading the file again, else why a force option has been defined ?
			delete $medium->{md5sum};
		    } else {
			unless ($medium->{md5sum}) {
			    $urpm->{log}(N("computing md5sum of existing source hdlist (or synthesis)"));
			    if ($medium->{synthesis}) {
				-e "$urpm->{statedir}/synthesis.$medium->{hdlist}" and
				  $medium->{md5sum} = (split ' ', `md5sum '$urpm->{statedir}/synthesis.$medium->{hdlist}'`)[0];
			    } else {
				-e "$urpm->{statedir}/$medium->{hdlist}" and
				  $medium->{md5sum} = (split ' ', `md5sum '$urpm->{statedir}/$medium->{hdlist}'`)[0];
			    }
			}
		    }
		    if ($medium->{md5sum}) {
			$urpm->{log}(N("examining MD5SUM file"));
			local (*F, $_);
			open F, reduce_pathname("$dir/$with_hdlist_dir/../MD5SUM");
			while (<F>) {
			    my ($md5sum, $file) = /(\S+)\s+(?:\.\/)?(\S+)/ or next;
			    #- keep md5sum got here to check download was ok ! so even if md5sum is not defined, we need
			    #- to compute it, keep it in mind ;)
			    $file eq $basename and $retrieved_md5sum = $md5sum;
			}
			close F;
			#- if an existing hdlist or synthesis file has the same md5sum, we assume the
			#- file are the same.
			#- if local md5sum is the same as distant md5sum, this means there is no need to
			#- download hdlist or synthesis file again.
			foreach (@{$urpm->{media}}) {
			    if ($_->{md5sum} && $_->{md5sum} eq $retrieved_md5sum) {
				unlink "$urpm->{cachedir}/partial/$basename";
				#- the medium is now considered not modified.
				$medium->{modified} = 0;
				#- hdlist or synthesis file must be linked with the other same one.
				#- a link is better for reducing used size of /var/lib/urpmi.
				if ($_ ne $medium) {
				    $medium->{md5sum} = $_->{md5sum};
				    unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
				    unlink "$urpm->{statedir}/$medium->{hdlist}";
				    symlink "synthesis.$_->{hdlist}", "synthesis.$medium->{hdlist}";
				    symlink $_->{hdlist}, $medium->{hdlist};
				}
				#- as previously done, just read synthesis file here, this is enough.
				$urpm->{log}(N("examining synthesis file [%s]",
					       "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
				eval { ($medium->{start}, $medium->{end}) =
					 $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}") };
				unless (defined $medium->{start} && defined $medium->{end}) {
				    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
				    eval { ($medium->{start}, $medium->{end}) =
					     $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1) };
				    unless (defined $medium->{start} && defined $medium->{end}) {
					$urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $medium->{name}));
					$medium->{ignore} = 1;
				    }
				}
				#- no need to continue examining other md5sum.
				last;
			    }
			}
			$medium->{modified} or next;
		    }
		}
	    }

	    #- if the source hdlist is present and we are not forcing using rpms file
	    if ($options{force} < 2 && $medium->{with_hdlist} && -e $with_hdlist_dir) {
		unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
		$urpm->{log}(N("copying source hdlist (or synthesis) of \"%s\"...", $medium->{name}));
		$options{callback} && $options{callback}('copy', $medium->{name});
		if (system("cp", "--preserve=mode", "--preserve=timestamps", "-R", $with_hdlist_dir,
			   "$urpm->{cachedir}/partial/$medium->{hdlist}")) {
		    $options{callback} && $options{callback}('failed', $medium->{name});
		    $urpm->{log}(N("...copying failed"));
		    unlink "$urpm->{cachedir}/partial/$medium->{hdlist}"; #- force error...
		} else {
		    $options{callback} && $options{callback}('done', $medium->{name});
		    $urpm->{log}(N("...copying done"));
		}

		-s "$urpm->{cachedir}/partial/$medium->{hdlist}" > 32 or
		  $error = 1, $urpm->{error}(N("copy of [%s] failed", $with_hdlist_dir));

		#- keep checking md5sum of file just copied ! (especially on nfs or removable device).
		if (!$error && $retrieved_md5sum) {
		    $urpm->{log}(N("computing md5sum of copied source hdlist (or synthesis)"));
		    (split ' ', `md5sum '$urpm->{cachedir}/partial/$medium->{hdlist}'`)[0] eq $retrieved_md5sum or
		      $error = 1, $urpm->{error}(N("copy of [%s] failed", $with_hdlist_dir));
		}

		#- check if the file are equals... and no force copy...
		if (!$error && !$options{force} && -e "$urpm->{statedir}/synthesis.$medium->{hdlist}") {
		    my @sstat = stat "$urpm->{cachedir}/partial/$medium->{hdlist}";
		    my @lstat = stat "$urpm->{statedir}/$medium->{hdlist}";
		    if ($sstat[7] == $lstat[7] && $sstat[9] == $lstat[9]) {
			#- the two files are considered equal here, the medium is so not modified.
			$medium->{modified} = 0;
			unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
			#- as previously done, just read synthesis file here, this is enough, but only
			#- if synthesis exists, else it need to be recomputed.
			$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
			eval { ($medium->{start}, $medium->{end}) =
				 $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}") };
			unless (defined $medium->{start} && defined $medium->{end}) {
			    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
			    eval { ($medium->{start}, $medium->{end}) =
				     $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1) };
			    unless (defined $medium->{start} && defined $medium->{end}) {
				$urpm->{error}(N("problem reading synthesis file of medium \"%s\"", $medium->{name}));
				$medium->{ignore} = 1;
			    }
			}
			next;
		    }
		}
	    } else {
		$options{force} < 2 and $options{force} = 2;
	    }

	    #- if copying hdlist has failed, try to build it directly.
	    if ($error) {
		$options{force} < 2 and $options{force} = 2;
		#- clean error state now.
		$error = undef;
	    }

	    if ($options{force} < 2) {
		#- examine if a local list file is available (always probed according to with_hdlist
		#- and check hdlist has not be named very strangely...
		if ($medium->{hdlist} ne 'list') {
		    my $local_list = $medium->{with_hdlist} =~ /hd(list.*)\.cz2?$/ ? $1 : 'list';
		    my $path_list = reduce_pathname("$dir/$with_hdlist_dir/../$local_list");
		    -s $path_list or $path_list = reduce_pathname("$dir/$with_hdlist_dir/../list");
		    -s $path_list or $path_list = "$dir/$local_list";
		    -s $path_list and system("cp", "--preserve=mode", "--preserve=timestamps", "-R",
					     $path_list, "$urpm->{cachedir}/partial/list");
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
			$urpm->{log}(N("reading rpm files from [%s]", $dir));
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
		    $@ and $error = 1, $urpm->{error}(N("unable to read rpm files from [%s]: %s", $dir, $@));
		    $error and delete $medium->{headers}; #- do not propagate these.
		    $error or delete $medium->{synthesis}; #- when building hdlist by ourself, drop synthesis property.
		} else {
		    $error = 1;
		    $urpm->{error}(N("no rpm files found from [%s]", $dir));
		}
	    }

	    #- examine if a local pubkey file is available.
	    if ($medium->{hdlist} ne 'pubkey' && !$medium->{'key-ids'}) {
		my $local_pubkey = $medium->{with_hdlist} =~ /hdlist(.*)\.cz2?$/ ? "pubkey$1" : 'pubkey';
		my $path_pubkey = reduce_pathname("$dir/$with_hdlist_dir/../$local_pubkey");
		-s $path_pubkey or $path_pubkey = reduce_pathname("$dir/$with_hdlist_dir/../pubkey");
		-s $path_pubkey or $path_pubkey = "$dir/$local_pubkey";
		-s $path_pubkey and system("cp", "--preserve=mode", "--preserve=timestamps", "-R",
					   $path_pubkey, "$urpm->{cachedir}/partial/pubkey");
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
		$urpm->{sync}({ dir => "$urpm->{cachedir}/partial",
				quiet => 1,
				limit_rate => $options{limit_rate},
				proxy => $urpm->{proxy} },
			      reduce_pathname("$medium->{url}/../descriptions"));
	    };
	    if (-e "$urpm->{cachedir}/partial/descriptions") {
		rename("$urpm->{cachedir}/partial/descriptions", "$urpm->{statedir}/descriptions.$medium->{name}") or
		  system("mv", "$urpm->{cachedir}/partial/descriptions", "$urpm->{statedir}/descriptions.$medium->{name}");
	    }

	    #- examine if a distant MD5SUM file is available.
	    #- this will only be done if $with_hdlist is not empty in order to use
	    #- an existing hdlist or synthesis file, and to check if download was good.
	    #- if no MD5SUM are available, do it as before...
	    if ($medium->{with_hdlist}) {
		#- we can assume at this point a basename is existing, but it needs
		#- to be checked for being valid, nothing can be deduced if no MD5SUM
		#- file are present.
		$basename = $medium->{with_hdlist} =~ /^.*\/([^\/]*)$/ && $1 || $medium->{with_hdlist};

		unlink "$urpm->{cachedir}/partial/MD5SUM";
		eval {
		    if (!$options{nomd5sum}) {
			$urpm->{sync}({ dir => "$urpm->{cachedir}/partial",
					quiet => 1,
					limit_rate => $options{limit_rate},
					proxy => $urpm->{proxy} },
				      reduce_pathname("$medium->{url}/$medium->{with_hdlist}/../MD5SUM"));
		    }
		};
		if (!$@ && -s "$urpm->{cachedir}/partial/MD5SUM" > 32) {
		    if ($options{force} >= 2) {
			#- force downloading the file again, else why a force option has been defined ?
			delete $medium->{md5sum};
		    } else {
			unless ($medium->{md5sum}) {
			    $urpm->{log}(N("computing md5sum of existing source hdlist (or synthesis)"));
			    if ($medium->{synthesis}) {
				-e "$urpm->{statedir}/synthesis.$medium->{hdlist}" and
				  $medium->{md5sum} = (split ' ', `md5sum '$urpm->{statedir}/synthesis.$medium->{hdlist}'`)[0];
			    } else {
				-e "$urpm->{statedir}/$medium->{hdlist}" and
				  $medium->{md5sum} = (split ' ', `md5sum '$urpm->{statedir}/$medium->{hdlist}'`)[0];
			    }
			}
		    }
		    if ($medium->{md5sum}) {
			$urpm->{log}(N("examining MD5SUM file"));
			local (*F, $_);
			open F, "$urpm->{cachedir}/partial/MD5SUM";
			while (<F>) {
			    my ($md5sum, $file) = /(\S+)\s+(?:\.\/)?(\S+)/ or next;
			    #- keep md5sum got here to check download was ok ! so even if md5sum is not defined, we need
			    #- to compute it, keep it in mind ;)
			    $file eq $basename and $retrieved_md5sum = $md5sum;
			}
			close F;
			#- if an existing hdlist or synthesis file has the same md5sum, we assume the
			#- file are the same.
			#- if local md5sum is the same as distant md5sum, this means there is no need to
			#- download hdlist or synthesis file again.
			foreach (@{$urpm->{media}}) {
			    if ($_->{md5sum} && $_->{md5sum} eq $retrieved_md5sum) {
				unlink "$urpm->{cachedir}/partial/$basename";
				#- the medium is now considered not modified.
				$medium->{modified} = 0;
				#- hdlist or synthesis file must be linked with the other same one.
				#- a link is better for reducing used size of /var/lib/urpmi.
				if ($_ ne $medium) {
				    $medium->{md5sum} = $_->{md5sum};
				    unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
				    unlink "$urpm->{statedir}/$medium->{hdlist}";
				    symlink "synthesis.$_->{hdlist}", "synthesis.$medium->{hdlist}";
				    symlink $_->{hdlist}, $medium->{hdlist};
				}
				#- as previously done, just read synthesis file here, this is enough.
				$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
				eval { ($medium->{start}, $medium->{end}) =
					 $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}") };
				unless (defined $medium->{start} && defined $medium->{end}) {
				    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
				    eval { ($medium->{start}, $medium->{end}) =
					     $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1) };
				    unless (defined $medium->{start} && defined $medium->{end}) {
					$urpm->{error}(N("problem reading synthesis file of medium \"%s\"", $medium->{name}));
					$medium->{ignore} = 1;
				    }
				}
				#- no need to continue examining other md5sum.
				last;
			    }
			}
			$medium->{modified} or next;
		    }
		} else {
		    #- at this point, we don't if a basename exists and is valid, let probe it later.
		    $basename = undef;
		}
	    }

	    #- try to probe for possible with_hdlist parameter, unless
	    #- it is already defined (and valid).
	    $urpm->{log}(N("retrieving source hdlist (or synthesis) of \"%s\"...", $medium->{name}));
	    $options{callback} && $options{callback}('retrieve', $medium->{name});
	    if ($options{probe_with}) {
		my ($suffix) = $dir =~ /RPMS([^\/]*)\/*$/;

		foreach my $with_hdlist ($medium->{with_hdlist}, probe_with_try_list($suffix, $options{probe_with})) {
		    $basename = $with_hdlist =~ /^.*\/([^\/]*)$/ && $1 || $with_hdlist or next;

		    $options{force} and unlink "$urpm->{cachedir}/partial/$basename";
		    eval {
			$urpm->{sync}({ dir => "$urpm->{cachedir}/partial",
					quiet => 0,
					limit_rate => $options{limit_rate},
					callback => $options{callback},
					proxy => $urpm->{proxy} }, reduce_pathname("$medium->{url}/$with_hdlist"));
		    };
		    if (!$@ && -s "$urpm->{cachedir}/partial/$basename" > 32) {
			$medium->{with_hdlist} = $with_hdlist;
			$urpm->{log}(N("found probed hdlist (or synthesis) as %s", $medium->{with_hdlist}));
			last; #- found a suitable with_hdlist in the list above.
		    }
		}
	    } else {
		$basename = $medium->{with_hdlist} =~ /^.*\/([^\/]*)$/ && $1 || $medium->{with_hdlist};

		#- try to sync (copy if needed) local copy after restored the previous one.
		$options{force} and unlink "$urpm->{cachedir}/partial/$basename";
		unless ($options{force}) {
		    if ($medium->{synthesis}) {
			-e "$urpm->{statedir}/synthesis.$medium->{hdlist}" and
			  system("cp", "--preserve=mode", "--preserve=timestamps", "-R",
				 "$urpm->{statedir}/synthesis.$medium->{hdlist}", "$urpm->{cachedir}/partial/$basename");
		    } else {
			-e "$urpm->{statedir}/$medium->{hdlist}" and
			  system("cp", "--preserve=mode", "--preserve=timestamps", "-R",
				 "$urpm->{statedir}/$medium->{hdlist}", "$urpm->{cachedir}/partial/$basename");
		    }
		}
		eval {
		    $urpm->{sync}({ dir => "$urpm->{cachedir}/partial",
				    quiet => 0,
				    limit_rate => $options{limit_rate},
				    callback => $options{callback},
				    proxy => $urpm->{proxy} }, reduce_pathname("$medium->{url}/$medium->{with_hdlist}"));
		};
		if ($@) {
		    $urpm->{log}(N("...retrieving failed: %s", $@));
		    unlink "$urpm->{cachedir}/partial/$basename";
		}
	    }

	    #- check downloaded file has right signature.
	    if (-s "$urpm->{cachedir}/partial/$basename" > 32 && $retrieved_md5sum) {
		$urpm->{log}(N("computing md5sum of retrieved source hdlist (or synthesis)"));
		unless ((split ' ', `md5sum '$urpm->{cachedir}/partial/$basename'`)[0] eq $retrieved_md5sum) {
		    $urpm->{log}(N("...retrieving failed: %s", N("md5sum mismatch")));
		    unlink "$urpm->{cachedir}/partial/$basename";
		}
	    }

	    if (-s "$urpm->{cachedir}/partial/$basename" > 32) {
		$options{callback} && $options{callback}('done', $medium->{name});
		$urpm->{log}(N("...retrieving done"));

		unless ($options{force}) {
		    my @sstat = stat "$urpm->{cachedir}/partial/$basename";
		    my @lstat = stat "$urpm->{statedir}/$medium->{hdlist}";
		    if ($sstat[7] == $lstat[7] && $sstat[9] == $lstat[9]) {
			#- the two files are considered equal here, the medium is so not modified.
			$medium->{modified} = 0;
			unlink "$urpm->{cachedir}/partial/$basename";
			#- as previously done, just read synthesis file here, this is enough.
			$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
			eval { ($medium->{start}, $medium->{end}) =
				 $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}") };
			unless (defined $medium->{start} && defined $medium->{end}) {
			    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
			    eval { ($medium->{start}, $medium->{end}) =
				     $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", packing => 1) };
			    unless (defined $medium->{start} && defined $medium->{end}) {
				$urpm->{error}(N("problem reading hdlist or synthesis file of medium \"%s\"", $medium->{name}));
				$medium->{ignore} = 1;
			    }
			}
			next;
		    }
		}

		#- the file are different, update local copy.
		rename("$urpm->{cachedir}/partial/$basename", "$urpm->{cachedir}/partial/$medium->{hdlist}");

		#- retrieve of hdlist or synthesis has been successfull, check if a list file is available.
		#- and check hdlist has not be named very strangely...
		if ($medium->{hdlist} ne 'list') {
		    my $local_list = $medium->{with_hdlist} =~ /hd(list.*)\.cz2?$/ ? $1 : 'list';
		    foreach (reduce_pathname("$medium->{url}/$medium->{with_hdlist}/../$local_list"),
			     reduce_pathname("$medium->{url}/$medium->{with_hdlist}/../list"),
			     reduce_pathname("$medium->{url}/$local_list"),
			    ) {
			eval {
			    $urpm->{sync}({ dir => "$urpm->{cachedir}/partial",
					    quiet => 1,
					    limit_rate => $options{limit_rate},
					    proxy => $urpm->{proxy} },
					  $_);
			    $local_list ne 'list' && -s "$urpm->{cachedir}/partial/$local_list" and
			      rename("$urpm->{cachedir}/partial/$local_list", "$urpm->{cachedir}/partial/list");
			};
			$@ and unlink "$urpm->{cachedir}/partial/list";
			-s "$urpm->{cachedir}/partial/list" and last;
		    }
		}

		#- retrieve pubkey file.
		if ($medium->{hdlist} ne 'pubkey' && !$medium->{'key-ids'}) {
		    my $local_pubkey = $medium->{with_hdlist} =~ /hdlist(.*)\.cz2?$/ ? "pubkey$1" : 'pubkey';
		    foreach (reduce_pathname("$medium->{url}/$medium->{with_hdlist}/../$local_pubkey"),
			     reduce_pathname("$medium->{url}/$medium->{with_hdlist}/../pubkey"),
			     reduce_pathname("$medium->{url}/$local_pubkey"),
			    ) {
			eval {
			    $urpm->{sync}({ dir => "$urpm->{cachedir}/partial",
					    quiet => 1,
					    limit_rate => $options{limit_rate},
					    proxy => $urpm->{proxy} },
					  $_);
			    $local_pubkey ne 'pubkey' && -s "$urpm->{cachedir}/partial/$local_pubkey" and
			      rename("$urpm->{cachedir}/partial/$local_pubkey", "$urpm->{cachedir}/partial/pubkey");
			};
			$@ and unlink "$urpm->{cachedir}/partial/pubkey";
			-s "$urpm->{cachedir}/partial/pubkey" and last;
		    }
		}
	    } else {
		$error = 1;
		$options{callback} && $options{callback}('failed', $medium->{name});
		$urpm->{error}(N("retrieve of source hdlist (or synthesis) failed"));
	    }
	}

	#- build list file according to hdlist used.
	unless ($medium->{headers} || -s "$urpm->{cachedir}/partial/$medium->{hdlist}" > 32) {
	    $error = 1;
	    $urpm->{error}(N("no hdlist file found for medium \"%s\"", $medium->{name}));
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
		    $list{$1} and $urpm->{error}(N("file [%s] already used in the same medium \"%s\"", $1, $medium->{name})), next;
		    $list{$1} = "$prefix:/$_\n";
		}
	    } else {
		#- read first pass hdlist or synthesis, try to open as synthesis, if file
		#- is larger than 1MB, this is probably an hdlist else a synthesis.
		#- anyway, if one tries fails, try another mode.
		$options{callback} && $options{callback}('parse', $medium->{name});
		my @unresolved_before = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};
		if (!$medium->{synthesis} || -s "$urpm->{cachedir}/partial/$medium->{hdlist}" > 262144) {
		    $urpm->{log}(N("examining hdlist file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
		    eval { ($medium->{start}, $medium->{end}) =
			     $urpm->parse_hdlist("$urpm->{cachedir}/partial/$medium->{hdlist}", 1) };
		    if (defined $medium->{start} && defined $medium->{end}) {
			delete $medium->{synthesis};
		    } else {
			$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
			eval { ($medium->{start}, $medium->{end}) =
				 $urpm->parse_synthesis("$urpm->{cachedir}/partial/$medium->{hdlist}") };
			defined $medium->{start} && defined $medium->{end} and $medium->{synthesis} = 1;
		    }
		} else {
		    $urpm->{log}(N("examining synthesis file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
		    eval { ($medium->{start}, $medium->{end}) =
			     $urpm->parse_synthesis("$urpm->{cachedir}/partial/$medium->{hdlist}") };
		    if (defined $medium->{start} && defined $medium->{end}) {
			$medium->{synthesis} = 1;
		    } else {
			$urpm->{log}(N("examining hdlist file [%s]", "$urpm->{cachedir}/partial/$medium->{hdlist}"));
			eval { ($medium->{start}, $medium->{end}) =
				 $urpm->parse_hdlist("$urpm->{cachedir}/partial/$medium->{hdlist}", 1) };
			defined $medium->{start} && defined $medium->{end} and delete $medium->{synthesis};
		    }
		}
		unless (defined $medium->{start} && defined $medium->{end}) {
		    $error = 1;
		    $urpm->{error}(N("unable to parse hdlist file of \"%s\"", $medium->{name}));
		    $options{callback} && $options{callback}('failed', $medium->{name});
		    #- we will have to read back the current synthesis file unmodified.
		} else {
		    $options{callback} && $options{callback}('done', $medium->{name});
		}

		unless ($error) {
		    my @unresolved_after = grep { ! defined $urpm->{provides}{$_} } keys %{$urpm->{provides} || {}};
		    @unresolved_before == @unresolved_after or $urpm->{second_pass} = 1;

		    if ($medium->{hdlist} ne 'list' && -s "$urpm->{cachedir}/partial/list") {
			local (*F, $_);
			open F, "$urpm->{cachedir}/partial/list";
			while (<F>) {
			    /\/([^\/]*\.rpm)$/ or next;
			    $list{$1} and $urpm->{error}(N("file [%s] already used in the same medium \"%s\"", $1, $medium->{name})), next;
			    $list{$1} = "$medium->{url}/$_";
			}
			close F;
		    } else {
			#- if url is clear and no relative list file has been downloaded,
			#- there is no need for a list file.
			if ($medium->{url} ne $medium->{clear_url}) {
			    foreach ($medium->{start} .. $medium->{end}) {
				my $filename = $urpm->{depslist}[$_]->filename;
				$list{$filename} = "$medium->{url}/$filename\n";
			    }
			}
		    }
		}
	    }

	    unless ($error) {
		if (%list) {
		    #- write list file.
		    local *LIST;
		    my $mask = umask 077;
		    open LIST, ">$urpm->{cachedir}/partial/$medium->{list}"
		      or $error = 1, $urpm->{error}(N("unable to write list file of \"%s\"", $medium->{name}));
		    umask $mask;
		    print LIST values %list;
		    close LIST;

		    #- check if at least something has been written into list file.
		    if (-s "$urpm->{cachedir}/partial/$medium->{list}") {
			$urpm->{log}(N("writing list file for medium \"%s\"", $medium->{name}));
		    } else {
			$error = 1, $urpm->{error}(N("nothing written in list file for \"%s\"", $medium->{name}));
		    }
		} else {
		    #- the flag is no more necessary.
		    delete $medium->{list};
		    unlink "$urpm->{statedir}/$medium->{list}";
		}
	    }
	}

	unless ($error) {
	    #- now... on pubkey
	    if (-s "$medium->{cachedir}/partial/pubkey") {
		$urpm->{log}(N("examining pubkey file of \"%s\"...", $medium->{name}));
		my (%keys, %unknown_keys);
		eval {
		    foreach ($urpm->parse_armored_file("$medium->{cachedir}/partial/pubkey")) {
			my $id;
			foreach my $kv (values %{$urpm->{keys} || {}}) {
			    $kv->{content} = $_->{content} and $keys{$id = $kv->{id}} = undef, last;
			}
			unless ($id) {
			    #- the key has not been found, this is important to import it now,
			    #- update keys hash (as we do not know how to get key id from its content).
			    #- and parse again to found the key.
			    $urpm->import_armored_file("$medium->{cachedir}/partial/pubkey", root => $urpm->{root});
			    $urpm->parse_pubkeys(root => $urpm->{root});

			    foreach my $kv (values %{$urpm->{keys} || {}}) {
				$kv->{content} = $_->{content} and $keys{$id = $kv->{id}} = undef, last;
			    }

			    #- now id should be defined, or there is a problem to import the keys...
			    $id or $urpm->{error}(N("unable to import pubkey file of \"%s\"", $medium->{name}));
			}
		    }
		};
		%keys and $medium->{'key-ids'} = join ',', keys %keys;
	    }
	}

	if ($error) {
	    #- an error has occured for updating the medium, we have to remove tempory files.
	    unlink "$urpm->{cachedir}/partial/$medium->{hdlist}";
	    $medium->{list} and unlink "$urpm->{cachedir}/partial/$medium->{list}";
	    #- read default synthesis (we have to make sure nothing get out of depslist).
	    $urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
	    eval { ($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}") };
	    unless (defined $medium->{start} && defined $medium->{end}) {
		$urpm->{error}(N("problem reading synthesis file of medium \"%s\"", $medium->{name}));
		$medium->{ignore} = 1;
	    }
	} else {
	    #- make sure to rebuild base files and clean medium modified state.
	    $medium->{modified} = 0;
	    $urpm->{modified} = 1;

	    #- but use newly created file.
	    unlink "$urpm->{statedir}/$medium->{hdlist}";
	    $medium->{synthesis} and unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
	    $medium->{list} and unlink "$urpm->{statedir}/$medium->{list}";
	    unless ($medium->{headers}) {
		unlink "$urpm->{statedir}/synthesis.$medium->{hdlist}";
		unlink "$urpm->{statedir}/$medium->{hdlist}";
		rename("$urpm->{cachedir}/partial/$medium->{hdlist}", $medium->{synthesis} ?
		       "$urpm->{statedir}/synthesis.$medium->{hdlist}" : "$urpm->{statedir}/$medium->{hdlist}") or
			 system("mv", "$urpm->{cachedir}/partial/$medium->{hdlist}", $medium->{synthesis} ?
				"$urpm->{statedir}/synthesis.$medium->{hdlist}" :
				"$urpm->{statedir}/$medium->{hdlist}");
	    }
	    if ($medium->{list}) {
		rename("$urpm->{cachedir}/partial/$medium->{list}", "$urpm->{statedir}/$medium->{list}") or
		  system("mv", "$urpm->{cachedir}/partial/$medium->{list}", "$urpm->{statedir}/$medium->{list}");
	    }
	    $medium->{md5sum} = $retrieved_md5sum; #- anyway, keep it, the previous one is no more usefull.

	    #- and create synthesis file associated.
	    $medium->{modified_synthesis} = !$medium->{synthesis};
	}
    }

    #- some unresolved provides may force to rebuild all synthesis,
    #- a second pass will be necessary.
    if ($urpm->{second_pass}) {
	$urpm->{log}(N("performing second pass to compute dependencies\n"));
	$urpm->unresolved_provides_clean;
    }

    #- second pass consist of reading again synthesis or hdlist.
    foreach my $medium (@{$urpm->{media}}) {
	#- take care of modified medium only or all if all have to be recomputed.
	$medium->{ignore} and next;

	$options{callback} && $options{callback}('parse', $medium->{name});
	#- a modified medium is an invalid medium, we have to read back the previous hdlist
	#- or synthesis which has not been modified by first pass above.
	if ($medium->{headers} && !$medium->{modified}) {
	    if ($urpm->{second_pass}) {
		$urpm->{log}(N("reading headers from medium \"%s\"", $medium->{name}));
		($medium->{start}, $medium->{end}) = $urpm->parse_headers(dir     => "$urpm->{cachedir}/headers",
									  headers => $medium->{headers},
									 );
	    }
	    $urpm->{log}(N("building hdlist [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
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
	    $urpm->{log}(N("built hdlist synthesis file for medium \"%s\"", $medium->{name}));
	    #- keep in mind we have modified database, sure at this point.
	    $urpm->{modified} = 1;
	} elsif ($medium->{synthesis}) {
	    if ($urpm->{second_pass}) {
		$urpm->{log}(N("examining synthesis file [%s]", "$urpm->{statedir}/synthesis.$medium->{hdlist}"));
		($medium->{start}, $medium->{end}) = $urpm->parse_synthesis("$urpm->{statedir}/synthesis.$medium->{hdlist}");
	    }
	} else {
	    if ($urpm->{second_pass}) {
		$urpm->{log}(N("examining hdlist file [%s]", "$urpm->{statedir}/$medium->{hdlist}"));
		($medium->{start}, $medium->{end}) = $urpm->parse_hdlist("$urpm->{statedir}/$medium->{hdlist}", 1);
	    }
	    #- check if synthesis file can be built.
	    if (($urpm->{second_pass} || $medium->{modified_synthesis}) && !$medium->{modified}) {
		unless ($medium->{virtual}) {
		    $urpm->build_synthesis(start     => $medium->{start},
					   end       => $medium->{end},
					   synthesis => "$urpm->{statedir}/synthesis.$medium->{hdlist}",
					  );
		    $urpm->{log}(N("built hdlist synthesis file for medium \"%s\"", $medium->{name}));
		}
		#- keep in mind we have modified database, sure at this point.
		$urpm->{modified} = 1;
	    }
	}
	$options{callback} && $options{callback}('done', $medium->{name});
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
	    $urpm->{log}(N("found %d headers in cache", scalar(keys %headers)));
	    foreach (@{$urpm->{depslist}}) {
		delete $headers{$_->fullname};
	    }
	    $urpm->{log}(N("removing %d obsolete headers in cache", scalar(keys %headers)));
	    foreach (values %headers) {
		unlink "$urpm->{cachedir}/headers/$_";
	    }
	}

	#- this file is written in any cases.
	$urpm->write_config();
    }

    $options{nolock} or $urpm->unlock_urpmi_db;
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
    my ($urpm, $dir, $infos) = @_;
    my ($pdir, $v, %fstab, @mntpoints);
    local (*F, $_);

    #- read /etc/fstab and check for existing mount point.
    open F, "/etc/fstab";
    while (<F>) {
	my ($device, $mntpoint, $fstype, $options) = /^\s*(\S+)\s+(\/\S+)\s+(\S+)\s+(\S+)/ or next;
	$mntpoint =~ s,/+,/,g; $mntpoint =~ s,/$,,;
	$fstab{$mntpoint} =  0;
	if (ref($infos)) {
	    if ($fstype eq 'supermount') {
		$options =~ /^(?:.*[\s,])?dev=([^\s,]+)/ and $infos->{$mntpoint} = { mounted => 0, device => $1, fs => $fstype,
										     supermount => 1, };
	    } else {
		$infos->{$mntpoint} = { mounted => 0, device => $device, fs => $fstype };
	    }
	}
    }
    open F, "/etc/mtab";
    while (<F>) {
	my ($device, $mntpoint, $fstype, $options) = /^\s*(\S+)\s+(\/\S+)\s+(\S+)\s+(\S+)/ or next;
	$mntpoint =~ s,/+,/,g; $mntpoint =~ s,/$,,;
	$fstab{$mntpoint} = 1;
	if (ref($infos)) {
	    if ($fstype eq 'supermount') {
		$options =~ /^(?:.*[\s,])?dev=([^\s,]+)/ and $infos->{$mntpoint} = { mounted => 1, device => $1, fs => $fstype,
										     supermount => 1, };
	    } else {
		$infos->{$mntpoint} = { mounted => 1, device => $device, fs => $fstype };
	    }
	}
    }
    close F;

    #- try to follow symlink, too complex symlink graph may not be seen.
    #- check the possible mount point.
    my @paths = split '/', $dir;
    while (defined ($_ = shift @paths)) {
	length($_) or next;
	$pdir .= "/$_";
	$pdir =~ s,/+,/,g; $pdir =~ s,/$,,;
	if (exists($fstab{$pdir})) {
	    ref($infos) and push @mntpoints, $pdir;
	    $infos eq 'mount' && ! $fstab{$pdir} and push @mntpoints, $pdir;
	    $infos eq 'umount' && $fstab{$pdir} and unshift @mntpoints, $pdir;
	    #- following symlinks may be dangerous for supermounted device and
	    #- unusefull.
	    #- this means it is assumed no symlink inside a removable device
	    #- will go outside the device itself (or at least will go into
	    #- regular already mounted device like /).
	    #- for simplification we refuse also any other device and
	    #- stop here.
	    last;
	} elsif (-l $pdir) {
	    while ($v = readlink $pdir) {
		if ($pdir =~ /^\//) {
		    $pdir = $v;
		} else {
		    while ($v =~ /^\.\.\/(.*)/) {
			$v = $1;
			$pdir =~ s/^(.*)\/[^\/]+\/*/$1/;
		    }
		    $pdir .= "/$v";
		}
	    }
	    unshift @paths, split '/', $pdir;
	    $pdir = '';
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
    my ($urpm, $dir, $removable) = @_;
    my %infos;

    $dir = reduce_pathname($dir);
    foreach (grep { ! $infos{$_}{mounted} && $infos{$_}{fs} ne 'supermount' } $urpm->find_mntpoints($dir, \%infos)) {
	$urpm->{log}(N("mounting %s", $_));
	`mount '$_' 2>/dev/null`;
	$removable && $infos{$_}{fs} ne 'supermount' and $urpm->{removable_mounted}{$_} = undef;
    }
    -e $dir;
}

sub try_umounting {
    my ($urpm, $dir) = @_;
    my %infos;

    $dir = reduce_pathname($dir);
    foreach (reverse grep { $infos{$_}{mounted} && $infos{$_}{fs} ne 'supermount' } $urpm->find_mntpoints($dir, \%infos)) {
	$urpm->{log}(N("unmounting %s", $_));
	`umount '$_' 2>/dev/null`;
	delete $urpm->{removable_mounted}{$_};
    }
    ! -e $dir;
}

sub try_umounting_removables {
    my ($urpm) = @_;
    foreach (keys %{$urpm->{removable_mounted}}) {
	$urpm->try_umounting($_);
    }
    delete $urpm->{removable_mounted};
}

#- relocate depslist array id to use only the most recent packages,
#- reorder info hashes to give only access to best packages.
sub relocate_depslist_provides {
    my ($urpm, %options) = @_;
    my $relocated_entries = $urpm->relocate_depslist;

    $urpm->{log}($relocated_entries ?
		 N("relocated %s entries in depslist", $relocated_entries) :
		 N("no entries relocated in depslist"));
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
	/\.rpm$/ or $error = 1, $urpm->{error}(N("invalid rpm file name [%s]", $_)), next;

	#- allow url to be given.
	if (my ($basename) = /^[^:]*:\/.*\/([^\/]*\.rpm)$/) {
	    unlink "$urpm->{cachedir}/partial/$basename";
	    eval {
		$urpm->{log}(N("retrieving rpm file [%s] ...", $_));
		$urpm->{sync}({ dir => "$urpm->{cachedir}/partial", quiet => 1, proxy => $urpm->{proxy} }, $_);
		$urpm->{log}(N("...retrieving done"));
		$_ = "$urpm->{cachedir}/partial/$basename";
	    };
	    $@ and $urpm->{log}(N("...retrieving failed: %s", $@));
	} else {
	    -r $_ or $error = 1, $urpm->{error}(N("unable to access rpm file [%s]", $_)), next;
	}

	($id, undef) = $urpm->parse_rpm($_);
	my $pkg = defined $id && $urpm->{depslist}[$id];
	$pkg or $urpm->{error}(N("unable to register rpm file")), next;
	$urpm->{source}{$id} = $_;
    }
    $error and $urpm->{fatal}(2, N("error registering local packages"));
    defined $id && $start <= $id and @requested{($start .. $id)} = (1) x ($id-$start+1);

    #- distribute local packages to distant nodes directly in cache of each machine.
    @files && $urpm->{parallel_handler} and $urpm->{parallel_handler}->parallel_register_rpms(@_);

    %requested;
}

#- search packages registered by their name by storing their id into packages hash.
sub search_packages {
    my ($urpm, $packages, $names, %options) = @_;
    my (%exact, %exact_a, %exact_ra, %found, %foundi);

    foreach my $v (@$names) {
	my $qv = quotemeta $v;

	unless ($options{fuzzy}) {
	    #- try to search through provides.
	    if (my @l = map { $_ && ($options{src} ? $_->arch eq 'src' : $_->is_arch_compat) &&
				($options{use_provides} || $_->name eq $v) && defined $_->id ?
				  ($_) : @{[]} } map { $urpm->{depslist}[$_] }
		keys %{$urpm->{provides}{$v} || {}}) {
		#- we assume that if the there is at least one package providing the resource exactly,
		#- this should be the best ones that is described.
		#- but we first check if one of the packages has the same name as searched.
		if (my @l2 = grep { $_->name eq $v} @l) {
		    $exact{$v} = join '|', map { $_->id } @l2;
		} else {
		    $exact{$v} = join '|', map { $_->id } @l;
		}
		next;
	    }
	}

	if ($options{use_provides} && $options{fuzzy}) {
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
	    foreach (split '\|', $exact{$_}) {
		my $pkg = $urpm->{depslist}[$_] or next;
		$pkg->set_flag_skip(0); #- reset skip flag as manually selected.
	    }
	} else {
	    #- at this level, we need to search the best package given for a given name,
	    #- always prefer already found package.
	    my %l;
	    foreach (@{$exact_a{$_} || $exact_ra{$_} || $found{$_} || $foundi{$_} || []}) {
		my $pkg = $urpm->{depslist}[$_];
		push @{$l{$pkg->name}}, $pkg;
	    }
	    if (values(%l) == 0) {
		$urpm->{error}(N("no package named %s", $_));
		$result = 0;
	    } elsif (values(%l) > 1 && !$options{all}) {
		$urpm->{error}(N("The following packages contain %s: %s", $_, "\n".join("\n", sort { $a cmp $b } keys %l)));
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
		    $best->set_flag_skip(0); #- reset skip flag as manually selected.
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

    if ($options{install_src}) {
	#- only src will be installed, so only update $state->{selected} according
	#- to src status of files.
	foreach (%$requested) {
	    my $pkg = $urpm->{depslist}[$_] or next;
	    $pkg->arch eq 'src' or next;
	    $state->{selected}{$_} = undef;
	}
    }
    if ($urpm->{parallel_handler}) {
	#- build the global synthesis file first.
	my $file = "$urpm->{cachedir}/partial/parallel.cz";
	unlink $file;
	foreach (@{$urpm->{media}}) {
	    defined $_->{start} && defined $_->{end} or next;
	    system "cat '$urpm->{statedir}/synthesis.$_->{hdlist}' >> $file";
	}
	#- let each node determine what is requested, according to handler given.
	$urpm->{parallel_handler}->parallel_resolve_dependencies($file, @_);
    } else {
	my $db;

	if ($options{rpmdb}) {
	    $db = new URPM;
	    $db->parse_synthesis($options{rpmdb});
	} else {
	    $db = URPM::DB::open($urpm->{root});
	    $db or $urpm->{fatal}(9, N("unable to open rpmdb"));
	}

	my $sig_handler = sub { undef $db; exit 3 };
	local $SIG{INT} = $sig_handler;
	local $SIG{QUIT} = $sig_handler;

	#- auto select package for upgrading the distribution.
	$options{auto_select} and $urpm->request_packages_to_upgrade($db, $state, $requested, requested => undef);

	$urpm->resolve_requested($db, $state, $requested, %options);
    }
}

sub create_transaction {
    my ($urpm, $state, %options) = @_;

    if ($urpm->{parallel_handler} || !$options{split_length} || $options{nodeps} ||
	keys %{$state->{selected}} < $options{split_level}) {
	#- build simplest transaction (no split).
	$urpm->build_transaction_set(undef, $state, split_length => 0);
    } else {
	my $db;

	if ($options{rpmdb}) {
	    $db = new URPM;
	    $db->parse_synthesis($options{rpmdb});
	} else {
	    $db = URPM::DB::open($urpm->{root});
	    $db or $urpm->{fatal}(9, N("unable to open rpmdb"));
	}

	my $sig_handler = sub { undef $db; exit 3 };
	local $SIG{INT} = $sig_handler;
	local $SIG{QUIT} = $sig_handler;

	#- build transaction set...
	$urpm->build_transaction_set($db, $state, split_length => $options{split_length});
    }
}

#- get list of package that should not be upgraded.
sub get_packages_list {
    my ($urpm, $file, $extra) = @_;
    my %val;

    local ($_, *F);
    open F, $file;
    while (<F>) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	if (my ($n, $s) = /^([^\s\[]+)(?:\[\*\])?\[?\s*([^\s\]]*\s*[^\s\]]*)/) {
 	    $val{$n}{$s} = undef;
	}
    }
    close F;

    #- additional skipping from given parameter.
    foreach (split ',', $extra) {
	if (my ($n, $s) = /^([^\s\[]+)(?:\[\*\])?\[?\s*([^\s\]]*\s*[^\s\]]*)/) {
 	    $val{$n}{$s} = undef;
	}
    }

    \%val;
}
#- for compability...
sub get_unwanted_packages {
    my ($urpm, $skip) = @_;
    print STDERR "calling obsoleted method urpm::get_unwanted_packages\n";
    get_packages_list($urpm->{skiplist}, $skip);
}

#- select source for package selected.
#- according to keys given in the packages hash.
#- return a list of list containing the source description for each rpm,
#- match exactly the number of medium registered, ignored medium always
#- have a null list.
sub get_source_packages {
    my ($urpm, $packages, %options) = @_;
    my ($id, $error, %protected_files, %local_sources, @list, %fullname2id, %file2fullnames, %examined);
    local (*D, *F, $_);

    #- build association hash to retrieve id and examine all list files.
    foreach (keys %$packages) {
	my $p = $urpm->{depslist}[$_];
	if ($urpm->{source}{$_}) {
	    $protected_files{$local_sources{$_} = $urpm->{source}{$_}} = undef;
	} else {
	    $fullname2id{$p->fullname} = $_.'';
	}
    }

    #- examine each medium to search for packages.
    #- now get rpm file name in hdlist to match list file.
    foreach my $pkg (@{$urpm->{depslist} || []}) {
	$file2fullnames{$pkg->filename}{$pkg->fullname} = undef;
    }

    #- examine the local repository, which is trusted (no gpg or pgp signature check but md5 is now done).
    opendir D, "$urpm->{cachedir}/rpms";
    while (defined($_ = readdir D)) {
	if (my ($filename) = /^([^\/]*\.rpm)$/) {
	    my $filepath = "$urpm->{cachedir}/rpms/$filename";
	    if (!$options{clean_all} && -s $filepath) {
		if (keys(%{$file2fullnames{$filename} || {}}) > 1) {
		    $urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\""), $filename);
		    next;
		} elsif (keys(%{$file2fullnames{$filename} || {}}) == 1) {
		    my ($fullname) = keys(%{$file2fullnames{$filename} || {}});
		    if (defined($id = delete $fullname2id{$fullname})) {
			$local_sources{$id} = $filepath;
		    } else {
			$options{clean_other} && ! exists $protected_files{$filepath} and unlink $filepath;
		    }
		} else {
		    $options{clean_other} && ! exists $protected_files{$filepath} and unlink $filepath;
		}
	    } else {
		#- this file should be removed or is already empty.
		unlink $filepath;
	    }
	} #- no error on unknown filename located in cache (because .listing) inherited from old urpmi
    }
    closedir D;

    #- clean download directory, do it here even if this is not the best moment.
    if ($options{clean_all}) {
	system("rm", "-rf", "$urpm->{cachedir}/partial");
	mkdir "$urpm->{cachedir}/partial";
    }

    foreach my $medium (@{$urpm->{media} || []}) {
	my (%sources, %list_examined, $list_warning);

	if (defined $medium->{start} && defined $medium->{end} && !$medium->{ignore}) {
	    #- always prefer a list file is available.
	    if ($medium->{list} && -r "$urpm->{statedir}/$medium->{list}") {
		open F, "$urpm->{statedir}/$medium->{list}";
		while (<F>) {
		    if (my ($filename) = /\/([^\/]*\.rpm)$/) {
			if (keys(%{$file2fullnames{$filename} || {}}) > 1) {
			    $urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\""), $filename);
			    next;
			} elsif (keys(%{$file2fullnames{$filename} || {}}) == 1) {
			    my ($fullname) = keys(%{$file2fullnames{$filename} || {}});
			    defined($id = $fullname2id{$fullname}) and $sources{$id} = $_;
			    $list_examined{$fullname} = $examined{$fullname} = undef;
			}
		    } else {
			chomp;
			$error = 1;
			$urpm->{error}(N("unable to correctly parse [%s] on value \"%s\"",
					 "$urpm->{statedir}/$medium->{list}", $_));
			last;
		    }
		}
		close F;
	    }
	    if (defined $medium->{url}) {
		foreach ($medium->{start} .. $medium->{end}) {
		    my $pkg = $urpm->{depslist}[$_];
		    if (keys(%{$file2fullnames{$pkg->filename} || {}}) > 1) {
			$urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\""), $pkg->filename);
			next;
		    } elsif (keys(%{$file2fullnames{$pkg->filename} || {}}) == 1) {
			my ($fullname) = keys(%{$file2fullnames{$pkg->filename} || {}});
			unless (exists($list_examined{$fullname})) {
			    ++$list_warning;
			    defined($id = $fullname2id{$fullname}) and $sources{$id} = "$medium->{url}/".$pkg->filename;
			    $examined{$fullname} = undef;
			}
		    }
		}
		$list_warning && $medium->{list} && -r "$urpm->{statedir}/$medium->{list}" and
		  $urpm->{error}(N("medium \"%s\" uses an invalid list file:
  mirror is probably not up-to-date, trying to use alternate method", $medium->{name}));
	    } elsif (!%list_examined) {
		$error = 1;
		$urpm->{error}(N("medium \"%s\" does not define any location for rpm files", $medium->{name}));
	    }
	}
	push @list, \%sources;
    }

    #- examine package list to see if a package has not been found.
    foreach (grep { ! exists($examined{$_}) } keys %fullname2id) {
	$error = 1;
	$urpm->{error}(N("package %s is not found.", $_));
    }

    $error ? @{[]} : (\%local_sources, \@list);
}

#- download package that may need to be downloaded.
#- make sure header are available in the appropriate directory.
#- change location to find the right package in the local
#- filesystem for only one transaction.
#- try to mount/eject removable media here.
#- return a list of package ready for rpm.
sub download_source_packages {
    my ($urpm, $local_sources, $list, %options) = @_;
    my %sources = %$local_sources;
    my %error_sources;

    print STDERR "calling obsoleted method urpm::download_source_packages\n";

    $urpm->exlock_urpmi_db;
    $urpm->copy_packages_of_removable_media($list, \%sources, %options) or return;
    $urpm->download_packages_of_distant_media($list, \%sources, \%error_sources, %options);
    $urpm->unlock_urpmi_db;

    %sources, %error_sources;
}

sub exlock_urpmi_db {
    my ($urpm) = @_;

    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my ($LOCK_EX, $LOCK_NB) = (2, 4);

    #- lock urpmi database, but keep lock to wait for an urpmi.update to finish.
    open LOCK_FILE, ">$urpm->{statedir}/.LOCK";
    flock LOCK_FILE, $LOCK_EX|$LOCK_NB or $urpm->{fatal}(7, N("urpmi database locked"));
}
sub shlock_urpmi_db {
    my ($urpm) = @_;

    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my ($LOCK_SH, $LOCK_NB) = (1, 4);

    #- create the .LOCK file if needed (and if possible)
    unless (-e "$urpm->{statedir}/.LOCK") {
	open LOCK_FILE, ">$urpm->{statedir}/.LOCK";
	close LOCK_FILE;
    }
    #- lock urpmi database, if the LOCK file doesn't exists no share lock.
    open LOCK_FILE, "$urpm->{statedir}/.LOCK" or return;
    flock LOCK_FILE, $LOCK_SH|$LOCK_NB or $urpm->{fatal}(7, N("urpmi database locked"));
}
sub unlock_urpmi_db {
    my ($urpm) = @_;

    #- avoid putting a require on Fcntl ':flock' (which is perl and not perl-base).
    my $LOCK_UN = 8;

    #- now everything is finished.
    system("sync");

    #- release lock on database.
    flock LOCK_FILE, $LOCK_UN;
    close LOCK_FILE;
}

sub copy_packages_of_removable_media {
    my ($urpm, $list, $sources, %options) = @_;
    my %removables;

    #- make sure everything is correct on input...
    @{$urpm->{media} || []} == @$list or return;

    #- examine if given medium is already inside a removable device.
    my $check_notfound = sub {
	my ($id, $dir, $removable) = @_;
	$dir and $urpm->try_mounting($dir, $removable);
	if (!$dir || -e $dir) {
	    foreach (values %{$list->[$id]}) {
		chomp;
		/^(removable_?[^_:]*|file):\/(.*\/([^\/]*))/ or next;
		unless ($dir) {
		    $dir = $2;
		    $urpm->try_mounting($dir, $removable);
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
	if (my ($prefix, $dir) = $medium->{url} =~ /^(removable[^:]*|file):\/(.*)/) {
	    #- the directory given does not exist or may be accessible
	    #- by mounting some other. try to figure out these directory and
	    #- mount everything necessary.
	    while ($check_notfound->($id, $dir, 'removable')) {
		$options{ask_for_medium} or $urpm->{fatal}(4, N("medium \"%s\" is not selected", $medium->{name}));
		$urpm->try_umounting($dir); system("eject", $device);
		$options{ask_for_medium}($medium->{name}, $medium->{removable}) or
		  $urpm->{fatal}(4, N("medium \"%s\" is not selected", $medium->{name}));
	    }
	    if (-e $dir) {
		while (my ($i, $url) = each %{$list->[$id]}) {
		    chomp $url;
		    my ($filepath, $filename) = $url =~ /^(?:removable[^:]*|file):\/(.*\/([^\/]*))/ or next;
		    if (-r $filepath) {
			if ($copy) {
			    #- we should assume a possible buggy removable device...
			    #- first copy in cache, and if the package is still good, transfert it
			    #- to the great rpms cache.
			    unlink "$urpm->{cachedir}/partial/$filename";
			    if (system("cp", "--preserve=mode", "--preserve=timestamps", "-R",
				       $filepath, "$urpm->{cachedir}/partial") &&
				URPM::verify_rpm("$urpm->{cachedir}/partial/$filename", nosignatures => 1) !~ /NOT OK/) {
				#- now we can consider the file to be fine.
				unlink "$urpm->{cachedir}/rpms/$filename";
				rename("$urpm->{cachedir}/partial/$filename", "$urpm->{cachedir}/rpms/$filename") or
				  system("mv", "$urpm->{cachedir}/partial/$filename", "$urpm->{cachedir}/rpms/$filename");
				-r "$urpm->{cachedir}/rpms/$filename" and $sources->{$i} = "$urpm->{cachedir}/rpms/$filename";
			    }
			} else {
			    $sources->{$i} = $filepath;
			}
		    }
		    unless ($sources->{$i}) {
			#- fallback to use other method for retrieving the file later.
			$urpm->{error}(N("unable to read rpm file [%s] from medium \"%s\"", $filepath, $medium->{name}));
		    }
		}
	    } else {
		$urpm->{error}(N("medium \"%s\" is not selected", $medium->{name}));
	    }
	} else {
	    #- we have a removable device that is not removable, well...
	    $urpm->{error}(N("incoherent medium \"%s\" marked removable but not really", $medium->{name}));
	}
    };

    foreach (0..$#$list) {
	values %{$list->[$_]} or next;
	my $medium = $urpm->{media}[$_];
	#- examine non removable device but that may be mounted.
	if ($medium->{removable}) {
	    push @{$removables{$medium->{removable}} ||= []}, $_;
	} elsif (my ($prefix, $dir) = $medium->{url} =~ /^(removable[^:]*|file):\/(.*)/) {
	    chomp $dir;
	    -e $dir || $urpm->try_mounting($dir) or
	      $urpm->{error}(N("unable to access medium \"%s\"", $medium->{name})), next;
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

    1;
}

sub download_packages_of_distant_media {
    my ($urpm, $list, $sources, $error_sources, %options) = @_;

    #- get back all ftp and http accessible rpms file into the local cache
    #- if necessary (as used by checksig or any other reasons).
    foreach (0..$#$list) {
	my %distant_sources;

	#- ignore as well medium that contains nothing about the current set of files.
	values %{$list->[$_]} or next;

	#- examine all files to know what can be indexed on multiple media.
	while (my ($i, $url) = each %{$list->[$_]}) {
	    #- it is trusted that the url given is acceptable, so the file can safely be ignored.
	    defined $sources->{$i} and next;
	    if ($url =~ /^(removable[^:]*|file):\/(.*\.rpm)$/) {
		if (-r $2) {
		    $sources->{$i} = $2;
		} else {
		    $error_sources->{$i} = $2;
		}
	    } elsif ($url =~ /^([^:]*):\/(.*\/([^\/]*\.rpm))$/) {
		if ($options{force_local} || $1 ne 'ftp' && $1 ne 'http') { #- only ftp and http protocol supported by grpmi.
		    $distant_sources{$i} = "$1:/$2";
		} else {
		    $sources->{$i} = "$1:/$2";
		}
	    } else {
		$urpm->{error}(N("malformed input: [%s]", $url));
	    }
	}

	#- download files from the current medium.
	if (%distant_sources) {
	    eval {
		$urpm->{log}(N("retrieving rpm files from medium \"%s\"...", $urpm->{media}[$_]{name}));
		$urpm->{sync}({ dir => "$urpm->{cachedir}/partial",
				quiet => 0,
				verbose => $options{verbose},
				limit_rate => $options{limit_rate},
				callback => $options{callback},
				proxy => $urpm->{proxy} },
			      values %distant_sources);
		$urpm->{log}(N("...retrieving done"));
	    };
	    if ($@) {
		$urpm->{log}(N("...retrieving failed: %s", $@));
	    }
	    #- clean files that have not been downloaded, but keep mind there
	    #- has been problem downloading them at least once, this is
	    #- necessary to keep track of failing download in order to
	    #- present the error to the user.
	    foreach my $i (keys %distant_sources) {
		my ($filename) = $distant_sources{$i} =~ /\/([^\/]*\.rpm)$/;
		if ($filename && -s "$urpm->{cachedir}/partial/$filename" &&
		    URPM::verify_rpm("$urpm->{cachedir}/partial/$filename", nosignatures => 1) !~ /NOT OK/) {
		    #- it seems the the file has been downloaded correctly and has been checked to be valid.
		    unlink "$urpm->{cachedir}/rpms/$filename";
		    rename("$urpm->{cachedir}/partial/$filename", "$urpm->{cachedir}/rpms/$filename") or
		      system("mv", "$urpm->{cachedir}/partial/$filename", "$urpm->{cachedir}/rpms/$filename");
		    -r "$urpm->{cachedir}/rpms/$filename" and $sources->{$i} = "$urpm->{cachedir}/rpms/$filename";
		}
		unless ($sources->{$i}) {
		    $error_sources->{$i} = $distant_sources{$i};
		}
	    }
	}
    }

    #- clean failed download which have succeeded.
    delete @{$error_sources}{keys %$sources};

    1;
}

#- prepare transaction.
sub prepare_transaction {
    my ($urpm, $set, $list, $sources, $transaction_list, $transaction_sources) = @_;

    foreach my $id (@{$set->{upgrade}}) {
	my $pkg = $urpm->{depslist}[$id];
	foreach (0..$#$list) {
	    exists $list->[$_]{$id} and $transaction_list->[$_]{$id} = $list->[$_]{$id};
	}
	exists $sources->{$id} and $transaction_sources->{$id} = $sources->{$id};
    }
}

#- extract package that should be installed instead of upgraded,
#- sources is a hash of id -> source rpm filename.
sub extract_packages_to_install {
    my ($urpm, $sources) = @_;
    my %inst;

    foreach (keys %$sources) {
	my $pkg = $urpm->{depslist}[$_] or next;
	$pkg->flag_disable_obsolete and $inst{$pkg->id} = delete $sources->{$pkg->id};
    }

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
	    $urpm->{logger_id} ||= 0;
	    printf "%-28s", N("Preparing...");
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

    $db or $urpm->{fatal}(9, N("unable to open rpmdb"));

    my $trans = $db->create_transaction($urpm->{root});
    if ($trans) {
	$urpm->{log}(N("created transaction for installing on %s (remove=%d, install=%d, upgrade=%d)", $urpm->{root} || '/',
		       scalar(@{$remove || []}), scalar(values %$install), scalar(values %$upgrade)));
    } else {
	return (N("unable to create transaction"));
    }

    my ($update, @l, %file2pkg) = 0;
    local *F;

    foreach (@$remove) {
	if ($trans->remove($_)) {
	    $urpm->{log}(N("removing package %s", $_));
	} else {
	    $urpm->{error}(N("unable to remove package %s", $_));
	}
    }
    foreach my $mode ($install, $upgrade) {
	foreach (keys %$mode) {
	    my $pkg = $urpm->{depslist}[$_];
	    $file2pkg{$mode->{$_}} = $pkg;
	    $pkg->update_header($mode->{$_});
	    if ($trans->add($pkg, update => $update,
			    $options{excludepath} ? (excludepath => [ split ',', $options{excludepath} ]) : ())) {
		$urpm->{log}(N("adding package %s (id=%d, eid=%d, update=%d, file=%s)", scalar($pkg->fullname),
			       $_, $pkg->id, $update, $mode->{$_}));
	    } else {
		$urpm->{error}(N("unable to install package %s", $mode->{$_}));
	    }
	}
	++$update;
    }
    !$options{nodeps} and @l = $trans->check(%options) and return @l;
    !$options{noorder} and @l = $trans->order and return @l;

    #- assume default value for some parameter.
    $options{delta} ||= 1000;
    $options{callback_open} ||= sub {
	my ($data, $type, $id) = @_;
	open F, $install->{$id} || $upgrade->{$id} or
	  $urpm->{error}(N("unable to access rpm file [%s]", $install->{$id} || $upgrade->{$id}));
	return fileno F;
    };
    $options{callback_close} ||= sub { close F };
    if (keys %$install || keys %$upgrade) {
	$options{callback_inst}  ||= \&install_logger;
	$options{callback_trans} ||= \&install_logger;
    }
    @l = $trans->run($urpm, %options);

    #- in case of error or testing, do not try to check rpmdb
    #- for packages being upgraded or not.
    @l || $options{test} and return @l;

    #- examine the local repository to delete package which have been installed.
    if ($options{post_clean_cache}) {
	foreach (keys %$install, keys %$upgrade) {
	    my $pkg = $urpm->{depslist}[$_];
	    $db->traverse_tag('name', [ $pkg->name ], sub {
				  my ($p) = @_;
				  $p->fullname eq $pkg->fullname or return;
				  unlink "$urpm->{cachedir}/rpms/".$pkg->filename;
			      });
	}
    }

    return @l;
}

#- install all files to node as remembered according to resolving done.
sub parallel_install {
    my ($urpm, $remove, $install, $upgrade, %options) = @_;
    $urpm->{parallel_handler}->parallel_install(@_);
}

#- find packages to remove.
sub find_packages_to_remove {
    my ($urpm, $state, $l, %options) = @_;

    if ($urpm->{parallel_handler}) {
	#- invoke parallel finder.
	$urpm->{parallel_handler}->parallel_find_remove($urpm, $state, $l, %options, find_packages_to_remove => 1);
    } else {
	my $db = URPM::DB::open($options{root});
	my (@m, @notfound);

	$db or $urpm->{fatal}(9, N("unable to open rpmdb"));

	if (!$options{matches}) {
	    foreach (@$l) {
		my ($n, $found);

		#- check if name-version-release may have been given.
		if (($n) = /^(.*)-[^\-]*-[^\-]*\.[^\.\-]*$/) {
		    $db->traverse_tag('name', [ $n ], sub {
					  my ($p) = @_;
					  $p->fullname eq $_ or return;
					  $urpm->resolve_rejected($db, $state, $p, removed => 1);
					  push @m, scalar $p->fullname;
					  $found = 1;
				      });
		    $found and next;
		}

		#- check if name-version-release may have been given.
		if (($n) = /^(.*)-[^\-]*-[^\-]*$/) {
		    $db->traverse_tag('name', [ $n ], sub {
					  my ($p) = @_;
					  join('-', ($p->fullname)[0..2]) eq $_ or return;
					  $urpm->resolve_rejected($db, $state, $p, removed => 1);
					  push @m, scalar $p->fullname;
					  $found = 1;
				      });
		    $found and next;
		}

		#- check if name-version may have been given.
		if (($n) = /^(.*)-[^\-]*$/) {
		    $db->traverse_tag('name', [ $n ], sub {
					  my ($p) = @_;
					  join('-', ($p->fullname)[0..1]) eq $_ or return;
					  $urpm->resolve_rejected($db, $state, $p, removed => 1);
					  push @m, scalar $p->fullname;
					  $found = 1;
				      });
		    $found and next;
		}

		#- check if only name may have been given.
		$db->traverse_tag('name', [ $_ ], sub {
				      my ($p) = @_;
				      $p->name eq $_ or return;
				      $urpm->resolve_rejected($db, $state, $p, removed => 1);
				      push @m, scalar $p->fullname;
				      $found = 1;
				  });
		$found and next;

		push @notfound, $_;
	    }
	    if (!$options{force} && @notfound && @$l > 1) {
		$options{callback_notfound} and $options{callback_notfound}->($urpm, @notfound)
		  or return ();
	    }
	}
	if ($options{matches} || @notfound) {
	    my $match = join "|", map { quotemeta } @$l;

	    #- reset what has been already found.
	    %$state = ();
	    @m = ();

	    #- search for package that matches, and perform closure again.
	    $db->traverse(sub {
			      my ($p) = @_;
			      $p->fullname =~ /$match/ or return;
			      $urpm->resolve_rejected($db, $state, $p, removed => 1);
			      push @m, scalar $p->fullname;
			  });

	    if (!$options{force} && @notfound) {
		unless (@m) {
		    $options{callback_notfound} and $options{callback_notfound}->($urpm, @notfound)
		      or return ();
		} else {
		    $options{callback_fuzzy} and $options{callback_fuzzy}->($urpm, $match, @m)
		      or return ();
		}
	    }
	}

	#- check if something need to be removed.
	if ($options{callback_base} && %{$state->{rejected} || {}}) {
	    my %basepackages;

	    #- check if a package to be removed is a part of basesystem requires.
	    $db->traverse_tag('whatprovides', [ 'basesystem' ], sub {
				  my ($p) = @_;
				  $basepackages{$p->fullname} = 0;
			      });

	    foreach (grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}}) {
		exists $basepackages{$_} or next;
		++$basepackages{$_};
	    }

	    grep { $_ } values %basepackages and
	      $options{callback_base}->($urpm, grep { $basepackages{$_} } keys %basepackages) || return ();
	}
    }
    grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected}};
}

#- remove packages from node as remembered according to resolving done.
sub parallel_remove {
    my ($urpm, $remove, %options) = @_;
    my $state = {};
    my $callback = sub { $urpm->{fatal}(1, "internal distributed remove fatal error") };
    $urpm->{parallel_handler}->parallel_find_remove($urpm, $state, $remove, %options,
						    callback_notfound => undef,
						    callback_fuzzy => $callback,
						    callback_base => $callback,
						   );
}

#- misc functions to help finding ask_unselect and ask_remove elements with their reasons translated.
sub unselected_packages {
    my ($urpm, $state) = @_;

    grep { $state->{rejected}{$_}{backtrack} } keys %{$state->{rejected} || {}};
}
sub translate_why_unselected {
    my ($urpm, $state, @l) = @_;

    map { my $rb = $state->{rejected}{$_}{backtrack};
	  my @froms = keys %{$rb->{closure} || {}};
	  my @unsatisfied = @{$rb->{unsatisfied} || []};
	  my $s = join ", ", ((map { N("due to missing %s", $_) } @froms),
			      (map { N("due to unsatisfied %s", $_) } @unsatisfied),
			      $rb->{promote} && !$rb->{keep} ? N("trying to promote %s", join(", ", @{$rb->{promote}})) : @{[]},
			      $rb->{keep} ? N("in order to keep %s", join(", ", @{$rb->{keep}})) : @{[]},
			     );
	  $_ . ($s ? " ($s)" : '');
      } @l;
}

sub removed_packages {
    my ($urpm, $state) = @_;

    grep { $state->{rejected}{$_}{removed} && !$state->{rejected}{$_}{obsoleted} } keys %{$state->{rejected} || {}};
}
sub translate_why_removed {
    my ($urpm, $state, @l) = @_;

    map { my ($from) = keys %{$state->{rejected}{$_}{closure}};
	  my ($whyk) = keys %{$state->{rejected}{$_}{closure}{$from}};
	  my ($whyv) = $state->{rejected}{$_}{closure}{$from}{$whyk};
	  my $frompkg = $urpm->search($from, strict_fullname => 1);
	  my $s;
	  for ($whyk) {
	      /old_requested/ and
		$s .= N("in order to install %s", $frompkg ? scalar $frompkg->fullname : $from);
	      /unsatisfied/ and do {
		  foreach (@$whyv) {
		      $s and $s .= ', ';
		      if (/([^\[\s]*)(?:\[\*\])?(?:\[|\s+)([^\]]*)\]?$/) {
			  $s .= N("due to unsatisfied %s", "$1 $2");
		      } else {
			  $s .= N("due to missing %s", $_);
		      }
		  }
	      };
	      /conflicts/ and
		$s .= N("due to conflicts with %s", $whyv);
	      /unrequested/ and
		$s .= N("unrequested");
	  }
	  #- now insert the reason if available.
	  $_ . ($s ? " ($s)" : '');
      } @l;
}

1;

__END__

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

    my ($local_sources, $list) = $urpm->get_source_packages(\%packages);
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
