package urpm::cfg;

use strict;
use warnings;

=head1 NAME

urpm::cfg - routines to handle the urpmi configuration files

=head1 SYNOPSIS

=head1 DESCRIPTION

=over

=cut

# Standard paths of the config files
our $PROXY_CFG = "/etc/urpmi/proxy.cfg";

=item set_environment($env_path)

Modifies the paths of the config files, so they will be searched
in the $env_path directory. This is obviously to be called early.

=cut

sub set_environment {
    my ($env) = @_;
    for ($PROXY_CFG) {
	$env =~ s,^/etc/urpmi,$env,;
    }
}

1;

__END__

=back

=cut
