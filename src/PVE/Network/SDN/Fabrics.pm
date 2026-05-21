package PVE::Network::SDN::Fabrics;

use strict;
use warnings;

use Socket qw(inet_pton AF_INET6);

use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file cfs_write_file);
use PVE::JSONSchema qw(get_standard_option);
use PVE::INotify;

use PVE::RS::SDN;
use PVE::RS::SDN::Fabrics;
use PVE::RS::SDN::PrefixLists;

PVE::JSONSchema::register_format(
    'pve-sdn-fabric-id',
    sub {
        my ($id, $noerr) = @_;

        if ($id !~ m/^[a-zA-Z0-9][a-zA-Z0-9-]{0,6}[a-zA-Z0-9]?$/i) {
            return undef if $noerr;
            die "Fabric ID '$id' contains illegal characters\n";
        }

        return $id;
    },
);

PVE::JSONSchema::register_standard_option(
    'pve-sdn-fabric-id',
    {
        description => "Identifier for SDN fabrics",
        type => 'string',
        format => 'pve-sdn-fabric-id',
        pattern => '[a-zA-Z0-9][a-zA-Z0-9-]{0,6}[a-zA-Z0-9]',
        minLength => 2,
        maxLength => 8,
    },
);

PVE::JSONSchema::register_standard_option(
    'pve-sdn-fabric-node-id',
    {
        description => "Identifier for nodes in an SDN fabric",
        type => 'string',
        format => 'pve-node',
    },
);

PVE::JSONSchema::register_standard_option(
    'pve-sdn-fabric-protocol',
    {
        description => "Type of configuration entry in an SDN Fabric section config",
        type => 'string',
        enum => ['openfabric', 'ospf', 'wireguard', 'bgp'],
    },
);

PVE::JSONSchema::register_format(
    'pve-sdn-wireguard-iface-name',
    sub {
        my ($name, $noerr) = @_;

        if ($name !~ m/^[a-zA-Z0-9][a-zA-Z0-9-]{0,6}[a-zA-Z0-9]?$/) {
            return undef if $noerr;
            die "WireGuard interface name '$name' contains illegal characters"
                . " or exceeds the eight character limit\n";
        }

        return $name;
    },
);

PVE::JSONSchema::register_format(
    'pve-sdn-fabric-wireguard-interface',
    {
        name => {
            type => 'string',
            format => 'pve-sdn-wireguard-iface-name',
            description => 'Name of the network interface',
        },
        public_key => {
            type => 'string',
            description => 'The public key of this interface',
            optional => 1,
        },
        ip => {
            type => 'string',
            format => 'CIDRv4',
            description => 'IPv4 address for this node',
            optional => 1,
        },
        ip6 => {
            type => 'string',
            format => 'CIDRv6',
            description => 'IPv6 address for this node',
            optional => 1,
        },
        listen_port => {
            type => 'number',
            description => 'Port to listen on for WireGuard traffic.',
            optional => 1,
            minimum => 1,
            maximum => 65535,
        },
    },
);

cfs_register_file(
    'sdn/fabrics.cfg', \&parse_fabrics_config, \&write_fabrics_config,
);

sub parse_fabrics_config {
    my ($filename, $raw) = @_;
    return migrate_legacy_wireguard_endpoints($raw // '');
}

sub write_fabrics_config {
    my ($filename, $config) = @_;
    return $config // '';
}

# FIXME: remove with PVE 10
#
# WireGuard fabrics from libpve-network-perl 1.5.0 stored a port-less endpoint
# and derived the port from the interface's listen_port; the endpoint is now a
# full host:port. On read, append the node's listen port to such legacy
# node-level endpoints (a bare IPv6 is bracketed). A port-less per-peer
# endpoint override cannot be expressed anymore and its target port is not
# available here, so it is dropped - the peer then falls back to the
# referenced node's (migrated) endpoint. Values already carrying a port, and
# external nodes (no interface, no port), are left for the strict parser.
sub migrate_legacy_wireguard_endpoints {
    my ($raw) = @_;

    return $raw if !length($raw // '');
    return $raw if $raw !~ /^wireguard_node:/m;

    # a port-less endpoint is a colon-free bare IPv4/hostname or a bare IPv6
    my $is_portless = sub { $_[0] !~ /:/ || defined(inet_pton(AF_INET6, $_[0])) };

    my @lines = split(/\n/, $raw, -1);

    my ($endpoint_idx, $host, $listen_port, $in_wg_node);
    my $flush = sub {
        if (defined($endpoint_idx) && defined($listen_port)) {
            $host = "[$host]" if defined(inet_pton(AF_INET6, $host));
            $lines[$endpoint_idx] =~ s/\S+$/$host:$listen_port/;
        }
        ($endpoint_idx, $host, $listen_port) = (undef, undef, undef);
    };

    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /^\S/) { # section header: only act on wireguard nodes
            $flush->();
            $in_wg_node = $lines[$i] =~ /^wireguard_node:/;
        } elsif (!$in_wg_node) {
            next;
        } elsif ($lines[$i] =~ /^\s+endpoint\s+(\S+)$/) {
            my $value = $1;
            ($endpoint_idx, $host) = ($i, $value) if $is_portless->($value);
        } elsif ($lines[$i] =~ /^(\s+peers\s+)(\S.*)$/) {
            my ($prefix, $props) = ($1, $2);
            if (my ($value) = $props =~ /(?:^|,)endpoint=([^,]+)/) {
                $props = join(',', grep { $_ ne "endpoint=$value" } split(/,/, $props))
                    if $is_portless->($value);
                $lines[$i] = "$prefix$props";
            }
        } elsif ($lines[$i] =~ /^\s+interfaces\s+\S/) {
            my ($port) = $lines[$i] =~ /(?:^|,)listen_port=(\d+)/;
            $listen_port //= $port;
        }
    }
    $flush->();

    return join("\n", @lines);
}

