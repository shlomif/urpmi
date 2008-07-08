package urpm::get_pkgs;

# $Id$

use urpm::msg;
use urpm::sys;
use urpm::util;
use urpm::media;
use urpm 'file_from_local_url';


sub clean_all_cache {
    my ($urpm) = @_;
    #- clean download directory, do it here even if this is not the best moment.
    $urpm->{log}(N("cleaning %s and %s", "$urpm->{cachedir}/partial", "$urpm->{cachedir}/rpms"));
    urpm::sys::empty_dir("$urpm->{cachedir}/partial");
    urpm::sys::empty_dir("$urpm->{cachedir}/rpms");
}

sub cachedir_rpms {
    my ($urpm) = @_;

    #- examine the local repository, which is trusted (no gpg or pgp signature check but md5 is now done).
    my %fn2file;
    foreach my $filepath (glob("$urpm->{cachedir}/rpms/*")) {
	next if -d $filepath;

	if (! -s $filepath) {
	    unlink $filepath; #- this file should be removed or is already empty.
	} else {
	    my $filename = basename($filepath);
	    my ($fullname) = $filename =~ /(.*)\.rpm$/ or next;
	    $fn2file{$fullname} = $filepath;
	}
    }
    \%fn2file;
}

#- select sources for selected packages,
#- according to keys of the packages hash.
#- returns a list of lists containing the source description for each rpm,
#- matching the exact number of registered media; ignored media being
#- associated to a null list.
sub _selected2local_and_ids {
    my ($urpm, $packages, %options) = @_;
    my (%protected_files, %local_sources, %fullname2id);

    #- build association hash to retrieve id and examine all list files.
    foreach (keys %$packages) {
	foreach my $id (split /\|/, $_) {
	    if ($urpm->{source}{$_}) {
		my $file = $local_sources{$id} = $urpm->{source}{$id};
		$protected_files{$file} = undef;
	    } else {
		$fullname2id{$urpm->{depslist}[$id]->fullname} = $id;
	    }
	}
    }

    #- examine the local repository, which is trusted (no gpg or pgp signature check but md5 is now done).
    my $cachedir_rpms = cachedir_rpms($urpm);

    foreach my $fullname (keys %$cachedir_rpms) {
	    my $filepath = $cachedir_rpms->{$fullname};

	    if (my $id = delete $fullname2id{$fullname}) {
		$local_sources{$id} = $filepath;
	    } else {
		$options{clean_other} && ! exists $protected_files{$filepath} and unlink $filepath;
	    }
    }

    my %id2ids;
    foreach my $id (values %fullname2id) {
	my $pkg = $urpm->{depslist}[$id];
	my $fullname = $pkg->fullname;
	my @pkg_ids = $pkg->arch eq 'src' ? do {
	    # packages_by_name can't be used here since $urpm->{provides} doesn't have src.rpm
	    # so a full search is needed
	    my %requested;
	    urpm::select::search_packages($urpm, \%requested, [$pkg->name], src => 1);
	    map { split /\|/ } keys %requested;
	} : do {
	    map { $_->id } grep {
		$_->filename !~ /\.delta\.rpm$/ || $urpm->is_delta_installable($_, $urpm->{root});
	    } grep { $fullname eq $_->fullname } $urpm->packages_by_name($pkg->name);
	};

	$id2ids{$id} = \@pkg_ids;
    }

    (\%local_sources, \%id2ids);
}

sub selected2list {
    my ($urpm, $selected, %options) = @_;

    my ($local_sources, $id2ids) = _selected2local_and_ids($urpm, $selected, %options);

    # id_map is a remapping of id.
    # it is needed because @list must be [ { id => pkg } ] where id is one the selected id,
    # not really the real package id
    my %id_map;
    foreach my $id (keys %$id2ids) {
	$id_map{$_} = $id foreach @{$id2ids->{$id}};
    }

    my @remaining_ids = sort { $a <=> $b } keys %id_map;

    my @list = map {
	my $medium = $_;
	my %sources;
	if (urpm::media::is_valid_medium($medium) && !$medium->{ignore}) {
	    while (@remaining_ids) {
		my $id = $remaining_ids[0];
		$medium->{start} <= $id && $id <= $medium->{end} or last;
		shift @remaining_ids;

		my $pkg = $urpm->{depslist}[$id];
		$sources{$id_map{$id}} = "$medium->{url}/" . $pkg->filename;
	    }
	}
	\%sources;
    } (@{$urpm->{media} || []});

    if (@remaining_ids) {
	$urpm->{error}(N("package %s is not found.", $urpm->{depslist}[$_]->fullname)) foreach @remaining_ids;
	return;
    }

    ($local_sources, \@list);
}

