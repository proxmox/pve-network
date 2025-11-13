package PVE::API2::Network::SDN::Nodes::Fabric;

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN::Fabrics;
use PVE::RPCEnvironment;
use PVE::RS::SDN::Fabrics;
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'diridx',
    path => '',
    method => 'GET',
    description => "Directory index for SDN fabric status.",
    permissions => {
        check => ['perm', '/sdn/fabrics/{fabric}', ['SDN.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            fabric => get_standard_option('pve-sdn-fabric-id'),
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
            { subdir => 'neighbors' }, { subdir => 'routes' },
        ];

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'routes',
    path => 'routes',
    method => 'GET',
    description => "Get all routes for a fabric.",
    permissions => {
        check => ['perm', '/sdn/fabrics/{fabric}', ['SDN.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            fabric => get_standard_option('pve-sdn-fabric-id'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                route => {
                    description => "The CIDR block for this routing table entry.",
                    type => 'string',
                },
                via => {
                    description => "A list of nexthops for that route.",
                    type => 'array',
                    items => {
                        type => 'string',
                        description => 'The IP address of the nexthop.',
                    },
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $fabric_id = extract_param($param, 'fabric');
        return PVE::RS::SDN::Fabrics::routes($fabric_id);
    },
});

__PACKAGE__->register_method({
    name => 'neighbors',
    path => 'neighbors',
    method => 'GET',
    description => "Get all neighbors for a fabric.",
    permissions => {
        check => ['perm', '/sdn/fabrics/{fabric}', ['SDN.Audit']],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            fabric => get_standard_option('pve-sdn-fabric-id'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                neighbor => {
                    description => "The IP or hostname of the neighbor.",
                    type => 'string',
                },
                status => {
                    description => "The status of the neighbor, as returned by FRR.",
                    type => 'string',
                },
                uptime => {
                    description =>
                        "The uptime of this neighbor, as returned by FRR (e.g. 8h24m12s).",
                    type => 'string',
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $fabric_id = extract_param($param, 'fabric');
        return PVE::RS::SDN::Fabrics::neighbors($fabric_id);
    },
});

__PACKAGE__->register_method({
    name => 'interfaces',
    path => 'interfaces',
    method => 'GET',
    description => "Get all interfaces for a fabric.",
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/fabrics/{fabric}', ['SDN.Audit']],
    },
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            fabric => get_standard_option('pve-sdn-fabric-id'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                name => {
                    description => "The name of the network interface.",
                    type => 'string',
                },
                type => {
                    description =>
                        "The type of this interface in the fabric (e.g. Point-to-Point, Broadcast, ..).",
                    type => 'string',
                },
                state => {
                    description => "The current state of the interface.",
                    type => 'string',
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $fabric_id = extract_param($param, 'fabric');
        return PVE::RS::SDN::Fabrics::interfaces($fabric_id);
    },
});

1;