sub config {
    my ($running) = @_;

    if ($running) {
        my $running_config = PVE::Network::SDN::running_config();

        # if the config hasn't yet been applied after the introduction of
        # fabrics then the key does not exist in the running config so we
        # default to an empty hash
        my $fabrics_config = $running_config->{fabrics}->{ids} // {};
        return PVE::RS::SDN::Fabrics->running_config($fabrics_config);
    }

    my $fabrics_config = cfs_read_file("sdn/fabrics.cfg");
    return PVE::RS::SDN::Fabrics->config($fabrics_config);
}

sub write_config {
    my ($config) = @_;
    cfs_write_file("sdn/fabrics.cfg", $config->to_raw(), 1);
}

sub get_frr_daemon_status {
    my ($fabric_config) = @_;

    my $daemon_status = {};
    my $nodename = PVE::INotify::nodename();

    my $enabled_daemons = $fabric_config->enabled_daemons($nodename);

    for my $daemon (@$enabled_daemons) {
        $daemon_status->{$daemon} = 1;
    }

    return $daemon_status;
}

sub generate_etc_network_config {
    my ($running_cfg) = @_;

    my $nodename = PVE::INotify::nodename();
    # if the config hasn't yet been applied after the introduction of
    # fabrics then the key does not exist in the running config so we
    # default to an empty hash
    my $fabrics_config = $running_cfg->{fabrics}->{ids} // {};
    my $fabric_object = PVE::RS::SDN::Fabrics->running_config($fabrics_config);

    return $fabric_object->get_interfaces_etc_network_config($nodename);
}

