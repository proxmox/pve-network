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

__PACKAGE__->register_method({
    name => 'bridges',
    path => 'bridges',
    proxyto => 'node',
    method => 'GET',
    protected => 1,
    description =>
        "Get a list of all bridges (vnets) that are part of a zone, as well as the ports that are members of that bridge.",
    permissions => {
        check => ['perm', '/sdn/zones/{zone}', ['SDN.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            zone => {
                type => 'string',
                description => 'zone name or "localnetwork"',
            },
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            description => 'List of bridges contained in the SDN zone.',
            type => 'object',
            properties => {
                name => {
                    description => 'Name of the bridge.',
                    type => 'string',
                },
                vlan_filtering => {
                    description =>
                        'Whether VLAN filtering is enabled for this bridge (= VLAN-aware).',
                    type => 'string',
                },
                ports => {
                    description => 'All ports that are members of the bridge',
                    type => 'array',
                    items => {
                        description => 'Information about bridge ports.',
                        type => 'object',
                        properties => {
                            name => {
                                description => 'The name of the bridge port.',
                                type => 'string',
                            },
                            vmid => {
                                description =>
                                    'The ID of the guest that this interface belongs to.',
                                type => 'number',
                                optional => 1,
                            },
                            index => {
                                description =>
                                    'The index of the guests network device that this interface belongs to.',
                                type => 'string',
                                optional => 1,
                            },
                            primary_vlan => {
                                description =>
                                    'The primary VLAN configured for the port of this bridge (= PVID). Only for VLAN-aware bridges.',
                                type => 'number',
                                optional => 1,
                            },
                            vlans => {
                                description =>
                                    'A list of VLANs and VLAN ranges that are allowed for this bridge port in addition to the primary VLAN. Only for VLAN-aware bridges.',
                                type => 'array',
                                items => {
                                    description =>
                                        'A single VLAN (123) or a VLAN range (234-435).',
                                    type => 'string',
                                },
                                optional => 1,
                            },
                        },
                    },
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $zone_id = extract_param($param, 'zone');
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my @bridges_in_zone;
        if ($zone_id eq 'localnetwork') {
            my $interface_config = PVE::INotify::read_file('interfaces', 1);
            my $interfaces = $interface_config->{data}->{ifaces};

            @bridges_in_zone =
                grep { $interfaces->{$_}->{type} eq 'bridge' } keys $interfaces->%*;
        } else {
            my $zone = PVE::Network::SDN::Zones::get_zone($zone_id, 1);

            raise_param_exc({
                zone => "zone does not exist",
            })
                if !$zone;

            my $vnet_cfg = PVE::Network::SDN::Vnets::config(1);
            @bridges_in_zone =
                grep { $vnet_cfg->{ids}->{$_}->{zone} eq $zone_id } keys $vnet_cfg->{ids}->%*;
        }

        my $ip_details = PVE::Network::ip_link_details();
        my $vlan_information = PVE::IPRoute2::get_vlan_information();

        my $result = {};
        for my $bridge_name (@bridges_in_zone) {
            next
                if !$rpcenv->check_any(
                    $authuser,
                    "/sdn/zones/$zone_id/$bridge_name",
                    ['SDN.Audit', 'SDN.Allocate'],
                    1,
                );

            my $ip_link = $ip_details->{$bridge_name};

            $result->{$bridge_name} = {
                name => $bridge_name,
                vlan_filtering => $ip_link->{linkinfo}->{info_data}->{vlan_filtering},
                ports => [],
            };
        }

        for my $interface (values $ip_details->%*) {
            if (PVE::IPRoute2::ip_link_is_bridge_member($interface)) {
                my $master = $interface->{master};

                # avoid potential TOCTOU by just skipping over the interface,
                # if we didn't get the master from 'ip link'
                next if !defined($result->{$master});

                my $ifname = $interface->{ifname};

                my $port = {
                    name => $ifname,
                };

                if ($ifname =~ m/^fwpr(\d+)p(\d+)$/) {
                    $port->{vmid} = $1;
                    $port->{index} = "net$2";
                } elsif ($ifname =~ m/^veth(\d+)i(\d+)$/) {
                    $port->{vmid} = $1;
                    $port->{index} = "net$2";
                } elsif ($ifname =~ m/^tap(\d+)i(\d+)$/) {
                    $port->{vmid} = $1;
                    $port->{index} = "net$2";
                }

                if ($result->{$master}->{vlan_filtering} == 1) {
                    $port->{vlans} = [];

                    for my $vlan ($vlan_information->{$ifname}->{vlans}->@*) {
                        if (grep { $_ eq 'PVID' } $vlan->{flags}->@*) {
                            $port->{primary_vlan} = $vlan->{vlan};
                        } elsif ($vlan->{vlan} && $vlan->{vlanEnd}) {
                            push $port->{vlans}->@*, "$vlan->{vlan}-$vlan->{vlanEnd}";
                        } elsif ($vlan->{vlan}) {
                            push $port->{vlans}->@*, "$vlan->{vlan}";
                        }
                    }
                }

                push $result->{$master}->{ports}->@*, $port;
            }
        }

        my @result = values $result->%*;
        return \@result;
    },
});

__PACKAGE__->register_method({
    name => 'ip-vrf',
    path => 'ip-vrf',
    proxyto => 'node',
    method => 'GET',
    protected => 1,
    description => "Get the IP VRF of an EVPN zone.",
    permissions => {
        check => ['perm', '/sdn/zones/{zone}', ['SDN.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            zone => {
                type => 'string',
                description => 'Name of an EVPN zone.',
            },
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        description => 'All entries in the VRF table of zone {zone} of the node.'
            . 'This does not include /32 routes for guests on this host,'
            . 'since they are handled via the respective vnet bridge directly.',
        type => 'array',
        items => {
            type => 'object',
            properties => {
                ip => {
                    type => 'string',
                    format => 'CIDR',
                    description => 'The CIDR of the route table entry.',
                },
                metric => {
                    type => 'integer',
                    description => 'This route\'s metric.',
                },
                protocol => {
                    type => 'string',
                    description => 'The protocol where this route was learned from (e.g. BGP).',
                },
                'nexthops' => {
                    type => 'array',
                    description => 'A list of nexthops for the route table entry.',
                    items => {
                        type => 'string',
                        description => 'the interface name or ip address of the next hop',
                    },
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $zone_id = extract_param($param, 'zone');
        my $zone = PVE::Network::SDN::Zones::get_zone($zone_id, 1);

        raise_param_exc({
            zone => "zone does not exist",
        })
            if !$zone;

        raise_param_exc({
            zone => "zone is not an EVPN zone",
        })
            if $zone->{type} ne 'evpn';

        my $node_id = extract_param($param, 'node');

        raise_param_exc({
            zone => "zone does not exist on node $node_id",
        })
            if defined($zone->{nodes}) && !grep { $_ eq $node_id } $zone->{nodes}->@*;

        return PVE::RS::SDN::Fabrics::l3vpn_routes($zone_id);
    },
});

1;
