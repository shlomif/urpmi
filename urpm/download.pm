package urpm::download;

use strict;
use urpm::msg;
use urpm::cfg;
use Cwd;

#- proxy config file.
our $PROXY_CFG = '/etc/urpmi/proxy.cfg';
my $proxy_config;

sub basename { local $_ = shift; s|/*\s*$||; s|.*/||; $_ }

sub import () {
    my $c = caller;
    no strict 'refs';
    foreach my $symbol (qw(get_proxy
	propagate_sync_callback
	sync_file sync_wget sync_curl sync_rsync sync_ssh
	set_proxy_config dump_proxy_config
    )) {
	*{$c.'::'.$symbol} = *$symbol;
    }
}

#- parses proxy.cfg (private)
sub load_proxy_config () {
    return if defined $proxy_config;
    open my $f, $PROXY_CFG or $proxy_config = {}, return;
    local $_;
    while (<$f>) {
	chomp; s/#.*$//; s/^\s*//; s/\s*$//;
	if (/^(?:(.*):\s*)?(ftp_proxy|http_proxy)\s*=\s*(.*)$/) {
	    $proxy_config->{$1 || ''}{$2} = $3;
	    next;
	}
	if (/^(?:(.*):\s*)?proxy_user\s*=\s*([^:]*)(?::(.*))?$/) {
	    $proxy_config->{$1 || ''}{user} = $2;
	    $proxy_config->{$1 || ''}{pwd} = $3 if defined $3;
	    next;
	}
    }
    close $f;
}

#- writes proxy.cfg
sub dump_proxy_config () {
    return 0 unless defined $proxy_config; #- hasn't been read yet
    open my $f, '>', $PROXY_CFG or return 0;
    print $f "# generated ".(scalar localtime)."\n";
    for ('', sort grep { !/^(|cmd_line)$/ } keys %$proxy_config) {
	my $m = $_ eq '' ? '' : "$_:";
	my $p = $proxy_config->{$_};
	for (qw(http_proxy ftp_proxy)) {
	    defined $p->{$_} && $p->{$_} ne ''
		and print $f "$m$_=$p->{$_}\n";
	}
	defined $p->{user} && $p->{user} ne ''
	    and print $f "${m}proxy_user=$p->{user}:$p->{pwd}\n";
    }
    close $f;
    chmod 0600, $PROXY_CFG; #- may contain passwords
    return 1;
}

#- deletes the proxy configuration for the specified media
sub remove_proxy_media {
    defined $proxy_config and delete $proxy_config->{$_[0] || ''};
}

#- reads and loads the proxy.cfg file ;
#- returns the global proxy settings (without arguments) or the
#- proxy settings for the specified media (with a media name as argument)
sub get_proxy (;$) {
    my ($o_media) = @_; $o_media ||= '';
    load_proxy_config();
    return $proxy_config->{cmd_line}
	|| $proxy_config->{$o_media}
	|| $proxy_config->{''}
	|| {
	    http_proxy => undef,
	    ftp_proxy => undef,
	    user => undef,
	    pwd => undef,
	};
}

#- overrides the config file proxy settings with values passed via command-line
sub set_cmdline_proxy {
    my (%h) = @_;
    $proxy_config->{cmd_line} ||= {
	http_proxy => undef,
	ftp_proxy => undef,
	user => undef,
	pwd => undef,
    };
    $proxy_config->{cmd_line}{$_} = $h{$_} for keys %h;
}

#- changes permanently the proxy settings
sub set_proxy_config {
    my ($key, $value, $o_media) = @_;
    $proxy_config->{$o_media || ''}{$key} = $value;
}

#- set up the environment for proxy usage for the appropriate tool.
#- returns an array of command-line arguments.
sub set_proxy {
    my ($proxy) = @_;
    my @res;
    if (defined $proxy->{proxy}{http_proxy} || defined $proxy->{proxy}{ftp_proxy}) {
	for ($proxy->{type}) {
	    /\bwget\b/ and do {
		for ($proxy->{proxy}) {
		    if (defined $_->{http_proxy}) {
			$ENV{http_proxy} = $_->{http_proxy} =~ /^http:/
			    ? $_->{http_proxy}
			    : "http://$_->{http_proxy}";
		    }
		    $ENV{ftp_proxy} = $_->{ftp_proxy} if defined $_->{ftp_proxy};
		    @res = ("--proxy-user=$_->{user}", "--proxy-passwd=$_->{pwd}")
			if defined $_->{user} && defined $_->{pwd};
		}
		last;
	    };
	    /\bcurl\b/ and do {
		for ($proxy->{proxy}) {
		    push @res, ('-x', $_->{http_proxy}) if defined $_->{http_proxy};
		    push @res, ('-x', $_->{ftp_proxy}) if defined $_->{ftp_proxy};
		    push @res, ('-U', "$_->{user}:$_->{pwd}")
			if defined $_->{user} && defined $_->{pwd};
		}
		last;
	    };
	    die N("Unknown webfetch `%s' !!!\n", $proxy->{type});
	}
    }
    return @res;
}