sub node_properties {
    my ($update) = @_;

    my $properties = {
        fabric_id => get_standard_option('pve-sdn-fabric-id'),
        node_id => get_standard_option('pve-sdn-fabric-node-id'),
        protocol => get_standard_option('pve-sdn-fabric-protocol'),
        digest => get_standard_option('pve-config-digest'),
        'lock-token' => get_standard_option('pve-sdn-lock-token'),
        ip => {
            type => 'string',
            format => 'ipv4',
            description => 'IPv4 address for this node',
            optional => 1,
        },
        ip6 => {
            type => 'string',
            format => 'ipv6',
            description => 'IPv6 address for this node',
            optional => 1,
        },
        interfaces => {
            # coerce this value into an array before parsing (oneOf workaround)
            type => 'array',
            'type-property' => 'protocol',
            oneOf => [
                {
                    type => 'array',
                    'instance-types' => ['openfabric'],
                    items => {
                        type => 'string',
                        format => {
                            name => {
                                type => 'string',
                                format => 'pve-iface',
                                description => 'Name of the network interface',
                            },
                            hello_multiplier => {
                                type => 'integer',
                                description => 'The hello_multiplier property of the interface',
                                optional => 1,
                                minimum => 2,
                                maximum => 100,
                            },
                            ip => {
                                type => 'string',
                                format => 'CIDRv4',
                                description => 'IPv4 address for this node',
                                optional => 1,
                            },
                            ip6 => {
                                type => 'string',
                                format => 'CIDRv6',
                                description => 'IPv6 address for this node',
                                optional => 1,
                            },
                        },
                    },
                    description => 'OpenFabric network interface',
                    optional => 1,
                },
                {
                    type => 'array',
                    'instance-types' => ['ospf'],
                    items => {
                        type => 'string',
                        format => {
                            name => {
                                type => 'string',
                                format => 'pve-iface',
                                description => 'Name of the network interface',
                            },
                            network_type => {
                                type => 'string',
                                description => 'Network Type of the OSPF interface',
                                enum => [
                                    'broadcast',
                                    'non-broadcast',
                                    'point-to-multipoint',
                                    'point-to-point',
                                ],
                                optional => 1,
                            },
                            ip => {
                                type => 'string',
                                format => 'CIDRv4',
                                description => 'IPv4 address for this node',
                                optional => 1,
                            },
                        },
                    },
                    description => 'OSPF network interface',
                    optional => 1,
                },
                {
                    type => 'array',
                    'instance-types' => ['wireguard'],
                    items => {
                        description => "WireGuard network interface",
                        type => 'string',
                        format => 'pve-sdn-fabric-wireguard-interface',
                    },
                    description => 'List of WireGuard network interfaces for this node.',
                    optional => 1,
                },
                {
                    'instance-types' => ['bgp'],
                    items => {
                        type => 'string',
                        format => {
                            name => {
                                type => 'string',
                                format => 'pve-iface',
                                description => 'Name of the network interface',
                            },
                        },
                    },
                    description => 'BGP network interface',
                    optional => 1,
                },
            ],
        },
        public_key => {
            'type-property' => 'protocol',
            'instance-types' => ['wireguard'],
            description => 'The public key for the external node.',
            type => 'string',
            optional => 1,
        },
        role => {
            'type-property' => 'protocol',
            'instance-types' => ['wireguard'],
            description => 'The role of this node in the WireGuard fabric.',
            type => 'string',
            enum => ['internal', 'external'],
            optional => 1,
        },
        endpoint => {
            'type-property' => 'protocol',
            'instance-types' => ['wireguard'],
            description => 'The endpoint used for connecting to this node.',
            optional => 1,
            type => 'string',
        },
        allowed_ips => {
            'type-property' => 'protocol',
            'instance-types' => ['wireguard'],
            type => 'array',
            optional => 1,
            description =>
                'A list of IPs that are routable via this node in the WireGuard fabric.',
            items => {
                type => 'string',
                format => 'FullRangeCIDR',
            },
        },
        peers => {
            'type-property' => 'protocol',
            'instance-types' => ['wireguard'],
            optional => 1,
            type => 'array',
            items => {
                type => 'string',
                format => {
                    type => {
                        type => 'string',
                        enum => ['internal', 'external'],
                    },
                    node => {
                        description =>
                            'The name of the referenced node section (the external node or the internal peer node).',
                        type => 'string',
                    },
                    node_iface => {
                        description => 'The interface of the other node, if it is internal',
                        type => 'string',
                        optional => 1,
                    },
                    iface => {
                        description =>
                            'The interface of this node that uses this peer definition.',
                        type => 'string',
                    },
                    endpoint => {
                        description =>
                            'Override for the endpoint settings in the node section.',
                        optional => 1,
                        type => 'string',
                    },
                    skip_route_generation => {
                        description =>
                            'Whether routes for the allowed IPs should be created in the kernel routing table.',
                        optional => 1,
                        default => 0,
                        type => 'boolean',
                    },
                },
            },
        },
    };

    if ($update) {
        $properties->{delete} = {
            # coerce this value into an array before parsing (oneOf workaround)
            type => 'array',
            'type-property' => 'protocol',
            oneOf => [
                {
                    type => 'array',
                    'instance-types' => ['bgp'],
                    items => {
                        type => 'string',
                        enum => ['interfaces', 'ip', 'ip6'],
                    },
                    optional => 1,
                },
                {
                    type => 'array',
                    'instance-types' => ['openfabric', 'ospf'],
                    items => {
                        type => 'string',
                        enum => ['interfaces', 'ip', 'ip6'],
                    },
                    optional => 1,
                },
                {
                    type => 'array',
                    'instance-types' => ['wireguard'],
                    items => {
                        type => 'string',
                        enum => ['allowed_ips', 'endpoint', 'interfaces', 'ip', 'ip6', 'peers'],
                    },
                    optional => 1,
                },
            ],
        };
    }

    return $properties;
}

