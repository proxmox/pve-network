package PVE::API2::Network::SDN::Zones;

use strict;
use warnings;

use Storable qw(dclone);

use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Exception qw(raise raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);

use PVE::Network::SDN::Dns;
use PVE::Network::SDN::Subnets;
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN;

use PVE::Network::SDN::Zones::EvpnPlugin;
use PVE::Network::SDN::Zones::FaucetPlugin;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Network::SDN::Zones::QinQPlugin;
use PVE::Network::SDN::Zones::SimplePlugin;
use PVE::Network::SDN::Zones::VlanPlugin;
use PVE::Network::SDN::Zones::VxlanPlugin;
use PVE::Network::SDN::Zones;

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

my $sdn_zones_type_enum = PVE::Network::SDN::Zones::Plugin->lookup_types();

my $api_sdn_zones_config = sub {
    my ($cfg, $id) = @_;

    my $scfg = dclone(PVE::Network::SDN::Zones::sdn_zones_config($cfg, $id));
    $scfg->{zone} = $id;
    $scfg->{digest} = $cfg->{digest};

    if ($scfg->{nodes}) {
        $scfg->{nodes} =
            PVE::Network::SDN::encode_value($scfg->{type}, 'nodes', $scfg->{nodes});
    }

    if ($scfg->{exitnodes}) {
        $scfg->{exitnodes} =
            PVE::Network::SDN::encode_value($scfg->{type}, 'exitnodes', $scfg->{exitnodes});
    }

    my $pending = $scfg->{pending};
    if ($pending->{nodes}) {
        $pending->{nodes} =
            PVE::Network::SDN::encode_value($scfg->{type}, 'nodes', $pending->{nodes});
    }

    if ($pending->{exitnodes}) {
        $pending->{exitnodes} =
            PVE::Network::SDN::encode_value($scfg->{type}, 'exitnodes', $pending->{exitnodes});
    }

    return $scfg;
};