sub propagate_sync_callback {
    my $options = shift @_;
    if (ref($options) && $options->{callback}) {
	my $mode = shift @_;
	if ($mode =~ /^(?:start|progress|end)$/) {
	    my $file = shift @_;
	    $file =~ s|([^:]*://[^/:\@]*:)[^/:\@]*(\@.*)|$1xxxx$2|; #- if needed...
	    return $options->{callback}($mode, $file, @_);
	} else {
	    return $options->{callback}($mode, @_);
	}
    }
}

sub sync_file {
    my $options = shift;
    foreach (@_) {
	my ($in) = m!^(?:removable[^:]*|file):/(.*)!;
	propagate_sync_callback($options, 'start', $_);
	system("cp", "-p", "-R", $in || $_, ref($options) ? $options->{dir} : $options) and
	  die N("copy failed: %s", $@);
	propagate_sync_callback($options, 'end', $_);
    }
}

sub sync_wget {
    -x "/usr/bin/wget" or die N("wget is missing\n");
    my $options = shift @_;
    $options = { dir => $options } if !ref $options;
    #- force download to be done in cachedir to avoid polluting cwd.
    my $cwd = getcwd();
    chdir $options->{dir};
    my ($buf, $total, $file) = ('', undef, undef);
    my $wget_pid = open my $wget, join(" ", map { "'$_'" }
	#- construction of the wget command-line
	"/usr/bin/wget",
	($options->{limit_rate} ? "--limit-rate=$options->{limit_rate}" : ()),
	($options->{resume} ? "--continue" : ()),
	($options->{proxy} ? set_proxy({ type => "wget", proxy => $options->{proxy} }) : ()),
	($options->{callback} ? ("--progress=bar:force", "-o", "-") :
	    $options->{quiet} ? "-q" : @{[]}),
	"--retr-symlinks",
	"-NP",
	$options->{dir},
	@_
    ) . " |";
    local $/ = \1; #- read input by only one char, this is slow but very nice (and it works!).
    while (<$wget>) {
	$buf .= $_;
	if ($_ eq "\r" || $_ eq "\n") {
	    if ($options->{callback}) {
		if ($buf =~ /^--\d\d:\d\d:\d\d--\s+(\S.*)\n/ms) {
		    if ($file && $file ne $1) {
			propagate_sync_callback($options, 'end', $file);
			undef $file;
		    }
		    ! defined $file and propagate_sync_callback($options, 'start', $file = $1);
		} elsif (defined $file && ! defined $total && $buf =~ /==>\s+RETR/) {
		    $total = '';
		} elsif (defined $total && $total eq '' && $buf =~ /^[^:]*:\s+(\d\S*)/) {
		    $total = $1;
		} elsif (my ($percent, $speed, $eta) = $buf =~ /^\s*(\d+)%.*\s+(\S+)\s+ETA\s+(\S+)\s*[\r\n]$/ms) {
		    if (propagate_sync_callback($options, 'progress', $file, $percent, $total, $eta, $speed) eq 'canceled') {
			kill 15, $wget_pid;
			close $wget;
			return;
		    }
		    if ($_ eq "\n") {
			propagate_sync_callback($options, 'end', $file);
			($total, $file) = (undef, undef);
		    }
		}
	    } else {
		$options->{quiet} or print STDERR $buf;
	    }
	    $buf = '';
	}
    }
    $file and propagate_sync_callback($options, 'end', $file);
    chdir $cwd;
    close $wget or die N("wget failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
}

sub sync_curl {
    -x "/usr/bin/curl" or die N("curl is missing\n");
    my $options = shift @_;
    $options = { dir => $options } if !ref $options;
    #- force download to be done in cachedir to avoid polluting cwd,
    #- however for curl, this is mandatory.
    my $cwd = getcwd();
    chdir($options->{dir});
    my (@ftp_files, @other_files);
    foreach (@_) {
	m|^ftp://.*/([^/]*)$| && -e $1 && -s _ > 8192 and do {
	    push @ftp_files, $_; next;
	}; #- manage time stamp for large file only.
	push @other_files, $_;
    }
    if (@ftp_files) {
	my ($cur_ftp_file, %ftp_files_info);

	eval { require Date::Manip };

	#- prepare to get back size and time stamp of each file.
	open my $curl, join(" ", map { "'$_'" } "/usr/bin/curl",
	    ($options->{limit_rate} ? ("--limit-rate", $options->{limit_rate}) : ()),
	    ($options->{proxy} ? set_proxy({ type => "curl", proxy => $options->{proxy} }) : ()),
	    "--stderr", "-", # redirect everything to stdout
	    "-s", "-I", @ftp_files) . " |";
	while (<$curl>) {
	    if (/Content-Length:\s*(\d+)/) {
		!$cur_ftp_file || exists($ftp_files_info{$cur_ftp_file}{size})
		    and $cur_ftp_file = shift @ftp_files;
		$ftp_files_info{$cur_ftp_file}{size} = $1;
	    }
	    if (/Last-Modified:\s*(.*)/) {
		!$cur_ftp_file || exists($ftp_files_info{$cur_ftp_file}{time})
		    and $cur_ftp_file = shift @ftp_files;
		eval {
		    $ftp_files_info{$cur_ftp_file}{time} = Date::Manip::ParseDate($1);
		    #- remove day and hour.
		    $ftp_files_info{$cur_ftp_file}{time} =~ s/(\d{6}).{4}(.*)/$1$2/;
		};
	    }
	}
	close $curl;

	#- now analyse size and time stamp according to what already exists here.
	if (@ftp_files) {
	    #- re-insert back shifted element of ftp_files, because curl output above
	    #- has not been parsed correctly, so in doubt download them all.
	    push @ftp_files, keys %ftp_files_info;
	} else {
	    #- for that, it should be clear ftp_files is empty...
	    #- elsewhere, the above work was useless.
	    foreach (keys %ftp_files_info) {
		my ($lfile) = m|/([^/]*)$| or next; #- strange if we can't parse it correctly.
		my $ltime = eval { Date::Manip::ParseDate(scalar gmtime((stat $1)[9])) };
		$ltime =~ s/(\d{6}).{4}(.*)/$1$2/; #- remove day and hour.
		-s $lfile == $ftp_files_info{$_}{size} && $ftp_files_info{$_}{time} eq $ltime or
		push @ftp_files, $_;
	    }
	}
    }
    # Indicates whether this option is available in our curl
    our $location_trusted;
    if (!defined $location_trusted) {
	$location_trusted = `/usr/bin/curl -h` =~ /location-trusted/ ? 1 : 0;
    }
    #- http files (and other files) are correctly managed by curl wrt conditional download.
    #- options for ftp files, -R (-O <file>)*
    #- options for http files, -R (-z file -O <file>)*
    if (my @all_files = (
	    (map { ("-O", $_) } @ftp_files),
	    (map { m|/([^/]*)$| ? ("-z", $1, "-O", $_) : @{[]} } @other_files)))
    {
	my @l = (@ftp_files, @other_files);
	my ($buf, $file) = ('');
	my $curl_pid = open my $curl, join(" ", map { "'$_'" } "/usr/bin/curl",
	    ($options->{limit_rate} ? ("--limit-rate", $options->{limit_rate}) : ()),
	    ($options->{resume} ? ("--continue-at", "-") : ()),
	    ($options->{proxy} ? set_proxy({ type => "curl", proxy => $options->{proxy} }) : ()),
	    ($options->{quiet} && !$options->{verbose} ? "-s" : @{[]}),
	    "-k",
	    $location_trusted ? "--location-trusted" : @{[]},
	    "-R",
	    "-f",
	    "--stderr", "-", # redirect everything to stdout
	    @all_files) . " |";
	local $/ = \1; #- read input by only one char, this is slow but very nice (and it works!).
	while (<$curl>) {
	    $buf .= $_;
	    if ($_ eq "\r" || $_ eq "\n") {
		if ($options->{callback}) {
		    unless (defined $file) {
			$file = shift @l;
			propagate_sync_callback($options, 'start', $file);
		    }
		    if (my ($percent, $total, $eta, $speed) = $buf =~ /^\s*(\d+)\s+(\S+)[^\r\n]*\s+(\S+)\s+(\S+)[\r\n]$/ms) {
			if (propagate_sync_callback($options, 'progress', $file, $percent, $total, $eta, $speed) eq 'canceled') {
			    kill 15, $curl_pid;
			    close $curl;
			    return;
			}
			if ($_ eq "\n") {
			    propagate_sync_callback($options, 'end', $file);
			    $file = undef;
			}
		    } elsif ($buf =~ /^curl:/) { #- likely to be an error reported by curl
			local $/ = "\n";
			chomp $buf;
			propagate_sync_callback($options, 'error', $file, $buf);
		    }
		} else {
		    $options->{quiet} or print STDERR $buf;
		}
		$buf = '';
	    }
	}
	chdir $cwd;
	close $curl or die N("curl failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
    } else {
	chdir $cwd;
    }
}

sub _calc_limit_rate {
    my $limit_rate = $_[0];
    for ($limit_rate) {
	/^(\d+)$/     and $limit_rate = int $1/1024, last;
	/^(\d+)[kK]$/ and $limit_rate = $1, last;
	/^(\d+)[mM]$/ and $limit_rate = 1024*$1, last;
	/^(\d+)[gG]$/ and $limit_rate = 1024*1024*$1, last;
    }
    $limit_rate;
}

sub sync_rsync {
    -x "/usr/bin/rsync" or die N("rsync is missing\n");
    my $options = shift @_;
    $options = { dir => $options } if !ref $options;
    #- force download to be done in cachedir to avoid polluting cwd.
    my $cwd = getcwd();
    chdir($options->{dir});
    my $limit_rate = _calc_limit_rate $options->{limit_rate};
    foreach (@_) {
	my $count = 10; #- retry count on error (if file exists).
	my $basename = basename($_);
	my ($file) =  m!^rsync://[^\/]*::! ? (m|^rsync://(.*)|) : ($_);
	propagate_sync_callback($options, 'start', $file);
	do {
	    local $_;
	    my $buf = '';
	    open my $rsync, join(" ", "/usr/bin/rsync",
		($limit_rate ? "--bwlimit=$limit_rate" : ()),
		($options->{quiet} ? qw(-q) : qw(--progress -v)),
		($options->{compress} ? qw(-z) : ()),
		($options->{ssh} ? qw(-e ssh) : ()),
		qw(--partial --no-whole-file),
		"'$file' '$options->{dir}' |");
	    local $/ = \1; #- read input by only one char, this is slow but very nice (and it works!).
	    while (<$rsync>) {
		$buf .= $_;
		if ($_ eq "\r" || $_ eq "\n") {
		    if ($options->{callback}) {
			if (my ($percent, $speed) = $buf =~ /^\s*\d+\s+(\d+)%\s+(\S+)\s+/) {
			    propagate_sync_callback($options, 'progress', $file, $percent, undef, undef, $speed);
			}
		    } else {
			$options->{quiet} or print STDERR $buf;
		    }
		    $buf = '';
		}
	    }
	    close $rsync;
	} while ($? != 0 && --$count > 0 && -e $options->{dir} . "/$basename");
	propagate_sync_callback($options, 'end', $file);
    }
    chdir $cwd;
    $? == 0 or die N("rsync failed: exited with %d or signal %d\n", $? >> 8, $? & 127);
}

sub sync_ssh {
    -x "/usr/bin/ssh" or die N("ssh is missing\n");
    my $options =shift(@_);
    $options->{ssh} = 1;
    sync_rsync($options, @_);
}

#- default logger suitable for sync operation on STDERR only.
sub sync_logger {
    my ($mode, $file, $percent, $total, $eta, $speed) = @_;
    if ($mode eq 'start') {
	print STDERR "    $file\n";
    } elsif ($mode eq 'progress') {
	my $text;
	if (defined $total && defined $eta) {
	    $text = N("        %s%% of %s completed, ETA = %s, speed = %s", $percent, $total, $eta, $speed);
	} else {
	    $text = N("        %s%% completed, speed = %s", $percent, $speed);
	}
	print STDERR $text, " " x (79 - length($text)), "\r";
    } elsif ($mode eq 'end') {
	print STDERR " " x 79, "\r";
    } elsif ($mode eq 'error') {
	#- error is 3rd argument, saved in $percent
	print STDERR N("...retrieving failed: %s", $percent), "\n";
    }
}

1;

__END__

=head1 NAME

urpm::download - download routines for the urpm* tools

=head1 SYNOPSIS

=head1 DESCRIPTION

=cut
