package PVE::API2::Network::SDN::Nodes::Zone;

use strict;
use warnings;

use JSON qw(decode_json);

use PVE::Exception qw(raise_param_exc);
use PVE::INotify;
use PVE::IPRoute2;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network;
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones;
use PVE::RS::SDN::Fabrics;
use PVE::Tools qw(extract_param run_command);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'diridx',
    path => '',
    method => 'GET',
    description => "Directory index for SDN zone status.",
    permissions => {
        check => ['perm', '/sdn/zones/{zone}', ['SDN.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            zone => get_standard_option('pve-sdn-zone-id'),
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
        my $res = [
            { subdir => 'content' }, { subdir => 'bridges' }, { subdir => 'ip-vrf' },
        ];

        return $res;
    },
});

__PACKAGE__->register_method({
    path => 'content',
    name => 'index',
    method => 'GET',
    description => "List zone content.",
    permissions => {
        check => ['perm', '/sdn/zones/{zone}', ['SDN.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            zone => get_standard_option(
                'pve-sdn-zone-id',
                {
                    completion => \&PVE::Network::SDN::Zones::complete_sdn_zone,
                },
            ),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                vnet => {
                    description => "Vnet identifier.",
                    type => 'string',
                },
                status => {
                    description => "Status.",
                    type => 'string',
                    optional => 1,
                },
                statusmsg => {
                    description => "Status details",
                    type => 'string',
                    optional => 1,
                },
            },
        },
        links => [{ rel => 'child', href => "{vnet}" }],
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();

        my $authuser = $rpcenv->get_user();

        my $zoneid = $param->{zone};

        my $res = [];

        my ($zone_status, $vnet_status) = PVE::Network::SDN::Zones::status();

        foreach my $id (keys %{$vnet_status}) {
            if ($vnet_status->{$id}->{zone} eq $zoneid) {
                my $item->{vnet} = $id;
                $item->{status} = $vnet_status->{$id}->{'status'};
                $item->{statusmsg} = $vnet_status->{$id}->{'statusmsg'};
                push @$res, $item;
            }
        }

        return $res;
    },
});

1;
