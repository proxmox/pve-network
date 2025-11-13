package PVE::API2::Network::SDN::Nodes::Vnet;

use strict;
use warnings;

use PVE::API2::Network::SDN::Vnets;
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones;
use PVE::RS::SDN::Fabrics;
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'diridx',
    path => '',
    method => 'GET',
    description => "",
    permissions => {
        description => "Require 'SDN.Audit' permissions on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vnet => get_standard_option(
                'pve-sdn-vnet-id',
                {
                    completion => \&PVE::Network::SDN::Vnets::complete_sdn_vnets,
                },
            ),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                subdir => { type => 'string' },
            },
        },
        links => [{ rel => 'child', href => "{subdir}" }],
    },
    code => sub {
        my ($param) = @_;

        my $vnet_id = extract_param($param, 'vnet');
        $PVE::API2::Network::SDN::Vnets::check_vnet_access->($vnet_id, ['SDN.Audit']);

        my $res = [
            { subdir => 'mac-vrf' },
        ];

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'mac-vrf',
    path => 'mac-vrf',
    proxyto => 'node',
    method => 'GET',
    description => "Get the MAC VRF for a VNet in an EVPN zone.",
    protected => 1,
    permissions => {
        description => "Require 'SDN.Audit' permissions on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            vnet => get_standard_option(
                'pve-sdn-vnet-id',
                {
                    completion => \&PVE::Network::SDN::Vnets::complete_sdn_vnets,
                },
            ),
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        description =>
            'All routes from the MAC VRF that this node self-originates or has learned via BGP.',
        type => 'array',
        items => {
            type => 'object',
            properties => {
                ip => {
                    type => 'string',
                    format => 'ip',
                    description => 'The IP address of the MAC VRF entry.',
                },
                mac => {
                    type => 'string',
                    format => 'mac-addr',
                    description => 'The MAC address of the MAC VRF entry.',
                },
                'nexthop' => {
                    type => 'string',
                    format => 'ip',
                    description => 'The IP address of the nexthop.',
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $vnet_id = extract_param($param, 'vnet');

        $PVE::API2::Network::SDN::Vnets::check_vnet_access->($vnet_id, ['SDN.Audit']);

        my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnet_id, 1);

        raise_param_exc({
            vnet => "vnet does not exist",
        })
            if !$vnet;

        my $zone = PVE::Network::SDN::Zones::get_zone($vnet->{zone}, 1);

        raise_param_exc({
            zone => "zone $vnet->{zone} does not exist",
        })
            if !$zone;

        raise_param_exc({
            zone => "zone $vnet->{zone} is not an EVPN zone.",
        })
            if $zone->{type} ne 'evpn';

        my $node_id = extract_param($param, 'node');

        raise_param_exc({
            zone => "zone $vnet->{zone} of vnet $vnet_id does not exist on node $node_id",
        })
            if defined($zone->{nodes}) && !grep { $_ eq $node_id } $zone->{nodes}->@*;

        return PVE::RS::SDN::Fabrics::l2vpn_routes($vnet_id);
    },
});

1;
