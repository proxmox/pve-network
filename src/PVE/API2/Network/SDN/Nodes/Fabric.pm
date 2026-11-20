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
    description => "Get all neighbors for a fabric, empty if this node is not part of it.",
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
                    description =>
                        "The IP or hostname of the neighbor. For WireGuard, the endpoint"
                        . " currently used, including the port. Omitted for WireGuard peers"
                        . " without a known endpoint.",
                    format_description => '(<IP>|<Host>)[:<port>]',
                    type => 'string',
                    optional => 1,
                },
                status => {
                    description =>
                        "The status of the neighbor. As returned by FRR for OSPF, Openfabric and"
                        . " BGP. For WireGuard, derived from the latest handshake: 'active' if"
                        . " the peer has a recent session, 'down' if it is unreachable despite"
                        . " persistent keepalive, 'idle' otherwise.",
                    type => 'string',
                },
                uptime => {
                    description =>
                        "The uptime of this neighbor, as returned by FRR, e.g. 8h24m12s"
                        . " (OSPF, Openfabric, BGP only)",
                    type => 'string',
                    optional => 1,
                },
                name => {
                    description =>
                        "The name for this neighbor in the WireGuard fabric. Omitted for peers"
                        . " that are not part of the fabric configuration. (WireGuard only)",
                    format_description => '<node>[ (<interface>)]',
                    type => 'string',
                    optional => 1,
                },
                interface => {
                    description =>
                        "The name of the interface that uses this neighbor as a peer"
                        . " (WireGuard only)",
                    type => 'string',
                    optional => 1,
                },
                'public-key' => {
                    description => "The public key used for this neighbor (WireGuard only)",
                    format_description => 'Base64-encoded Curve 25519 public key.',
                    type => 'string',
                    optional => 1,
                },
                'allowed-ips' => {
                    description =>
                        "The allowed IPs for this neighbor, omitted if there are none"
                        . " (WireGuard only)",
                    type => 'string',
                    format_description => 'Comma-separated list of CIDRs.',
                    optional => 1,
                },
                'latest-handshake' => {
                    description =>
                        "UNIX Timestamp of the last successful handshake, omitted if no handshake"
                        . " happened yet (WireGuard only)",
                    type => 'number',
                    optional => 1,
                },
                'bytes-rx' => {
                    description =>
                        "The number of bytes received from this neighbor (WireGuard only)",
                    type => 'number',
                    optional => 1,
                },
                'bytes-tx' => {
                    description =>
                        "The number of bytes transmitted to this neighbor (WireGuard only)",
                    type => 'number',
                    optional => 1,
                },
                'persistent-keepalive' => {
                    description =>
                        "The currently used persistent keepalive interval for this neighbor in"
                        . " seconds, omitted if disabled (WireGuard only)",
                    type => 'number',
                    optional => 1,
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
    description => "Get all interfaces for a fabric, empty if this node is not part of it.",
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
                        "The type of this interface in the fabric (e.g. Point-to-Point, Broadcast, ..)."
                        . " Omitted for WireGuard if the interface is missing or is not a WireGuard"
                        . " interface.",
                    type => 'string',
                    optional => 1,
                },
                state => {
                    description => "The current state of the interface.",
                    type => 'string',
                },
                'public-key' => {
                    description => "The public key of the interface, omitted if WireGuard does"
                        . " not report one (WireGuard only).",
                    format_description => 'Base64-encoded Curve 25519 public key.',
                    type => 'string',
                    optional => 1,
                },
                'listen-port' => {
                    description => "The listen port of the interface, omitted if WireGuard does"
                        . " not report the interface (WireGuard only).",
                    type => 'number',
                    optional => 1,
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