my $ZONE_PROPERTIES = {
    mtu => {
        type => 'integer',
        optional => 1,
        description => 'MTU of the zone, will be used for the created VNet bridges.',
    },
    dns => {
        type => 'string',
        optional => 1,
        description => 'ID of the DNS server for this zone.',
    },
    reversedns => {
        type => 'string',
        optional => 1,
        description => 'ID of the reverse DNS server for this zone.',
    },
    dnszone => {
        type => 'string',
        optional => 1,
        description => 'Domain name for this zone.',
    },
    ipam => {
        type => 'string',
        optional => 1,
        description => 'ID of the IPAM for this zone.',
    },
    dhcp => {
        type => 'string',
        enum => ['dnsmasq'],
        optional => 1,
        description => 'Name of DHCP server backend for this zone.',
    },
    'rt-import' => {
        type => 'string',
        optional => 1,
        description =>
            'Comma-separated list of Route Targets that should be imported into the VRF of the zone. EVPN zone only.',
        format => 'pve-sdn-bgp-rt-list',
    },
    'vrf-vxlan' => {
        type => 'integer',
        optional => 1,
        description => 'VNI for the zone VRF. EVPN zone only.',
        minimum => 1,
        maximum => 16777215,
    },
    mac => {
        type => 'string',
        optional => 1,
        description => 'MAC address of the anycast router for this zone.',
    },
    controller => {
        type => 'string',
        optional => 1,
        description => 'ID of the controller for this zone. EVPN zone only.',
    },
    nodes => {
        type => 'string',
        optional => 1,
        description => 'Nodes where this zone should be created.',
    },
    'exitnodes' => get_standard_option(
        'pve-node-list',
        {
            description =>
                "List of PVE Nodes that should act as exit node for this zone. EVPN zone only.",
            optional => 1,
        },
    ),
    'exitnodes-local-routing' => {
        type => 'boolean',
        description =>
            "Create routes on the exit nodes, so they can connect to EVPN guests. EVPN zone only.",
        optional => 1,
    },
    'exitnodes-primary' => get_standard_option(
        'pve-node',
        {
            description => "Force traffic through this exitnode first. EVPN zone only.",
            optional => 1,
        },
    ),
    'advertise-subnets' => {
        type => 'boolean',
        description =>
            "Advertise IP prefixes (Type-5 routes) instead of MAC/IP pairs (Type-2 routes). EVPN zone only.",
        optional => 1,
    },
    'disable-arp-nd-suppression' => {
        type => 'boolean',
        description =>
            "Suppress IPv4 ARP && IPv6 Neighbour Discovery messages. EVPN zone only.",
        optional => 1,
    },
    'rt-import' => {
        type => 'string',
        description =>
            "Route-Targets that should be imported into the VRF of this zone via BGP. EVPN zone only.",
        optional => 1,
        format => 'pve-sdn-bgp-rt-list',
    },
    tag => {
        type => 'integer',
        minimum => 0,
        optional => 1,
        description => "Service-VLAN Tag (outer VLAN). QinQ zone only",
    },
    'vlan-protocol' => {
        type => 'string',
        enum => ['802.1q', '802.1ad'],
        default => '802.1q',
        optional => 1,
        description => "VLAN protocol for the creation of the QinQ zone. QinQ zone only.",
    },
    'peers' => {
        description =>
            "Comma-separated list of peers, that are part of the VXLAN zone. Usually the IPs of the nodes. VXLAN zone only.",
        type => 'string',
        format => 'ip-list',
        optional => 1,
    },
    'vxlan-port' => {
        description =>
            "UDP port that should be used for the VXLAN tunnel (default 4789). VXLAN zone only.",
        minimum => 1,
        maximum => 65536,
        type => 'integer',
        optional => 1,
        default => 4789,
    },
    'bridge' => {
        type => 'string',
        description => 'the bridge for which VLANs should be managed. VLAN & QinQ zone only.',
        optional => 1,
    },
    'bridge-disable-mac-learning' => {
        type => 'boolean',
        description => "Disable auto mac learning. VLAN zone only.",
        optional => 1,
    },
};

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SDN zones index.",
    permissions => {
        description =>
            "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/sdn/zones/<zone>'",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            type => {
                description => "Only list SDN zones of specific type",
                type => 'string',
                enum => $sdn_zones_type_enum,
                optional => 1,
            },
            running => {
                type => 'boolean',
                optional => 1,
                description => "Display running config.",
            },
            pending => {
                type => 'boolean',
                optional => 1,
                description => "Display pending config.",
            },
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                digest => {
                    type => 'string',
                    description => 'Digest of the controller section.',
                    optional => 1,
                },
                state => get_standard_option('pve-sdn-config-state'),
                zone => {
                    type => 'string',
                    description => 'Name of the zone.',
                },
                type => {
                    type => 'string',
                    description => 'Type of the zone.',
                    enum => PVE::Network::SDN::Zones::Plugin->lookup_types(),
                },
                pending => {
                    type => 'object',
                    description =>
                        'Changes that have not yet been applied to the running configuration.',
                    optional => 1,
                    properties => $ZONE_PROPERTIES,
                },
                %$ZONE_PROPERTIES,
            },
        },
        links => [{ rel => 'child', href => "{zone}" }],
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $cfg = {};
        if ($param->{pending}) {
            my $running_cfg = PVE::Network::SDN::running_config();
            my $config = PVE::Network::SDN::Zones::config();
            $cfg = PVE::Network::SDN::pending_config($running_cfg, $config, 'zones');
        } elsif ($param->{running}) {
            my $running_cfg = PVE::Network::SDN::running_config();
            $cfg = $running_cfg->{zones};
        } else {
            $cfg = PVE::Network::SDN::Zones::config();
        }

        my @sids = PVE::Network::SDN::Zones::sdn_zones_ids($cfg);
        my $res = [];
        for my $id (@sids) {
            my $privs = ['SDN.Audit', 'SDN.Allocate'];
            next if !$rpcenv->check_any($authuser, "/sdn/zones/$id", $privs, 1);

            my $scfg = &$api_sdn_zones_config($cfg, $id);
            next if $param->{type} && $param->{type} ne $scfg->{type};

            my $plugin_config = $cfg->{ids}->{$id};
            my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
            push @$res, $scfg;
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'read',
    path => '{zone}',
    method => 'GET',
    description => "Read sdn zone configuration.",
    permissions => {
        check => ['perm', '/sdn/zones/{zone}', ['SDN.Allocate']],
    },

    parameters => {
        additionalProperties => 0,
        properties => {
            zone => get_standard_option('pve-sdn-zone-id'),
            running => {
                type => 'boolean',
                optional => 1,
                description => "Display running config.",
            },
            pending => {
                type => 'boolean',
                optional => 1,
                description => "Display pending config.",
            },
        },
    },
    returns => {
        properties => {
            digest => {
                type => 'string',
                description => 'Digest of the controller section.',
                optional => 1,
            },
            state => get_standard_option('pve-sdn-config-state'),
            zone => {
                type => 'string',
                description => 'Name of the zone.',
            },
            type => {
                type => 'string',
                description => 'Type of the zone.',
                enum => PVE::Network::SDN::Zones::Plugin->lookup_types(),
            },
            pending => {
                type => 'object',
                description =>
                    'Changes that have not yet been applied to the running configuration.',
                optional => 1,
                properties => $ZONE_PROPERTIES,
            },
            %$ZONE_PROPERTIES,
        },
    },
    code => sub {
        my ($param) = @_;

        my $cfg = {};
        if ($param->{pending}) {
            my $running_cfg = PVE::Network::SDN::running_config();
            my $config = PVE::Network::SDN::Zones::config();
            $cfg = PVE::Network::SDN::pending_config($running_cfg, $config, 'zones');
        } elsif ($param->{running}) {
            my $running_cfg = PVE::Network::SDN::running_config();
            $cfg = $running_cfg->{zones};
        } else {
            $cfg = PVE::Network::SDN::Zones::config();
        }

        return &$api_sdn_zones_config($cfg, $param->{zone});
    },
});

