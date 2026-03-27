package PVE::Network::SDN::Controllers::EvpnPlugin;

use strict;
use warnings;

use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(run_command file_set_contents file_get_contents);
use PVE::RESTEnvironment qw(log_warn);

use PVE::Network::SDN::Controllers::Plugin;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Network::SDN::Fabrics;
use Net::IP;

use base('PVE::Network::SDN::Controllers::Plugin');

sub type {
    return 'evpn';
}

sub properties {
    return {
        asn => {
            type => 'integer',
            description => "autonomous system number",
            minimum => 0,
            maximum => 2**32 - 1,
        },
        fabric => {
            description => "SDN fabric to use as underlay for this EVPN controller.",
            type => 'string',
            format => 'pve-sdn-fabric-id',
        },
        peers => {
            description => "peers address list.",
            type => 'string',
            format => 'ip-list',
        },
    };
}

sub options {
    return {
        'asn' => { optional => 0 },
        'peers' => { optional => 1 },
        'fabric' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_frr_config {
    my ($class, $plugin_config, $controller_cfg, $id, $uplinks, $config) = @_;

    my $local_node = PVE::INotify::nodename();

    my @peers;
    my $asn = int($plugin_config->{asn});
    my $ebgp = undef;
    my $loopback = undef;
    my $autortas = undef;
    my $ifaceip = undef;
    my $routerid = undef;

    my $bgp_controller = find_bgp_controller($local_node, $controller_cfg);
    my $isis_controller = find_isis_controller($local_node, $controller_cfg);

    if ($plugin_config->{'fabric'}) {
        my $config = PVE::Network::SDN::Fabrics::config(1);

        my $fabric = eval { $config->get_fabric($plugin_config->{fabric}) };
        if ($@) {
            log_warn("could not configure EVPN controller $plugin_config->{id}: $@");
            return;
        }

        my $nodes = $config->list_nodes_fabric($plugin_config->{fabric});

        my $current_node = eval { $config->get_node($plugin_config->{fabric}, $local_node) };
        if ($@) {
            log_warn("could not configure EVPN controller $plugin_config->{id}: $@");
            return;
        }

        if (!$current_node->{ip}) {
            log_warn(
                "Node $local_node requires an IP in the fabric $fabric->{id} to configure the EVPN controller"
            );
            return;
        }

        for my $node_id (sort keys %$nodes) {
            my $node = $nodes->{$node_id};
            push @peers, $node->{ip} if $node->{ip};
        }

        $loopback = "dummy_$fabric->{id}";

        $ifaceip = $current_node->{ip};
        $routerid = $current_node->{ip};

    } elsif ($plugin_config->{'peers'}) {
        @peers = PVE::Tools::split_list($plugin_config->{'peers'});

        if ($bgp_controller) {
            $loopback = $bgp_controller->{loopback} if $bgp_controller->{loopback};
        } elsif ($isis_controller) {
            $loopback = $isis_controller->{loopback} if $isis_controller->{loopback};
        }

        ($ifaceip, my $interface) =
            PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers, $loopback);
        $routerid = PVE::Network::SDN::Controllers::Plugin::get_router_id($ifaceip, $interface);
    } else {
        log_warn("neither fabric nor peers configured for EVPN controller $plugin_config->{id}");
        return;
    }

    if ($bgp_controller) {
        $ebgp = 1 if $plugin_config->{'asn'} ne $bgp_controller->{asn};
        $asn = int($bgp_controller->{asn}) if $bgp_controller->{asn};
        $autortas = $plugin_config->{'asn'} if $ebgp;
    }

    return if !$asn || !$routerid;

    my $bgp_router = $config->{frr}->{bgp}->{vrf_router}->{'default'} //= {};

    # Initialize router if not already configured
    if (!keys %{$bgp_router}) {
        $bgp_router->{asn} = $asn;
        $bgp_router->{router_id} = $routerid;
        $bgp_router->{default_ipv4_unicast} = 0;
        $bgp_router->{hard_administrative_reset} = 0;
        $bgp_router->{graceful_restart_notification} = 0;
        $bgp_router->{coalesce_time} = 1000;
        $bgp_router->{neighbor_groups} = [];
        $bgp_router->{address_families} = {};
    }

    # Build VTEP neighbor group
    my @vtep_ips = grep { $_ ne $ifaceip } @peers;

    my $neighbor_group = {
        name => "VTEP",
        bfd => 1,
        remote_as => $ebgp ? "external" : $asn,
        ips => \@vtep_ips,
        interfaces => [],
    };
    $neighbor_group->{ebgp_multihop} = 10 if $ebgp && $loopback;
    $neighbor_group->{update_source} = $loopback if $loopback;

    push @{ $bgp_router->{neighbor_groups} }, $neighbor_group;

    # Configure l2vpn evpn address family
    $bgp_router->{address_families}->{l2vpn_evpn} //= {
        neighbors => [{
            name => "VTEP",
            route_map_in => 'MAP_VTEP_IN',
            route_map_out => 'MAP_VTEP_OUT',
        }],
        advertise_all_vni => 1,
    };

    $bgp_router->{address_families}->{l2vpn_evpn}->{autort_as} = $autortas if $autortas;

    my $routemap_in = { seq => 1, action => "permit" };
    my $routemap_out = { seq => 1, action => "permit" };

    push($config->{frr}->{routemaps}->{'MAP_VTEP_IN'}->@*, $routemap_in);
    push($config->{frr}->{routemaps}->{'MAP_VTEP_OUT'}->@*, $routemap_out);

    return $config;
}

