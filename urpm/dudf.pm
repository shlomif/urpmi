package urpm::dudf;

# $Id: dudf.pm 639 2009-04-17 14:32:03Z orosello $

our @ISA = qw();
use strict;
use Exporter;
use URPM;
use urpm;
use urpm::msg;
use Cwd;
use IO::File;
use Switch;
use locale;
use POSIX qw(locale_h strtod);
use POSIX qw(strftime);
use File::Path;
use Compress::Zlib;
use XML::Writer;
use Data::UUID;

#- Timeout for curl connection and wget operations
our $CONNECT_TIMEOUT = 60; #-  (in seconds)

use fields qw(
    access_url
    distribution_codename
    distribution_description
    distribution_name
    distribution_release
    dudf_dir
    dudf_file
    dudf_filename
    dudf_time
    dudf_uid
    dudf_urpm
    exit_code
    exit_msg
    force_dudf
    installer_name
    installer_version
    log_file
    metainstaller_name
    metainstaller_version
    package_universe_synthesis
    packages_removed
    packages_upgraded
    pkgs_toinstall
    pkgs_user
    version
    xmlns
    xmlnsdudf
    );

my @package_status;

BEGIN {}

(our $VERSION) = q($Revision: 246 $) =~ /(\d+)/;

sub dudf_exit {
    my ($self, $exit_code, $o_exit_msg) = @_;
    $self->set_exit_code($exit_code);
    if ($o_exit_msg) {
        $self->set_exit_msg($o_exit_msg);
    }
    $self->write_dudf;
    exit($exit_code);
}