sub create_etc_interfaces_sdn_dir {
    mkdir("/etc/pve/sdn");
}

__PACKAGE__->register_method({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new sdn zone object.",
    permissions => {
        check => ['perm', '/sdn/zones', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::Zones::Plugin->createSchema(
        undef,
        {
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
        },
    ),
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $type = extract_param($param, 'type');
        my $id = extract_param($param, 'zone');
        my $lock_token = extract_param($param, 'lock-token');

        my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($type);
        my $opts = $plugin->check_config($id, $param, 1, 1);

        PVE::Cluster::check_cfs_quorum();
        create_etc_interfaces_sdn_dir();

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $zone_cfg = PVE::Network::SDN::Zones::config();
                my $controller_cfg = PVE::Network::SDN::Controllers::config();
                my $dns_cfg = PVE::Network::SDN::Dns::config();

                my $scfg = undef;
                if ($scfg = PVE::Network::SDN::Zones::sdn_zones_config($zone_cfg, $id, 1)) {
                    die "sdn zone object ID '$id' already defined\n";
                }

                my $dnsserver = $opts->{dns};
                raise_param_exc({ dns => "$dnsserver don't exist" })
                    if $dnsserver && !$dns_cfg->{ids}->{$dnsserver};

                my $reversednsserver = $opts->{reversedns};
                raise_param_exc({ reversedns => "$reversednsserver don't exist" })
                    if $reversednsserver && !$dns_cfg->{ids}->{$reversednsserver};

                my $dnszone = $opts->{dnszone};
                raise_param_exc({ dnszone => "missing dns server" })
                    if $dnszone && !$dnsserver;

                my $ipam = $opts->{ipam};
                my $ipam_cfg = PVE::Network::SDN::Ipams::config();
                raise_param_exc({ ipam => "$ipam not existing" })
                    if $ipam && !$ipam_cfg->{ids}->{$ipam};

                $zone_cfg->{ids}->{$id} = $opts;
                $plugin->on_update_hook($id, $zone_cfg, $controller_cfg);

                PVE::Network::SDN::Zones::write_config($zone_cfg);

            },
            "create sdn zone object failed",
            $lock_token,
        );

        return;
    },
});