sub generate_zone_frr_config {
    my ($class, $plugin_config, $controller, $controller_cfg, $id, $uplinks, $config) = @_;

    my $local_node = PVE::INotify::nodename();

    my $vrf = "vrf_$id";
    my $vrfvxlan = $plugin_config->{'vrf-vxlan'};
    my $exitnodes = $plugin_config->{'exitnodes'};
    my $exitnodes_primary = $plugin_config->{'exitnodes-primary'};
    my $advertisesubnets = $plugin_config->{'advertise-subnets'};
    my $exitnodes_local_routing = $plugin_config->{'exitnodes-local-routing'};
    my $rt_import;
    $rt_import = [PVE::Tools::split_list($plugin_config->{'rt-import'})]
        if $plugin_config->{'rt-import'};

    my $asn = $controller->{asn};

    my @peers;
    my $ebgp = undef;
    my $loopback = undef;
    my $ifaceip = undef;
    my $autortas = undef;
    my $routerid = undef;

    my $bgprouter = find_bgp_controller($local_node, $controller_cfg);
    my $isisrouter = find_isis_controller($local_node, $controller_cfg);

    if ($controller->{fabric}) {
        my $config = PVE::Network::SDN::Fabrics::config(1);

        my $fabric = eval { $config->get_fabric($controller->{fabric}) };
        if ($@) {
            log_warn("could not configure EVPN controller $controller->{id}: $@");
            return;
        }

        my $nodes = $config->list_nodes_fabric($controller->{fabric});

        my $current_node = eval { $config->get_node($controller->{fabric}, $local_node) };
        if ($@) {
            log_warn("could not configure EVPN controller $controller->{id}: $@");
            return;
        }

        if (!$current_node->{ip}) {
            log_warn(
                "Node $local_node requires an IP in the fabric $fabric->{id} to configure the EVPN controller"
            );
            return;
        }

        for my $node (values %$nodes) {
            push @peers, $node->{ip} if $node->{ip};
        }

        $loopback = "dummy_$fabric->{id}";

        $ifaceip = $current_node->{ip};
        $routerid = $current_node->{ip};

    } elsif ($controller->{peers}) {
        @peers = PVE::Tools::split_list($controller->{'peers'}) if $controller->{'peers'};

        if ($bgprouter) {
            $loopback = $bgprouter->{loopback} if $bgprouter->{loopback};
        } elsif ($isisrouter) {
            $loopback = $isisrouter->{loopback} if $isisrouter->{loopback};
        }

        ($ifaceip, my $interface) =
            PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers, $loopback);
        $routerid = PVE::Network::SDN::Controllers::Plugin::get_router_id($ifaceip, $interface);

    } else {
        log_warn("neither fabric nor peers configured for EVPN controller $controller->{id}");
        return;
    }

    if ($bgprouter) {
        $ebgp = 1 if $controller->{'asn'} ne $bgprouter->{asn};
        $asn = $bgprouter->{asn} if $bgprouter->{asn};
        $autortas = $controller->{'asn'} if $ebgp;
    }

    return if !$vrf || !$vrfvxlan || !$asn;

    my $is_gateway = $exitnodes->{$local_node};

    # Configure VRF
    my $vrf_router = $config->{frr}->{bgp}->{vrf_router}->{$vrf} //= {};
    $vrf_router->{asn} = $asn;
    $vrf_router->{router_id} = $routerid;
    $vrf_router->{hard_administrative_reset} = 0;
    $vrf_router->{graceful_restart_notification} = 0;

    my $bgp_vrf = $config->{frr}->{bgp}->{vrfs}->{$vrf} //= {};

    $bgp_vrf->{vni} = $vrfvxlan;
    $bgp_vrf->{ip_routes} = [];

    # Add null routes for other zones to avoid routing between nodes through exit nodes
    if ($is_gateway) {
        my $subnets = PVE::Network::SDN::Vnets::get_subnets();
        my $cidrs = {};
        foreach my $subnetid (sort keys %{$subnets}) {
            my $subnet = $subnets->{$subnetid};
            my $cidr = $subnet->{cidr};
            my $zone = $subnet->{zone};
            my ($ip, $mask) = split(/\//, $cidr);
            $cidrs->{$ip} = $mask if $zone ne $id;
        }

        my @sorted_ip =
            map { $_->[0] }
            sort { $a->[1] <=> $b->[1] }
            map { [$_, eval { Net::IP->new($_)->intip }] }
            keys $cidrs->%*;

        foreach my $ip (@sorted_ip) {
            my $is_ipv6 = Net::IP::ip_is_ipv6($ip);
            push @{ $bgp_vrf->{ip_routes} },
                {
                    is_ipv6 => $is_ipv6,
                    prefix => "$ip/$cidrs->{$ip}",
                    via => "null0",
                };
        }
    }

    # Configure VRF BGP router
    $vrf_router->{neighbor_groups} = [];
    $vrf_router->{address_families} = {};

    # Configure L2VPN EVPN address family with route targets
    if ($autortas) {
        $vrf_router->{address_families}->{l2vpn_evpn} //= {};
        $vrf_router->{address_families}->{l2vpn_evpn}->{route_targets} = {
            import => ["$autortas:$vrfvxlan"],
            export => ["$autortas:$vrfvxlan"],
        };
    }

    if ($is_gateway) {
        push(
            @{ $config->{frr}->{prefix_lists}->{only_default} },
            { seq => 1, action => 'permit', network => '0.0.0.0/0', is_ipv6 => 0 },
        ) if !defined($config->{frr}->{prefix_lists}->{only_default});
        push(
            @{ $config->{frr}->{prefix_lists}->{only_default_v6} },
            { seq => 1, action => 'permit', network => '::/0', is_ipv6 => 1 },
        ) if !defined($config->{frr}->{prefix_lists}->{only_default_v6});

        if (!$exitnodes_primary || $exitnodes_primary eq $local_node) {
            # Filter default route coming from other exit nodes on primary node
            my $routemap_config_v6 = {
                protocol_type => 'ipv6',
                match_type => 'address',
                value => { list_type => 'prefixlist', list_name => 'only_default_v6' },
            };
            my $routemap_v6 = { seq => 1, matches => [$routemap_config_v6], action => "deny" };
            unshift(
                @{ $config->{frr}->{routemaps}->{'MAP_VTEP_IN'} }, $routemap_v6,
            );

            my $routemap_config = {
                protocol_type => 'ip',
                match_type => 'address',
                value => { list_type => 'prefixlist', list_name => 'only_default' },
            };
            my $routemap = { seq => 1, matches => [$routemap_config], action => "deny" };
            unshift(@{ $config->{frr}->{routemaps}->{'MAP_VTEP_IN'} }, $routemap);

        } elsif ($exitnodes_primary ne $local_node) {
            my $routemap_config_v6 = {
                protocol_type => 'ipv6',
                match_type => 'address',
                value => { list_type => 'prefixlist', list_name => 'only_default_v6' },
            };
            my $routemap_v6 = {
                seq => 1,
                matches => [$routemap_config_v6],
                sets => [{ set_type => 'metric', value => 200 }],
                action => "permit",
            };
            unshift(
                @{ $config->{frr}->{routemaps}->{'MAP_VTEP_OUT'} }, $routemap_v6,
            );

            my $routemap_config = {
                protocol_type => 'ip',
                match_type => 'address',
                value => { list_type => 'prefixlist', list_name => 'only_default' },
            };
            my $routemap = {
                seq => 1,
                matches => [$routemap_config],
                sets => [{ set_type => 'metric', value => 200 }],
                action => "permit",
            };
            unshift(@{ $config->{frr}->{routemaps}->{'MAP_VTEP_OUT'} }, $routemap);
        }

        if (!$exitnodes_local_routing) {
            # Import /32 routes from VRF to main router
            my $main_bgp_router = $config->{frr}->{bgp}->{vrf_router}->{'default'};
            if ($main_bgp_router) {
                $main_bgp_router->{address_families}->{ipv4_unicast} //= {};
                push(@{ $main_bgp_router->{address_families}->{ipv4_unicast}->{import_vrf} }, $vrf);

                $main_bgp_router->{address_families}->{ipv6_unicast} //= {};
                push(@{ $main_bgp_router->{address_families}->{ipv6_unicast}->{import_vrf} }, $vrf);
            }

            # Redistribute connected in VRF router
            $vrf_router->{address_families}->{ipv4_unicast} //= { redistribute => [] };
            push @{ $vrf_router->{address_families}->{ipv4_unicast}->{redistribute} },
                { protocol => "connected" };

            $vrf_router->{address_families}->{ipv6_unicast} //= { redistribute => [] };
            push @{ $vrf_router->{address_families}->{ipv6_unicast}->{redistribute} },
                { protocol => "connected" };
        }

        # Add default originate to announce 0.0.0.0/0 type5 route in evpn
        $vrf_router->{address_families}->{l2vpn_evpn} //= {};
        $vrf_router->{address_families}->{l2vpn_evpn}->{default_originate} = ["ipv4", "ipv6"];

    } elsif ($advertisesubnets) {
        # Redistribute connected networks
        $vrf_router->{address_families}->{ipv4_unicast} //= { redistribute => [] };
        push @{ $vrf_router->{address_families}->{ipv4_unicast}->{redistribute} },
            { protocol => "connected" };

        $vrf_router->{address_families}->{ipv6_unicast} //= { redistribute => [] };
        push @{ $vrf_router->{address_families}->{ipv6_unicast}->{redistribute} },
            { protocol => "connected" };

        # Advertise connected networks type5 route in evpn
        $vrf_router->{address_families}->{l2vpn_evpn} //= {};
        $vrf_router->{address_families}->{l2vpn_evpn}->{advertise_ipv4_unicast} = 1;
        $vrf_router->{address_families}->{l2vpn_evpn}->{advertise_ipv6_unicast} = 1;
    }

    if ($rt_import) {
        $vrf_router->{address_families}->{l2vpn_evpn} //= { route_targets => {} };
        $vrf_router->{address_families}->{l2vpn_evpn}->{route_targets}->{import} //= [];
        push @{ $vrf_router->{address_families}->{l2vpn_evpn}->{route_targets}->{import} },
            @{$rt_import};
    }

    return $config;
}

