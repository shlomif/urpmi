package urpm::get_pkgs;

# $Id$

use urpm::msg;
use urpm::sys;
use urpm::util;
use urpm::media;
use urpm 'file_from_local_url';


#- select sources for selected packages,
#- according to keys of the packages hash.
#- returns a list of lists containing the source description for each rpm,
#- matching the exact number of registered media; ignored media being
#- associated to a null list.
sub selected2list {
    my ($urpm, $packages, %options) = @_;
    my (%protected_files, %local_sources, %fullname2id);

    #- build association hash to retrieve id and examine all list files.
    foreach (keys %$packages) {
	foreach (split /\|/, $_) {
	    if ($urpm->{source}{$_}) {
		$protected_files{$local_sources{$_} = $urpm->{source}{$_}} = undef;
	    } else {
		$fullname2id{$urpm->{depslist}[$_]->fullname} = $_ . '';
	    }
	}
    }

    #- examine each medium to search for packages.
    #- now get rpm file name in hdlist to match list file.
    my %file2fullnames;
    foreach my $pkg (@{$urpm->{depslist} || []}) {
	$file2fullnames{$pkg->filename}{$pkg->fullname} = undef;
    }

    #- examine the local repository, which is trusted (no gpg or pgp signature check but md5 is now done).
    my $dh = urpm::sys::opendir_safe($urpm, "$urpm->{cachedir}/rpms");
    if ($dh) {
	while (defined(my $filename = readdir $dh)) {
	    my $filepath = "$urpm->{cachedir}/rpms/$filename";
	    if (-d $filepath) {
	    } elsif ($options{clean_all} || ! -s _) {
		unlink $filepath; #- this file should be removed or is already empty.
	    } else {
		if (keys(%{$file2fullnames{$filename} || {}}) > 1) {
		    $urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\"", $filename));
		} elsif (keys(%{$file2fullnames{$filename} || {}}) == 1) {
		    my ($fullname) = keys(%{$file2fullnames{$filename} || {}});
		    if (defined(my $id = delete $fullname2id{$fullname})) {
			$local_sources{$id} = $filepath;
		    } else {
			$options{clean_other} && ! exists $protected_files{$filepath} and unlink $filepath;
		    }
		} else {
		    $options{clean_other} && ! exists $protected_files{$filepath} and unlink $filepath;
		}
	    }
	}
	closedir $dh;
    }

    if ($options{clean_all}) {
	#- clean download directory, do it here even if this is not the best moment.
	$urpm->{log}(N("cleaning $urpm->{cachedir}/partial"));
	urpm::sys::clean_dir("$urpm->{cachedir}/partial");
    }

    my ($error, @list_error, @list, %examined);

    foreach my $medium (@{$urpm->{media} || []}) {
	my (%sources, %list_examined, $list_warning);

	if (urpm::media::is_valid_medium($medium) && !$medium->{ignore}) {
	    #- always prefer a list file if available.
	    if ($medium->{list}) {
		if (-r urpm::media::statedir_list($urpm, $medium)) {
		    foreach (cat_(urpm::media::statedir_list($urpm, $medium))) {
			chomp;
			if (my ($filename) = m!([^/]*\.rpm)$!) {
			    if (keys(%{$file2fullnames{$filename} || {}}) > 1) {
				$urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\"", $filename));
				next;
			    } elsif (keys(%{$file2fullnames{$filename} || {}}) == 1) {
				my ($fullname) = keys(%{$file2fullnames{$filename} || {}});
				if (defined(my $id = $fullname2id{$fullname})) {
				    if (!/\.delta\.rpm$/ || $urpm->is_delta_installable($urpm->{depslist}[$id], $urpm->{root})) {
					$sources{$id} = "$medium->{url}/$filename";
				    }
				}
				$list_examined{$fullname} = $examined{$fullname} = undef;
			    }
			} else {
			    chomp;
			    $error = 1;
			    $urpm->{error}(N("unable to correctly parse [%s] on value \"%s\"", urpm::media::statedir_list($urpm, $medium), $_));
			    last;
			}
		    }
		} else {
		    # list file exists but isn't readable
		    # report error only if no result found, list files are only readable by root
		    push @list_error, N("unable to access list file of \"%s\", medium ignored", $medium->{name});
		    $< and push @list_error, "    " . N("(retry as root?)");
		    next;
		}
	    }
	    if (defined $medium->{url}) {
		foreach ($medium->{start} .. $medium->{end}) {
		    my $pkg = $urpm->{depslist}[$_];
		    my $fi = $pkg->filename;
		    if (keys(%{$file2fullnames{$fi} || {}}) > 1) {
			$urpm->{error}(N("there are multiple packages with the same rpm filename \"%s\"", $fi));
			next;
		    } elsif (keys(%{$file2fullnames{$fi} || {}}) == 1) {
			my ($fullname) = keys(%{$file2fullnames{$fi} || {}});
			unless (exists($list_examined{$fullname})) {
			    ++$list_warning;
			    if (defined(my $id = $fullname2id{$fullname})) {
				if ($fi !~ /\.delta\.rpm$/ || $urpm->is_delta_installable($urpm->{depslist}[$id], $urpm->{root})) {
				    $sources{$id} = "$medium->{url}/" . $fi;
				}
			    }
			    $examined{$fullname} = undef;
			}
		    }
		}
		$list_warning && $medium->{list} && -r urpm::media::statedir_list($urpm, $medium) && -f _
		    and $urpm->{error}(N("medium \"%s\" uses an invalid list file:
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
	# print list errors only once if any
	$urpm->{error}($_) foreach @list_error;
	@list_error = ();
	$error = 1;
	$urpm->{error}(N("package %s is not found.", $_));
    }

    $error ? @{[]} : (\%local_sources, \@list);
}

# TODO verify that files are downloaded from the right corresponding media
#- options: quiet, callback, 
sub download_packages_of_distant_media {
    my ($urpm, $list, $sources, $error_sources, %options) = @_;

    #- get back all ftp and http accessible rpm files into the local cache
    foreach my $n (0..$#$list) {
	my %distant_sources;

	#- ignore media that contain nothing for the current set of files
	values %{$list->[$n]} or next;

	#- examine all files to know what can be indexed on multiple media.
	while (my ($i, $url) = each %{$list->[$n]}) {
	    #- the given URL is trusted, so the file can safely be ignored.
	    defined $sources->{$i} and next;
	    my $local_file = file_from_local_url($url);
	    if ($local_file && $local_file =~ /\.rpm$/) {
		if (-r $local_file) {
		    $sources->{$i} = $local_file;
		} else {
		    $error_sources->{$i} = $local_file;
		}
	    } elsif ($url =~ m!^([^:]*):/(.*/([^/]*\.rpm))\Z!) {
		$distant_sources{$i} = "$1:/$2"; #- will download now
	    } else {
		$urpm->{error}(N("malformed URL: [%s]", $url));
	    }
	}

	#- download files from the current medium.
	if (%distant_sources) {
	    $urpm->{log}(N("retrieving rpm files from medium \"%s\"...", $urpm->{media}[$n]{name}));
	    if (urpm::download::sync($urpm, $urpm->{media}[$n], [ values %distant_sources ],
				     quiet => $options{quiet}, resume => $urpm->{options}{resume}, callback => $options{callback})) {
		$urpm->{log}(N("...retrieving done"));
	    } else {
		$urpm->{error}(N("...retrieving failed: %s", $@));
	    }
	    #- clean files that have not been downloaded, but keep in mind
	    #- there have been problems downloading them at least once, this
	    #- is necessary to keep track of failing downloads in order to
	    #- present the error to the user.
	    foreach my $i (keys %distant_sources) {
		my ($filename) = $distant_sources{$i} =~ m|/([^/]*\.rpm)$|;
		if ($filename && -s "$urpm->{cachedir}/partial/$filename" &&
		    URPM::verify_rpm("$urpm->{cachedir}/partial/$filename", nosignatures => 1))
		{
		    #- it seems the the file has been downloaded correctly and has been checked to be valid.
		    unlink "$urpm->{cachedir}/rpms/$filename";
		    urpm::util::move("$urpm->{cachedir}/partial/$filename", "$urpm->{cachedir}/rpms/$filename");
		    -r "$urpm->{cachedir}/rpms/$filename" and $sources->{$i} = "$urpm->{cachedir}/rpms/$filename";
		}
		unless ($sources->{$i}) {
		    $error_sources->{$i} = $distant_sources{$i};
		}
	    }
	}
    }

    #- clean failed download which have succeeded.
    delete @$error_sources{keys %$sources};

    1;
}

1;
