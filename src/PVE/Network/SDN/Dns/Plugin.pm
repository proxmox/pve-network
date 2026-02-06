package PVE::Network::SDN::Dns::Plugin;

use strict;
use warnings;

use PVE::Tools qw(run_command);
use PVE::JSONSchema;
use PVE::Cluster;
use HTTP::Request;
use LWP::UserAgent;

use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file(
    'sdn/dns.cfg',
    sub { __PACKAGE__->parse_config(@_); },
    sub { __PACKAGE__->write_config(@_); },
);

PVE::JSONSchema::register_standard_option(
    'pve-sdn-dns-id',
    {
        description => "The SDN dns object identifier.",
        type => 'string',
        pattern => '[a-zA-Z][a-zA-Z0-9]*[a-zA-Z0-9]',
        minLength => 2,
    },
);

my $defaultData = {

    propertyList => {
        type => {
            description => "Plugin type.",
            type => 'string',
            format => 'pve-configid',
        },
        ttl => { type => 'integer', optional => 1 },
        reversev6mask => { type => 'integer', optional => 1 },
        dns => get_standard_option(
            'pve-sdn-dns-id',
            { completion => \&PVE::Network::SDN::Dns::complete_sdn_dns },
        ),
        fingerprint => get_standard_option('fingerprint-sha256', { optional => 1 }),
    },
};

sub private {
    return $defaultData;
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
        my ($type, $id) = (lc($1), $2);
        my $errmsg = undef; # set if you want to skip whole section
        eval { PVE::JSONSchema::pve_verify_configid($type); };
        $errmsg = $@ if $@;
        my $config = {}; # to return additional attributes
        return ($type, $id, $errmsg, $config);
    }
    return undef;
}

sub add_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;

    die "please implement inside plugin";
}

sub add_ptr_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;

    die "please implement inside plugin";
}

sub del_ptr_record {
    my ($class, $plugin_config, $zone, $ip, $noerr) = @_;

    die "please implement inside plugin";
}

sub del_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;

    die "please implement inside plugin";
}

sub verify_zone {
    my ($class, $plugin_config, $zone, $noerr) = @_;

    die "please implement inside plugin";
}

sub get_reversedns_zone {
    my ($class, $plugin_config, $subnetid, $subnet, $ip) = @_;

    die "please implement inside plugin";
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;
}

1;