sub get_distribution {
    my ($self) = @_;

    my $handle = new IO::File;
    if ($handle->open("</etc/lsb-release")) {
        while (<$handle>) {
                if (m/DISTRIB_ID=/i)            { s/.*=//; s/\n//; $self->{distribution_name} = $_ }
                if (m/DISTRIB_RELEASE=/i)       { s/.*=//; s/\n//; $self->{distribution_release} = $_ }
                if (m/DISTRIB_CODENAME=/i)      { s/.*=//; s/\n//; $self->{distribution_codename} = $_ }
                if (m/DISTRIB_DESCRIPTION=/i)   {   s/.*=//; s///g; s/\n//; $self->{distribution_description} = $_ }
        }
        $handle->close;
    }
}

sub check_package {
    my ($urpm, $pkg) = @_;
    my $db = urpm::db_open_or_die_($urpm);
    my @l;
    $db->traverse_tag("name", [ $pkg ], sub {
                                                my ($p) = @_;
                                                $p->pack_header;
                                                push(@l, $p);
                                              });
    \@l;
}

# Find packages selected to be removed due to obsoletes and store them into @{$self->{packages_removed}}
# or due to upgrade or conflict and store them into @{$self->{packages_upgraded}}
sub check_removed_upgraded {
    my ($self, $state) = @_;
    my $urpm = ${$self->{dudf_urpm}};
    my $t = $state->{rejected};

    foreach my $pkg (keys %$t) {
        my $v = $t->{$pkg};
        if ($v->{obsoleted} == 1) {
            $pkg =~ s/-.*//;
            my $p = check_package($urpm,$pkg);
            push(@{$self->{packages_removed}}, $p);
        }
        if ($v->{removed} == 1) {
            $pkg =~ s/-.*//;
            my $p = check_package($urpm,$pkg);
            push(@{$self->{packages_upgraded}}, $p);
        }
    }        
}

sub get_package_status_ {
    my ($ps) = @_;
    $ps->pack_header;
    push(@package_status, $ps);
}

# Store list of installed packages
sub get_package_status {
    my ($self) = @_;
    my $db = urpm::db_open_or_die_(${$self->{dudf_urpm}});
    $db->traverse(\&get_package_status_);
}

# Store list of synthesis files to parse
sub get_package_universe {
    my ($self) = @_;
    my $urpm = ${$self->{dudf_urpm}};

    @{$self->{package_universe_synthesis}} = grep { !$_->{ignore} } @{$urpm->{media}};
}

# Parse a synthesis file
sub get_synthesis {
    my ($self, $file, $doc) = @_;
    my $buffer;

    my $gz = gzopen($file, "rb");
# or die "Cannot open $file: $gzerrno\n" ;

    $doc->characters($buffer) 
        while $gz->gzread($buffer) > 0;
#    die "Error reading from $file: $gzerrno\n" 
#        if my $gzerrno != Z_STREAM_END ;

    $gz->gzclose;
}

sub new {
    my ($class, $urpm, $action, $force_dudf) = @_;
    my $self = {
        dudf_urpm => $urpm,
        action => $action,
        force_dudf => $force_dudf,
        dudf_file => undef,
        exit_code => 0,
        metainstaller_name => $0,
        metainstaller_version => $urpm::VERSION,
        xmlns => "http://www.mancoosi.org/2008/cudf/dudf",
        xmlnsdudf => "http://www.mancoosi.org/2008/cudf/dudf",
        version => "1.0",
        dudf_time => undef
    };

    my $base_url = "http://dudf.forge.mandriva.com";
    $self->{access_url} = $base_url . "/file/";
    $self->{upload_url} = $base_url . "/upload";
    $self->{metainstaller_name} =~ s/.*\///;
    ${$self->{dudf_urpm}}->{fatal} = sub { printf STDERR "%s\n", $_[1]; $self->set_exit_msg($_[1]);  $self->set_exit_code($_[0]); $self->write_dudf; exit($_[0]) };
    ${$self->{dudf_urpm}}->{error} = sub { printf STDERR "%s\n", $self->set_exit_msg($_[0]); $_[0] };
    #${$self->{dudf_urpm}}->{log}   = sub { printf STDERR "%s\n", $_[0] };

    $urpm = ${$self->{dudf_urpm}};
    $self->{dudf_dir} = $urpm->{cachedir} . "/dudf";
    $self->{log_file} = $self->{dudf_dir} . "/dudf_uploads.log";
    if (!-d $self->{dudf_dir}) {
        mkpath($self->{dudf_dir});
    }

    # If there is no log file, we create the default content here
    if (! -f $self->{log_file})
    {
	output_safe($self->{log_file}, 
                    N("# Here are logs of your DUDF uploads.\n# Line format is : <date time of generation> <uid>\n# You can use uids to see the content of your uploads at this url :\n# http://dudf.forge.mandriva.com/"));
    }
    my $ug = new Data::UUID;
    $self->{dudf_uid} = $ug->to_string($ug->create_str);
    $self->{dudf_filename} = "dudf_" . $self->{dudf_uid} . ".dudf.xml";
    $self->{dudf_file} = $self->{dudf_dir} . "/" . $self->{dudf_filename};

    bless($self,$class);
    return $self;
}

sub set_exit_msg {
    my ($self, $m) = @_;
    $self->{exit_msg} = $m;
}

# store the exit code
sub set_exit_code {
    my ($self, $exit_code) = @_;

    $self->{exit_code} = $exit_code;
}

# Store the list of packages the user wants to install (given to urpmi)
sub store_userpkgs {
    my ($self, @pkgs) = @_;

    @{$self->{pkgs_user}} = @pkgs;
}

# Store a list of packages selected by urpmi to install
sub store_toinstall {
    my ($self, @pkgs) = @_;

    @{$self->{pkgs_toinstall}} = @pkgs;
}

#upload dudf data to server
sub upload_dudf {
    -x "/usr/bin/curl" or do { print N("curl is missing, cannot upload DUDF file.\n"); return };
    my ($self, $options) = @_;

    print N("Compressing DUDF data... ");
    # gzip the file to upload
    open(FILE, $self->{dudf_file}) or do { print N("NOT OK\n"); return };
    my $gz = gzopen($self->{dudf_file} . ".gz", "wb") or do { print N("NOT OK\n"); return };
    $gz->gzsetparams(Z_BEST_COMPRESSION, Z_DEFAULT_STRATEGY);
   
    while (<FILE>) {
        $gz->gzwrite($_);
    }
    $gz->gzclose;
    close(FILE);
    print N("OK\n");

    print N("Uploading DUDF data:\n");
    my (@ftp_files, @other_files);
    push @other_files, $self->{dudf_filename};
    my @l = (@ftp_files, @other_files);
    my $cmd = join(" ", map { "'$_'" } "/usr/bin/curl",
        "-q", # don't read .curlrc; some toggle options might interfer
        ($options->{proxy} ? urpm::download::set_proxy({ type => "curl", proxy => $options->{proxy} }) : ()),
        ($options->{retry} ? ('--retry', $options->{retry}) : ()),
        "--stderr", "-", # redirect everything to stdout
        "--connect-timeout", $CONNECT_TIMEOUT,
#                "-s",
        "-f", 
        "--anyauth",
        (defined $options->{'curl-options'} ? split /\s+/, $options->{'curl-options'} : ()),
        "-F file=@" . $self->{dudf_file} . ".gz",
        "-F id=" . $self->{dudf_uid},
        $self->{upload_url},
        );
    urpm::download::_curl_action($cmd, $options, @l, 1);
    unlink $self->{dudf_file} . ".gz";
    unlink $self->{dudf_file};
    print N("\nYou can see your DUDF report at the following URL :\n\t");
    print $self->{access_url} . "?uid=" . $self->{dudf_uid} . "\n";
    append_to_file($self->{log_file}, $self->{dudf_time} . "\t" . $self->{dudf_uid} . "\n");
    print N("You can access to a log of your uploads in\n\t") . $self->{log_file} . "\n";
}

sub xml_pkgs {
    my ($doc, $pk) = @_;

    $doc->startTag("package", "name" => $pk->name, "version" => $pk->version, "arch" => $pk->arch, "release" => $pk->release);
    if ($pk->provides) {
        $doc->startTag("provides");
        foreach my $i ($pk->provides) {
            $doc->characters("@" . $i);
        }
        $doc->endTag;
    }
    if ($pk->requires) {
        $doc->startTag("requires");
        foreach my $i ($pk->requires) {
            $doc->characters("@" . $i);
        }
        $doc->endTag;
    }
    if ($pk->conflicts) {
        $doc->startTag("conflicts");
        foreach my $i ($pk->conflicts) {
            $doc->characters("@" . $i);
        }
        $doc->endTag;
    }
    if ($pk->obsoletes) {
        $doc->startTag("obsoletes");
        foreach my $i ($pk->obsoletes) {
            $doc->characters("@" . $i);
        }
        $doc->endTag;
    }
    $doc->endTag;
}

# Generate DUDF data
sub write_dudf {
    my ($self) = @_;

    if ($self->{force_dudf} != 0 || $self->{exit_code} != 0) {
        my $noexpr = N("Nn");
        my $msg = N("A problem has been encountered. You can help Mandriva to improve packages installation \n");
        $msg .= N("by uploading us a DUDF report file. This is a part of the Mancoosi european research project.\n");
        $msg .= N("More at http://www.mancoosi.org\n");
        $msg .= N("Do you want to upload to Mandriva a DUDF report?");
        if ($self->{force_dudf} || message_input_($msg . N(" (Y/n) "), boolean => 1) !~ /[$noexpr]/) {
            print N("\nGenerating DUDF... ");

            urpm::db_open_or_die(urpm->new)->traverse_tag("name", [ "rpm" ], sub { my ($p) = @_; $self->{installer_name} = $p->name; $self->{installer_version} = $p->version });
            $self->get_package_status;
            $self->get_package_universe;

            my $output = new IO::File;
            if ($output->open(">" . $self->{dudf_file})) {
                my $doc = new XML::Writer(OUTPUT => $output, DATA_MODE => 1, DATA_INDENT => 1, NEW_LINES => 1, ENCODING => 'utf-8');
                $doc->xmlDecl("UTF-8");

                $self->get_distribution;

                my $old_locale = setlocale(LC_CTYPE);
                setlocale(LC_TIME, "C");
                my $now = time();

                $doc->startTag("dudf", version => $self->{version}, xmlns => $self->{xmlns}, "xmlns:dudf" => $self->{xmlnsdudf});
                $doc->dataElement(timestamp => strftime("%a, %d %b %Y %H:%M:%S %z", localtime($now)));
                $self->{dudf_time} = strftime("%Y%m%d %H:%M:%S %z", localtime($now));

                setlocale(LC_CTYPE, $old_locale);

                # From here, the indent is special : a new ident is made for each XML tag opening
                # It's easier to debug XML with this
                $doc->dataElement(uid => $self->{dudf_uid});

                    $doc->startTag("distribution");
                        $doc->characters($self->{distribution_name});
    # Following lines removed because these elements are not specified into dudf for now (leave comment in code for future usage)
    #                    $doc->dataElement(name => "$self->{distribution_name}");
    #                    $doc->dataElement(release => "$self->{distribution_release}");
    #                    $doc->dataElement(codename => "$self->{distribution_codename}");
    #                    $doc->dataElement(description => "$self->{distribution_description}");
                    $doc->endTag;
                    $doc->startTag("installer");
                        $doc->dataElement(name => $self->{installer_name});
                        $doc->dataElement(version => $self->{installer_version});
                    $doc->endTag;
                    $doc->startTag("meta-installer");
                        $doc->dataElement(name => $self->{metainstaller_name});
                        $doc->dataElement(version => $self->{metainstaller_version});
                    $doc->endTag;
                    $doc->startTag("problem");
                        $doc->startTag("package-status");
                            $doc->startTag("installer");
                                # packages removed by urpmi are added back
                                foreach my $pkg (@{$self->{packages_removed}}) {
                                    foreach my $pk (@$pkg) {
                                            xml_pkgs($doc,$pk);
                                    }
                                }
                                # packages upgraded by urpmi are restored in the list (version before upgrade)
                                foreach my $pkg (@{$self->{packages_upgraded}}) {
                                    foreach my $pk (@$pkg) {
                                            xml_pkgs($doc,$pk);
                                    }
                                }
                                # packages already installed before the launch of urpmi
                                foreach my $pk (@package_status) {
                                    # packages installed by urpmi are removed from the list 
                                    foreach my $pkg (@{$self->{pkgs_toinstall}}) {
                                        if ($pkg->name ne $pk->name || $pkg->version ne $pk->version || $pkg->arch ne $pk->arch || $pkg->release ne $pk->release) {
                                            xml_pkgs($doc,$pk);
                                        }
                                    }
                                }
                            $doc->endTag;
                            $doc->dataElement("meta-installer" => "meta installer package status");
                        $doc->endTag;
                        $doc->startTag("package-universe");
                            foreach my $media (@{$self->{package_universe_synthesis}}) {
                                my $file = $media->{name};
                                my $url = $media->{url};
                                my $filename = urpm::media::any_synthesis(${$self->{dudf_urpm}},$media);
                                $doc->startTag("package-list", "dudf:format" => "synthesis", "dudf:filetype" => $file, "dudf:filename" => $filename, "dudf:url" => $url);
                                $self->get_synthesis($filename, $doc);
                                $doc->endTag;
                            }
                        $doc->endTag;
                        $doc->startTag("action");
    #                        $doc->startTag("upgrade");
    #                            foreach my $pkg (@{$self->{pkgs_toinstall}}) {
    #                                if ($pkg->flag_installed) {
    #                                    $doc->startTag("package", "name" => $pkg->name, "version" => $pkg->version, "arch" => $pkg->arch, "release" => $pkg->release);
    #                                    $doc->endTag;
    #                                }
    #                            }
    #                        $doc->endTag;
    #                        $doc->startTag("install");
                                $doc->characters($self->{action});
     #                       $doc->endTag;
                        $doc->endTag;
                        $doc->startTag("selected");
                                foreach my $pkg (@{$self->{pkgs_user}}) {
                                    $doc->startTag("package", "name" => $pkg);
                                    $doc->endTag;
                                }
                        $doc->endTag;
                        $doc->startTag("desiderata");
                        $doc->endTag;
                    $doc->endTag;
                    $doc->startTag("outcome");
                        $doc->startTag("dudf:result");
                            $doc->characters(($self->{exit_code} == 0 ? "success" : "failure"));
                        $doc->endTag;
                        if ($self->{exit_code}) {
                            $doc->startTag("error");
                                $doc->characters($self->{exit_msg});
                            $doc->endTag;
                        }
                    $doc->endTag;
                $doc->endTag;
                $doc->end;
                $output->close;
                print N("OK\n");
                $self->upload_dudf;
            }
            else {
                print N("Cannot write DUDF file\n.");
            }
        }
    }
}

1;

__END__
