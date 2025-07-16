package PVE::Network::SDN::Fabrics;

use strict;
use warnings;

use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file cfs_write_file);
use PVE::JSONSchema qw(get_standard_option);
use PVE::INotify;
use PVE::RS::SDN::Fabrics;

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
        enum => ['openfabric', 'ospf'],
    },
);

cfs_register_file(
    'sdn/fabrics.cfg', \&parse_fabrics_config, \&write_fabrics_config,
);

sub parse_fabrics_config {
    my ($filename, $raw) = @_;
    return $raw // '';
}

sub write_fabrics_config {
    my ($filename, $config) = @_;
    return $config // '';
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

sub generate_frr_raw_config {
    my ($fabric_config) = @_;

    my @raw_config = ();

    my $nodename = PVE::INotify::nodename();

    my $frr_config = $fabric_config->get_frr_raw_config($nodename);
    push @raw_config, @$frr_config if @$frr_config;

    return \@raw_config;
}

sub generate_etc_network_config {
    my $nodename = PVE::INotify::nodename();
    my $fabric_config = PVE::Network::SDN::Fabrics::config(1);

    return $fabric_config->get_interfaces_etc_network_config($nodename);
}

sub node_properties {
    my ($update) = @_;

    my $properties = {
        fabric_id => get_standard_option('pve-sdn-fabric-id'),
        node_id => get_standard_option('pve-sdn-fabric-node-id'),
        protocol => get_standard_option('pve-sdn-fabric-protocol'),
        digest => get_standard_option('pve-config-digest'),
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
            ],
        },
    };

    if ($update) {
        $properties->{delete} = {
            type => 'array',
            items => {
                type => 'string',
                enum => ['interfaces', 'ip', 'ip6'],
            },
            optional => 1,
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
                        enum => ['hello_interval', 'csnp_interval'],
                    },
                    optional => 1,
                },
                {
                    type => 'array',
                    'instance-types' => ['ospf'],
                    items => {
                        type => 'string',
                        enum => ['area'],
                    },
                    optional => 1,
                },
            ],
        };
    }

    return $properties;
}

1;
