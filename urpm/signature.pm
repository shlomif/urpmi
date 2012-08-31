package urpm::signature;

# $Id: signature.pm 253617 2009-03-05 11:18:45Z tv $

use strict;
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
	$filepath !~ /\.spec$/ or next;

	$urpm->{debug} and $urpm->{debug}("verifying signature of $filepath");
	#- rpmlib is doing strftime %c, and so the string comes from the current encoding
	#- (URPM::bind_rpm_textdomain_codeset() doesn't help here)
	#- so we have to transform...
	my $verif = urpm::msg::from_locale_encoding(URPM::verify_signature($filepath, $urpm->{urpmi_root}));

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
	    if (!$medium) {
		if ($verif =~ /OK \(\(none\)\)/) {
	            $verif =~ s/\n//g;
	            $urpm->{info}(N("The following package has no signature (%s): %s\n", $verif, $filepath));
	        }
		next;
	    }
	    #- check whether verify-rpm is specifically disabled for this medium
	    if (defined $medium->{'verify-rpm'} && !$medium->{'verify-rpm'}) {
		$urpm->{log}(N("NOT checking %s\n", $filepath));
		next;
	    }

	    my $key_ids = $medium->{'key-ids'} || $urpm->{options}{'key-ids'};
	    #- check that the key ids of the medium match the key ids of the package.
	    if ($key_ids) {
		my $valid_ids = 0;
		my $invalid_ids = 0;

		foreach my $key_id ($verif =~ /(?:key id \w{8}|#)(\w+)/gi) {
		    if (any { hex($_) == hex($key_id) } split /[,\s]+/, $key_ids) {
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
	    } elsif ($urpm::args::options{usedistrib} && $medium->{virtual}) {
		$urpm->{info}(N("SECURITY: Medium \"%s\" has no key (%s)!", $verif));
	    } else {
		$invalid_sources{$filepath} = N("Medium without key (%s)", $verif);
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
