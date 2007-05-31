package urpm::signature;

# $Id$

use urpm::msg;
use urpm::media;
use urpm::util;


#- options: callback, basename
sub check {
    my ($urpm, $sources_install, $sources, %options) = @_;
    sort(_check($urpm, $sources_install, %options),
	 _check($urpm, $sources, %options));
}
sub _check {
    my ($urpm, $sources, %options) = @_;
    my ($medium, %invalid_sources);

    foreach my $id (keys %$sources) {
	my $filepath = $sources->{$id};
	my $verif = URPM::verify_signature($filepath);

	if ($verif =~ /NOT OK/) {
	    $verif =~ s/\n//g;
	    $invalid_sources{$filepath} = N("Invalid signature (%s)", $verif);
	} else {
	    unless ($medium && urpm::media::is_valid_medium($medium) &&
		    $medium->{start} <= $id && $id <= $medium->{end})
	    {
		$medium = undef;
		foreach (@{$urpm->{media}}) {
		    urpm::media::is_valid_medium($_) && $_->{start} <= $id && $id <= $_->{end}
			and $medium = $_, last;
		}
	    }
	    #- no medium found for this rpm ?
	    next if !$medium;
	    #- check whether verify-rpm is specifically disabled for this medium
	    next if defined $medium->{'verify-rpm'} && !$medium->{'verify-rpm'};

	    my $key_ids = $medium->{'key-ids'} || $urpm->{options}{'key-ids'};
	    #- check that the key ids of the medium match the key ids of the package.
	    if ($key_ids) {
		my $valid_ids = 0;
		my $invalid_ids = 0;

		foreach my $key_id ($verif =~ /(?:key id \w{8}|#)(\w+)/gi) {
		    if (grep { hex($_) == hex($key_id) } split /[,\s]+/, $key_ids) {
			++$valid_ids;
		    } else {
			++$invalid_ids;
		    }
		}

		if ($invalid_ids) {
		    $invalid_sources{$filepath} = N("Invalid Key ID (%s)", $verif);
		} elsif (!$valid_ids) {
		    $invalid_sources{$filepath} = N("Missing signature (%s)", $verif);
		}
	    }
	    #- invoke check signature callback.
	    $options{callback} and $options{callback}->(
		$urpm, $filepath,
		id => $id,
		verif => $verif,
		why => $invalid_sources{$filepath},
	    );
	}
    }
    map { ($options{basename} ? basename($_) : $_) . ": $invalid_sources{$_}" }
      keys %invalid_sources;
}

1;