sub generate_vnet_frr_config {
    my ($class, $plugin_config, $controller, $zone, $zoneid, $vnetid, $config) = @_;

    my $exitnodes = $zone->{'exitnodes'};
    my $exitnodes_local_routing = $zone->{'exitnodes-local-routing'};

    return if !$exitnodes_local_routing;

    my $local_node = PVE::INotify::nodename();
    my $is_gateway = $exitnodes->{$local_node};

    return if !$is_gateway;

    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);
    $config->{frr}->{ip_routes} //= [];
    foreach my $subnetid (sort keys %{$subnets}) {
        my $subnet = $subnets->{$subnetid};
        my $cidr = $subnet->{cidr};
        my ($ip) = split(/\//, $cidr, 2);
        if (Net::IP::ip_is_ipv6($ip)) {
            push @{ $config->{frr}->{ip_routes} },
                {
                    prefix => $cidr,
                    via => "fe80::2",
                    vrf => "xvrf_$zoneid",
                    is_ipv6 => 1,
                };
        } else {
            push @{ $config->{frr}->{ip_routes} },
                {
                    prefix => $cidr,
                    via => "10.255.255.2",
                    vrf => "xvrf_$zoneid",
                    is_ipv6 => 0,
                };
        }
    }
}

sub on_delete_hook {
    my ($class, $controllerid, $zone_cfg) = @_;

    # verify that zone is associated to this controller
    foreach my $id (keys %{ $zone_cfg->{ids} }) {
        my $zone = $zone_cfg->{ids}->{$id};
        die "controller $controllerid is used by $id"
            if (defined($zone->{controller}) && $zone->{controller} eq $controllerid);
    }
}