__PACKAGE__->register_method({
    name => 'update',
    protected => 1,
    path => '{zone}',
    method => 'PUT',
    description => "Update sdn zone object configuration.",
    permissions => {
        check => ['perm', '/sdn/zones/{zone}', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::Zones::Plugin->updateSchema(
        undef,
        {
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
        },
    ),
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $id = extract_param($param, 'zone');
        my $digest = extract_param($param, 'digest');
        my $delete = extract_param($param, 'delete');
        my $lock_token = extract_param($param, 'lock-token');

        if ($delete) {
            $delete = [PVE::Tools::split_list($delete)];
        }

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $zone_cfg = PVE::Network::SDN::Zones::config();
                my $controller_cfg = PVE::Network::SDN::Controllers::config();
                my $dns_cfg = PVE::Network::SDN::Dns::config();

                PVE::SectionConfig::assert_if_modified($zone_cfg, $digest);

                my $scfg = PVE::Network::SDN::Zones::sdn_zones_config($zone_cfg, $id);

                my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($scfg->{type});
                my $opts = $plugin->check_config($id, $param, 0, 1);

                my $old_ipam = $scfg->{ipam};

                if ($delete) {
                    my $options = $plugin->private()->{options}->{ $scfg->{type} };
                    PVE::SectionConfig::delete_from_config($scfg, $options, $opts, $delete);
                }

                $scfg->{$_} = $opts->{$_} for keys $opts->%*;

                my $new_ipam = $scfg->{ipam};
                if (!$new_ipam != !$old_ipam || (($new_ipam // '') ne ($old_ipam // ''))) {
                    # don't allow ipam change if subnet are defined for now, need to implement resync ipam content
                    my $subnets_cfg = PVE::Network::SDN::Subnets::config();
                    for my $subnetid (sort keys %{ $subnets_cfg->{ids} }) {
                        my $subnet =
                            PVE::Network::SDN::Subnets::sdn_subnets_config($subnets_cfg, $subnetid);
                        raise_param_exc(
                            {
                                ipam =>
                                    "can't change ipam if a subnet is already defined in this zone",
                            },
                        ) if $subnet->{zone} eq $id;
                    }
                }

                my $dnsserver = $opts->{dns};
                raise_param_exc({ dns => "$dnsserver don't exist" })
                    if $dnsserver && !$dns_cfg->{ids}->{$dnsserver};

                my $reversednsserver = $opts->{reversedns};
                raise_param_exc({ reversedns => "$reversednsserver don't exist" })
                    if $reversednsserver && !$dns_cfg->{ids}->{$reversednsserver};

                my $dnszone = $opts->{dnszone};
                raise_param_exc({ dnszone => "missing dns server" }) if $dnszone && !$dnsserver;

                my $ipam = $opts->{ipam};
                my $ipam_cfg = PVE::Network::SDN::Ipams::config();
                raise_param_exc({ ipam => "$ipam not existing" })
                    if $ipam && !$ipam_cfg->{ids}->{$ipam};

                $plugin->on_update_hook($id, $zone_cfg, $controller_cfg);

                PVE::Network::SDN::Zones::write_config($zone_cfg);

            },
            "update sdn zone object failed",
            $lock_token,
        );

        return;
    },
});

__PACKAGE__->register_method({
    name => 'delete',
    protected => 1,
    path => '{zone}',
    method => 'DELETE',
    description => "Delete sdn zone object configuration.",
    permissions => {
        check => ['perm', '/sdn/zones/{zone}', ['SDN.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            zone => get_standard_option(
                'pve-sdn-zone-id',
                {
                    completion => \&PVE::Network::SDN::Zones::complete_sdn_zones,
                },
            ),
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $id = extract_param($param, 'zone');
        my $lock_token = extract_param($param, 'lock-token');

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $cfg = PVE::Network::SDN::Zones::config();
                my $scfg = PVE::Network::SDN::Zones::sdn_zones_config($cfg, $id);

                my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($scfg->{type});
                my $vnet_cfg = PVE::Network::SDN::Vnets::config();

                $plugin->on_delete_hook($id, $vnet_cfg);

                delete $cfg->{ids}->{$id};

                PVE::Network::SDN::Zones::write_config($cfg);
            },
            "delete sdn zone object failed",
            $lock_token,
        );

        return;
    },
});

1;