sub fabric_properties {
    my ($update) = @_;

    my $properties = {
        id => get_standard_option('pve-sdn-fabric-id'),
        protocol => get_standard_option('pve-sdn-fabric-protocol'),
        digest => get_standard_option('pve-config-digest'),
        'lock-token' => get_standard_option('pve-sdn-lock-token'),
        ip_prefix => {
            type => 'string',
            format => 'CIDR',
            description => 'The IP prefix for Node IPs',
            optional => 1,
        },
        ip6_prefix => {
            type => 'string',
            format => 'CIDR',
            description => 'The IP prefix for Node IPs',
            optional => 1,
        },
        hello_interval => {
            type => 'number',
            'type-property' => 'protocol',
            'instance-types' => ['openfabric'],
            description => 'The hello_interval property for Openfabric',
            optional => 1,
            minimum => 1,
            maximum => 600,
        },
        csnp_interval => {
            type => 'number',
            'type-property' => 'protocol',
            'instance-types' => ['openfabric'],
            description => 'The csnp_interval property for Openfabric',
            optional => 1,
            minimum => 1,
            maximum => 600,
        },
        area => {
            type => 'string',
            'type-property' => 'protocol',
            'instance-types' => ['ospf'],
            description =>
                'OSPF area. Either a IPv4 address or a 32-bit number. Gets validated in rust.',
            optional => 1,
        },
        route_filter => {
            type => 'string',
            format => 'pve-sdn-prefix-list-id',
            'type-property' => 'protocol',
            'instance-types' => ['ospf', 'openfabric'],
            description =>
                'A prefix list that should be used for filtering routes that are to be installed into the kernel routing table',
            optional => 1,
        },
        persistent_keepalive => {
            type => 'number',
            'type-property' => 'protocol',
            'instance-types' => ['wireguard'],
            description => 'A seconds interval, between 1 and 65535 inclusive, of how often to'
                . ' send an authenticated empty packet to the peer for the purpose of keeping a'
                . ' stateful firewall or NAT mapping valid persistently. For example, if the'
                . ' interface very rarely sends traffic, but it might at anytime receive traffic'
                . ' from another node, and it is behind NAT, the interface might benefit from'
                . ' having a persistent keepalive interval of 25 seconds. If unset or set to 0, it'
                . ' is turned off',
            optional => 1,
            minimum => 0,
            maximum => 65535,
        },
        redistribute => {
            # coerce this value into an array before parsing (oneOf workaround)
            type => 'array',
            'type-property' => 'protocol',
            oneOf => [
                {
                    type => 'array',
                    'instance-types' => ['ospf'],
                    items => {
                        type => 'string',
                        format => {
                            source => {
                                type => 'string',
                                description =>
                                    'The protocol from which to redistribute routes from.',
                                enum => [
                                    'bgp', 'connected', 'kernel', 'static',
                                ],
                            },
                            'route-map' => {
                                type => 'string',
                                format => 'pve-sdn-route-map-id',
                                description =>
                                    'Route map to filter or transform redistributed routes from this source.',
                                optional => 1,
                            },
                        },
                    },
                    optional => 1,
                },
                {
                    type => 'array',
                    'instance-types' => ['bgp'],
                    items => {
                        type => 'string',
                        format => {
                            source => {
                                type => 'string',
                                description =>
                                    'The protocol from which to redistribute routes from.',
                                enum => [
                                    'connected', 'kernel', 'ospf', 'static',
                                ],
                            },
                            'route-map' => {
                                type => 'string',
                                format => 'pve-sdn-route-map-id',
                                description =>
                                    'Route map to filter or transform redistributed routes from this source.',
                                optional => 1,
                            },
                        },
                    },
                    optional => 1,
                },
            ],
        },
    };

    if ($update) {
        $properties->{delete} = {
            # coerce this value into an array before parsing (oneOf workaround)
            type => 'array',
            'type-property' => 'protocol',
            oneOf => [
                {
                    type => 'array',
                    'instance-types' => ['openfabric'],
                    items => {
                        type => 'string',
                        enum => ['hello_interval', 'csnp_interval', 'route_filter'],
                    },
                    optional => 1,
                },
                {
                    type => 'array',
                    'instance-types' => ['bgp'],
                    items => {
                        type => 'string',
                        enum =>
                            ['redistribute', 'route_filter', 'route_map_in', 'route_map_out'],
                    },
                    optional => 1,
                },
                {
                    type => 'array',
                    'instance-types' => ['ospf'],
                    items => {
                        type => 'string',
                        enum => ['area', 'redistribute', 'route_filter'],
                    },
                    optional => 1,
                },
                {
                    type => 'array',
                    'instance-types' => ['wireguard'],
                    items => {
                        type => 'string',
                        enum => ['persistent_keepalive'],
                    },
                    optional => 1,
                },
            ],
        };
    }

    return $properties;
}

1;