#- side-effects: none
sub _create_blists {
    my ($media, $list) = @_;

    #- make sure everything is correct on input...
    $media or return;
    @$media == @$list or return;

    my $i;
    [ map { 
	my $list = $list->[$i++];
	%$list ? { medium => $_, list => $list } : ();
    } @$media ];
}

sub selected2local_and_blists {
    my ($urpm, $selected, %options) = @_;

    my ($local_sources, $list) = selected2local_and_blists($urpm, $selected, %options);
    ($local_sources, _create_blists($urpm->{media}, $list));
}

sub verify_partial_rpm_and_move {
    my ($urpm, $cachedir, $filename) = @_;

    URPM::verify_rpm("$cachedir/partial/$filename", nosignatures => 1) or do {
	unlink "$cachedir/partial/$filename";
	return;
    };
    #- it seems the the file has been downloaded correctly and has been checked to be valid.
    unlink "$cachedir/rpms/$filename";
    urpm::sys::move_or_die($urpm, "$cachedir/partial/$filename", "$cachedir/rpms/$filename");
    "$cachedir/rpms/$filename";
}

# TODO verify that files are downloaded from the right corresponding media
#- options: quiet, callback, 
sub download_packages_of_distant_media {
    my ($urpm, $blists, $sources, $error_sources, %options) = @_;

    my %errors;

    #- get back all ftp and http accessible rpm files into the local cache
    foreach my $blist (@$blists) {
	my %distant_sources;

	#- examine all files to know what can be indexed on multiple media.
	while (my ($i, $url) = each %{$blist->{list}}) {
	    #- the given URL is trusted, so the file can safely be ignored.
	    defined $sources->{$i} and next;
	    my $local_file = file_from_local_url($url);
	    if ($local_file && $local_file =~ /\.rpm$/) {
		if (-r $local_file) {
		    $sources->{$i} = $local_file;
		} else {
		    $errors{$i} = [ $local_file, 'missing' ];
		}
	    } elsif ($url =~ m!^([^:]*):/(.*/([^/]*\.rpm))\Z!) {
		$distant_sources{$i} = "$1:/$2"; #- will download now
	    } else {
		$urpm->{error}(N("malformed URL: [%s]", $url));
	    }
	}

	if (%distant_sources) {
	    _download_packages_of_distant_media($urpm, $sources, \%errors, $blist, \%distant_sources, %options);
	}
    }

    #- clean failed download which have succeeded.
    delete @errors{keys %$sources};

    push @$error_sources, values %errors;

    1;
}


sub _download_packages_of_distant_media {
    my ($urpm, $sources, $errors, $blist, $distant_sources, %options) = @_;

    my %distant_sources = %$distant_sources;

    my $cachedir = $urpm->{cachedir};
    if (! -w "$cachedir/partial") {
	if (my $userdir = urpm::userdir($urpm)) {
	    $cachedir = $userdir;
	    mkdir "$cachedir/partial";
	    mkdir "$cachedir/rpms";
	} else {
	    $urpm->{fatal}(1, N("Can not download packages into %s", "$cachedir/partial"));
	}
    }

    $urpm->{log}(N("retrieving rpm files from medium \"%s\"...", $blist->{media}{name}));
    if (urpm::download::sync($urpm, $blist->{media}, [ values %distant_sources ],
			     dir => "$cachedir/partial", quiet => $options{quiet}, 
			     resume => $urpm->{options}{resume}, callback => $options{callback})) {
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
	if ($filename && -s "$cachedir/partial/$filename") {
	    if (my $rpm = verify_partial_rpm_and_move($urpm, $cachedir, $filename)) {
		$sources->{$i} = $rpm;
	    } else {
		$errors->{$i} = [ $distant_sources{$i}, 'bad' ];
	    }
	} else {
	    $errors->{$i} = [ $distant_sources{$i}, 'missing' ];
	}
    }
}

1;
