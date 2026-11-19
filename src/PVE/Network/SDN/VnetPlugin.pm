package PVE::Network::SDN::VnetPlugin;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Exception qw(raise raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);

use PVE::SectionConfig;
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file(
    'sdn/vnets.cfg',
    sub { __PACKAGE__->parse_config(@_); },
    sub { __PACKAGE__->write_config(@_); },
);

my $sdn_vnet_id_pattern = '[a-zA-Z][a-zA-Z0-9]*[a-zA-Z0-9]';
my $vnet_min_length = 2;
my $vnet_max_length = 8;

sub pve_verify_sdn_vnet_id {
    my ($vnet, $noerr) = @_;

    my $len = length($vnet);

    if ($vnet !~ m/^$sdn_vnet_id_pattern\z/ || $len < $vnet_min_length || $len > $vnet_max_length) {
        return undef if $noerr;
        die "invalid SDN VNet '$vnet', must be $vnet_min_length-$vnet_max_length characters"
            . " long, start with a letter, and contain only alphanumeric characters\n";
    }
    return $vnet;
}

PVE::JSONSchema::register_format('pve-sdn-vnet-id', \&pve_verify_sdn_vnet_id);

PVE::JSONSchema::register_standard_option(
    'pve-sdn-vnet-id',
    {
        description => "The SDN vnet object identifier.",
        type => 'string',
        format => 'pve-sdn-vnet-id',
        pattern => $sdn_vnet_id_pattern,
        minLength => $vnet_min_length,
        maxLength => $vnet_max_length,
    },
);

my $defaultData = {

    propertyList => {
        vnet => get_standard_option(
            'pve-sdn-vnet-id',
            { completion => \&PVE::Network::SDN::Vnets::complete_sdn_vnet },
        ),
    },
};

sub type {
    return 'vnet';
}

sub private {
    return $defaultData;
}

sub properties {
    return {
        zone => {
            type => 'string',
            description => 'Name of the zone this VNet belongs to.',
        },
        type => {
            type => 'string',
            enum => ['vnet'],
            description => 'Type of the VNet.',
            optional => 1,
        },
        tag => {
            type => 'integer',
            description =>
                'VLAN Tag (for VLAN or QinQ zones) or VXLAN VNI (for VXLAN or EVPN zones).',
            optional => 1,
            minimum => 1,
            maximum => 16777215,
        },
        vlanaware => {
            type => 'boolean',
            description => 'Allow VLANs to pass through this vnet.',
            optional => 1,
        },
        alias => {
            type => 'string',
            description => "Alias name of the VNet.",
            pattern => qr/[\w ()*+,\-.\/:;<=>?@\[\]^]{0,256}/i,
            maxLength => 256,
            optional => 1,
        },
        'isolate-ports' => {
            type => 'boolean',
            description =>
                "If true, sets the isolated property for all interfaces on the bridge of this VNet.",
            optional => 1,
        },
    };
}

sub options {
    return {
        zone => { optional => 0 },
        tag => { optional => 1 },
        alias => { optional => 1 },
        vlanaware => { optional => 1 },
        'isolate-ports' => { optional => 1 },
    };
}

sub on_delete_hook {
    my ($class, $vnetid, $vnet_cfg) = @_;

    #verify if subnets are associated
    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid);
    raise_param_exc({ vnet => "Can't delete vnet if subnets exists" }) if $subnets;
}

sub on_update_hook {
    my ($class, $vnetid, $vnet_cfg) = @_;

    my $vnet = $vnet_cfg->{ids}->{$vnetid};
    my $tag = $vnet->{tag};
    my $vlanaware = $vnet->{vlanaware};

    #don't allow vlanaware change if subnets are defined
    if ($vnet->{vlanaware}) {
        my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid);
        raise_param_exc({ vlanaware => "vlanaware vnet is not compatible with subnets" })
            if $subnets;
    }
}

1;