sub on_update_hook {
    my ($class, $controllerid, $controller_cfg) = @_;

    # we can only have 1 evpn controller / 1 asn by server

    my $controllernb = 0;
    foreach my $id (keys %{ $controller_cfg->{ids} }) {
        next if $id eq $controllerid;
        my $controller = $controller_cfg->{ids}->{$id};
        next if $controller->{type} ne "evpn";
        $controllernb++;
        die "only 1 global evpn controller can be defined" if $controllernb >= 1;
    }

    my $controller = $controller_cfg->{ids}->{$controllerid};
    if ($controller->{type} eq 'evpn') {
        die "must have exactly one of peers / fabric defined"
            if ($controller->{peers} && $controller->{fabric})
            || !($controller->{peers} || $controller->{fabric});
    }
}

sub find_bgp_controller {
    my ($nodename, $controller_cfg) = @_;

    my $res = undef;
    foreach my $id (keys %{ $controller_cfg->{ids} }) {
        my $controller = $controller_cfg->{ids}->{$id};
        next if $controller->{type} ne 'bgp';
        next if $controller->{node} ne $nodename;
        $res = $controller;
        last;
    }
    return $res;
}

sub find_isis_controller {
    my ($nodename, $controller_cfg) = @_;

    my $res = undef;
    foreach my $id (keys %{ $controller_cfg->{ids} }) {
        my $controller = $controller_cfg->{ids}->{$id};
        next if $controller->{type} ne 'isis';
        next if $controller->{node} ne $nodename;
        $res = $controller;
        last;
    }
    return $res;
}

1;
