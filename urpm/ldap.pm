package urpm::ldap;

use strict;
use warnings;
use urpm::msg 'N';

use Net::LDAP;
use MDK::Common;

my $LDAP_CONFIG_FILE = '/etc/openldap/ldap.conf'; 
# FIXME duplication 
my @per_media_opt = qw(
    downloader 
    hdlist
    ignore
    key-ids
    list
    md5sum    
    noreconfigure
    priority
    priority-upgrade
    removable
    synthesis
    update
    verify-rpm 
    virtual
    with_hdlist
);

# TODO
# use srv dns record ?
# complete the doc


=head1 NAME

urpm::ldap - routines to handle configuration with ldap

=head1 SYNOPSIS

=head1 DESCRIPTION

=over

=item write_ldap_cache($urpm,$medium)

Write the value fetched from ldap, in case of failure of server
This should not be used to reduce the load of ldap server, as 
fetching is still needed, and therefore, caching is useless if server is up

=item check_ldap_medium($medium)

Check if the ldap medium has all needed attributes.

=item read_ldap_cache($urpm,%options)

Read the cache created by the function write_ldap_cache.
should be called if the ldap server do not respond ( upgrade, network problem,
mobile user, etc ).

=item clean_ldap_cache($urpm)

Clean the ldap cache, remove all file in the directory.

=item load_ldap_media($urpm,%options)

=item get_ldap_config

=item get_ldap_config_file($file)

=item get_ldap_config_dns

=cut

sub write_ldap_cache($$) {
    my ($urpm, $medium) = @_;
    my $ldap_cache = "$urpm->{cachedir}/ldap";
    # FIXME what perm for cache ?
    mkdir_p($ldap_cache);
    open(my $cache, ">$ldap_cache/$medium->{name}") or die N("Cannot write cache file for ldap\n");
    print $cache "# internal cache file for disconnect ldap operation, do not edit\n";
    foreach (keys %$medium)
    {
        defined $medium->{$_} or next;
        print $cache "$_ = $medium->{$_}\n";
    }
    close($cache);
}

sub check_ldap_medium($) {
    my ($medium) = @_;
    return $medium->{name} && $medium->{clear_url};
}

sub read_ldap_cache($%) {
    my ($urpm, %options) = @_;
    foreach (glob("$urpm->{cachedir}/ldap/*"))
    {
        ! -f $_ and next;
        my %medium = getVarsFromSh($_);
        next if ! check_ldap_medium(\%medium); 
        $urpm->probe_medium(\%medium, %options) and push @{$urpm->{media}}, \%medium;
    }
}

#- clean the cache, before writing a new one
sub clean_ldap_cache($) {
    my ($urpm) = @_;
    unlink($_) foreach glob("$urpm->{cachedir}/ldap/*");
}

sub get_ldap_config {
    return get_ldap_config_file($LDAP_CONFIG_FILE);
}

sub get_ldap_config_file($) {
    my ($file) = @_;
    my %config;
    # TODO more verbose error ? 
    open(my $CONFIG, $file) or return;
    while(<$CONFIG>) {
        s/#.*//;
        s/^\s*//;
        s/\s*$//;
        s/\s{2}/ /g;
        /^$/ and next;
        /^(\S*)\s*(\S*)/;
        ! $2 and next;
        $config{$1} = $2;
    }
    close($CONFIG);
    return \%config;
}

sub get_ldap_config_dns {
    # TODO  
    die "not implemented now";
}


sub load_ldap_media($%) {
    my ($urpm,%options) = @_;
    
    my $config = get_ldap_config() or return ;
    
    # try first urpmi_foo and then foo
    for my $opt ('base', 'uri', 'filter', 'host', 'ssl', 'port', 'binddn', 'passwd', 'scope' )
    {
        if ( !defined $config->{"$opt"} && defined $config->{"urpmi_$opt"})
        {
            $config->{"$opt"} =  $config->{"urpmi_$opt"};
        }
    }

    die N("No server defined, missing uri or host") if ! ( defined $config->{'uri'} || defined $config->{'host'} );
    die N("No base defined") if ! defined $config->{'base'};
    
    if (! defined $config->{'uri'}) {
        $config->{'uri'} = "ldap" . ( $config->{'ssl'} eq 'on' ? "s" : "" ) . "://" . 
                            $config->{'host'} . (  $config->{'port'} ? ":" . $config->{'port'} : "" ) . "/" ;
    }


    eval {
        my $ldap = Net::LDAP->new($config->{'uri'}) 
            or die N("Cannot connect to ldap uri :"), $config->{'uri'};

        $ldap->bind($config->{'binddn'}, $config->{'password'}) 
            or die N("Cannot connect to ldap uri :"), $config->{'uri'};
        #- base is mandatory
        my $result = $ldap->search( 
            base   => $config->{'base'} ,
            filter => $config->{'filter'} || '(objectClass=urpmiRepository)',
            scope => $config->{'scope'} || 'sub' 
        );
        
        $result->code and die $result->error;
        # FIXME more than one server ?
        clean_ldap_cache($urpm);
        
        foreach my $entry ($result->all_entries) {
            my $medium = {};
            my  %ldap_changed_attributes = (
                'source-name' => 'name',
                'url' => 'clear_url',
                'with-hdlist' => 'with_hdlist'
            );

            foreach my $opt (@per_media_opt, keys %ldap_changed_attributes) {
                defined $entry->get_value($opt) and $medium->{$opt} = $entry->get_value($opt);
            }    

            #- name is not valid for the schema ( already in top )
            #- and _ are forbidden in attributes names

            foreach ( keys ( %ldap_changed_attributes ) )
            {
                $medium->{$ldap_changed_attributes{$_}} = $medium->{$_};
                delete $medium->{$_};
            }
            #- add ldap_ to reduce collision
            #- TODO check if name already defined ?
            $medium->{'name'} = "ldap" . "_" . $medium->{'name'};
            $medium->{'ldap'} = 1;
            next if ! check_ldap_medium($medium);
            $urpm->probe_medium($medium, %options) and push @{$urpm->{media}}, $medium;
            $urpm->write_ldap_cache($medium) or $urpm->{log}(N("Could not write ldap cache : ") . $_ );
        } 
    };
    if ($@)
    {
        $urpm->{log}($@);
        read_ldap_cache($urpm,%options);
    }

}

1;
