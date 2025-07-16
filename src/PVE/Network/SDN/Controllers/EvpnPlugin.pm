package PVE::Network::SDN::Controllers::EvpnPlugin;

use strict;
use warnings;

use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(run_command file_set_contents file_get_contents);
use PVE::RESTEnvironment qw(log_warn);

use PVE::Network::SDN::Controllers::Plugin;
use PVE::Network::SDN::Zones::Plugin;
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
            maximum => 4294967296,
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
        'peers' => { optional => 0 },
    };
}

# Plugin implementation
sub generate_frr_config {
    my ($class, $plugin_config, $controller_cfg, $id, $uplinks, $config) = @_;

    my @peers;
    @peers = PVE::Tools::split_list($plugin_config->{'peers'}) if $plugin_config->{'peers'};

    my $local_node = PVE::INotify::nodename();

    my $asn = $plugin_config->{asn};
    my $ebgp = undef;
    my $loopback = undef;
    my $autortas = undef;
    my $bgprouter = find_bgp_controller($local_node, $controller_cfg);
    my $isisrouter = find_isis_controller($local_node, $controller_cfg);

    if ($bgprouter) {
        $ebgp = 1 if $plugin_config->{'asn'} ne $bgprouter->{asn};
        $loopback = $bgprouter->{loopback} if $bgprouter->{loopback};
        $asn = $bgprouter->{asn} if $bgprouter->{asn};
        $autortas = $plugin_config->{'asn'} if $ebgp;
    } elsif ($isisrouter) {
        $loopback = $isisrouter->{loopback} if $isisrouter->{loopback};
    }

    return if !$asn;

    my $bgp = $config->{frr}->{router}->{"bgp $asn"} //= {};

    my ($ifaceip, $interface) =
        PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers, $loopback);
    my $routerid = PVE::Network::SDN::Controllers::Plugin::get_router_id($ifaceip, $interface);

    my $remoteas = $ebgp ? "external" : $asn;

    #global options
    my @controller_config = (
        "bgp router-id $routerid",
        "no bgp hard-administrative-reset",
        "no bgp default ipv4-unicast",
        "coalesce-time 1000",
        "no bgp graceful-restart notification",
    );

    push(@{ $bgp->{""} }, @controller_config) if keys %{$bgp} == 0;

    @controller_config = ();

    #VTEP neighbors
    push @controller_config, "neighbor VTEP peer-group";
    push @controller_config, "neighbor VTEP remote-as $remoteas";
    push @controller_config, "neighbor VTEP bfd";

    push @controller_config, "neighbor VTEP ebgp-multihop 10" if $ebgp && $loopback;
    push @controller_config, "neighbor VTEP update-source $loopback" if $loopback;

    # VTEP peers
    foreach my $address (@peers) {
        next if $address eq $ifaceip;
        push @controller_config, "neighbor $address peer-group VTEP";
    }

    push(@{ $bgp->{""} }, @controller_config);

    # address-family l2vpn
    @controller_config = ();
    push @controller_config, "neighbor VTEP activate";
    push @controller_config, "neighbor VTEP route-map MAP_VTEP_IN in";
    push @controller_config, "neighbor VTEP route-map MAP_VTEP_OUT out";
    push @controller_config, "advertise-all-vni";
    push @controller_config, "autort as $autortas" if $autortas;
    push(@{ $bgp->{"address-family"}->{"l2vpn evpn"} }, @controller_config);

    my $routemap = { rule => undef, action => "permit" };
    push(@{ $config->{frr_routemap}->{'MAP_VTEP_IN'} }, $routemap);
    push(@{ $config->{frr_routemap}->{'MAP_VTEP_OUT'} }, $routemap);

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
    @peers = PVE::Tools::split_list($controller->{'peers'}) if $controller->{'peers'};
    my $ebgp = undef;
    my $loopback = undef;
    my $autortas = undef;
    my $bgprouter = find_bgp_controller($local_node, $controller_cfg);
    my $isisrouter = find_isis_controller($local_node, $controller_cfg);

    if ($bgprouter) {
        $ebgp = 1 if $controller->{'asn'} ne $bgprouter->{asn};
        $loopback = $bgprouter->{loopback} if $bgprouter->{loopback};
        $asn = $bgprouter->{asn} if $bgprouter->{asn};
        $autortas = $controller->{'asn'} if $ebgp;
    } elsif ($isisrouter) {
        $loopback = $isisrouter->{loopback} if $isisrouter->{loopback};
    }

    return if !$vrf || !$vrfvxlan || !$asn;

    my ($ifaceip, $interface) =
        PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers, $loopback);
    my $routerid = PVE::Network::SDN::Controllers::Plugin::get_router_id($ifaceip, $interface);

    my $is_gateway = $exitnodes->{$local_node};

    # vrf
    my @controller_config = ();
    push @controller_config, "vni $vrfvxlan";
    #avoid to routes between nodes through the exit nodes
    #null routes subnets of other zones
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
            my $ipversion = Net::IP::ip_is_ipv4($ip) ? 'ip' : 'ipv6';
            push @controller_config, "$ipversion route $ip/$cidrs->{$ip} null0";
        }
    }

    push(@{ $config->{frr}->{vrf}->{"$vrf"} }, @controller_config);

    #main vrf router
    @controller_config = ();
    push @controller_config, "bgp router-id $routerid";
    push @controller_config, "no bgp hard-administrative-reset";
    push @controller_config, "no bgp graceful-restart notification";

    #    push @controller_config, "!";
    push(@{ $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{""} }, @controller_config);

    if ($autortas) {
        push(
            @{
                $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}
                    ->{"l2vpn evpn"}
            },
            "route-target import $autortas:$vrfvxlan",
        );
        push(
            @{
                $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}
                    ->{"l2vpn evpn"}
            },
            "route-target export $autortas:$vrfvxlan",
        );
    }

    if ($is_gateway) {

        $config->{frr_prefix_list}->{'only_default'}->{1} = "permit 0.0.0.0/0";
        $config->{frr_prefix_list_v6}->{'only_default_v6'}->{1} = "permit ::/0";

        if (!$exitnodes_primary || $exitnodes_primary eq $local_node) {
            #filter default route coming from other exit nodes on primary node or both nodes if no primary is defined.
            my $routemap_config_v6 = ();
            push @{$routemap_config_v6}, "match ipv6 address prefix-list only_default_v6";
            my $routemap_v6 = { rule => $routemap_config_v6, action => "deny" };
            unshift(@{ $config->{frr_routemap}->{'MAP_VTEP_IN'} }, $routemap_v6);

            my $routemap_config = ();
            push @{$routemap_config}, "match ip address prefix-list only_default";
            my $routemap = { rule => $routemap_config, action => "deny" };
            unshift(@{ $config->{frr_routemap}->{'MAP_VTEP_IN'} }, $routemap);

        } elsif ($exitnodes_primary ne $local_node) {
            my $routemap_config_v6 = ();
            push @{$routemap_config_v6}, "match ipv6 address prefix-list only_default_v6";
            push @{$routemap_config_v6}, "set metric 200";
            my $routemap_v6 = { rule => $routemap_config_v6, action => "permit" };
            unshift(@{ $config->{frr_routemap}->{'MAP_VTEP_OUT'} }, $routemap_v6);

            my $routemap_config = ();
            push @{$routemap_config}, "match ip address prefix-list only_default";
            push @{$routemap_config}, "set metric 200";
            my $routemap = { rule => $routemap_config, action => "permit" };
            unshift(@{ $config->{frr_routemap}->{'MAP_VTEP_OUT'} }, $routemap);
        }

        if (!$exitnodes_local_routing) {
            @controller_config = ();
            #import /32 routes of evpn network from vrf1 to default vrf (for packet return)
            push @controller_config, "import vrf $vrf";
            push(
                @{
                    $config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv4 unicast"}
                },
                @controller_config,
            );
            push(
                @{
                    $config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv6 unicast"}
                },
                @controller_config,
            );

            @controller_config = ();
            #redistribute connected to be able to route to local vms on the gateway
            push @controller_config, "redistribute connected";
            push(
                @{
                    $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}
                        ->{"ipv4 unicast"}
                },
                @controller_config,
            );
            push(
                @{
                    $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}
                        ->{"ipv6 unicast"}
                },
                @controller_config,
            );
        }

        @controller_config = ();
        #add default originate to announce 0.0.0.0/0 type5 route in evpn
        push @controller_config, "default-originate ipv4";
        push @controller_config, "default-originate ipv6";
        push(
            @{
                $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}
                    ->{"l2vpn evpn"}
            },
            @controller_config,
        );
    } elsif ($advertisesubnets) {

        @controller_config = ();
        #redistribute connected networks
        push @controller_config, "redistribute connected";
        push(
            @{
                $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}
                    ->{"ipv4 unicast"}
            },
            @controller_config,
        );
        push(
            @{
                $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}
                    ->{"ipv6 unicast"}
            },
            @controller_config,
        );

        @controller_config = ();
        #advertise connected networks type5 route in evpn
        push @controller_config, "advertise ipv4 unicast";
        push @controller_config, "advertise ipv6 unicast";
        push(
            @{
                $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}
                    ->{"l2vpn evpn"}
            },
            @controller_config,
        );
    }

    if ($rt_import) {
        @controller_config = ();
        foreach my $rt (sort @{$rt_import}) {
            push @controller_config, "route-target import $rt";
        }
        push(
            @{
                $config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}
                    ->{"l2vpn evpn"}
            },
            @controller_config,
        );
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
    my @controller_config = ();
    foreach my $subnetid (sort keys %{$subnets}) {
        my $subnet = $subnets->{$subnetid};
        my $cidr = $subnet->{cidr};
        push @controller_config, "ip route $cidr 10.255.255.2 xvrf_$zoneid";
    }
    push(@{ $config->{frr_ip_protocol} }, @controller_config);
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
