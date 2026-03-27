package PVE::Network::SDN::Controllers::BgpPlugin;

use strict;
use warnings;

use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(run_command file_set_contents file_get_contents);

use PVE::Network::SDN::Controllers::Plugin;
use PVE::Network::SDN::Zones::Plugin;
use Net::IP;

use base('PVE::Network::SDN::Controllers::Plugin');

sub type {
    return 'bgp';
}

sub properties {
    return {
        'bgp-multipath-as-path-relax' => {
            type => 'boolean',
            optional => 1,
            description =>
                'Consider different AS paths of equal length for multipath computation.',
        },
        ebgp => {
            type => 'boolean',
            optional => 1,
            description => "Enable eBGP (remote-as external).",
        },
        'ebgp-multihop' => {
            type => 'integer',
            optional => 1,
            description => 'Set maximum amount of hops for eBGP peers.',
        },
        loopback => {
            description => "Name of the loopback/dummy interface that provides the Router-IP.",
            type => 'string',
        },
        node => get_standard_option('pve-node'),
    };
}

sub options {
    return {
        'node' => { optional => 0 },
        'asn' => { optional => 0 },
        'peers' => { optional => 0 },
        'bgp-multipath-as-path-relax' => { optional => 1 },
        'ebgp' => { optional => 1 },
        'ebgp-multihop' => { optional => 1 },
        'loopback' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_frr_config {
    my ($class, $plugin_config, $controller, $id, $uplinks, $config) = @_;

    my @peers;
    @peers = PVE::Tools::split_list($plugin_config->{'peers'}) if $plugin_config->{'peers'};

    my $asn = int($plugin_config->{asn});
    my $ebgp = $plugin_config->{ebgp};
    my $ebgp_multihop = $plugin_config->{'ebgp-multihop'};
    my $loopback = $plugin_config->{loopback};
    my $multipath_relax = $plugin_config->{'bgp-multipath-as-path-relax'};

    my $local_node = PVE::INotify::nodename();

    return if !$asn;
    return if $local_node ne $plugin_config->{node};

    my ($ifaceip, $interface) =
        PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers, $loopback);
    my $routerid = PVE::Network::SDN::Controllers::Plugin::get_router_id($ifaceip, $interface);

    my $bgp_router = $config->{frr}->{bgp}->{vrf_router}->{'default'} //= {};

    # Initialize router if not already configured
    if (!keys %{$bgp_router}) {
        $bgp_router->{asn} = $asn;
        $bgp_router->{router_id} = $routerid;
        $bgp_router->{default_ipv4_unicast} = 0;
        $bgp_router->{coalesce_time} = 1000;
        $bgp_router->{neighbor_groups} = [];
        $bgp_router->{address_families} = {};
    }

    # Add BGP-specific options
    $bgp_router->{disable_ebgp_connected_route_check} = 1 if $loopback && $ebgp;
    $bgp_router->{bestpath_as_path_multipath_relax} = 1 if $multipath_relax;

    # Build BGP neighbor group
    if (@peers) {
        my $neighbor_group = {
            name => "BGP",
            bfd => 1,
            remote_as => $ebgp ? "external" : $asn,
            ips => \@peers,
            interfaces => [],
        };
        $neighbor_group->{ebgp_multihop} = int($ebgp_multihop) if $ebgp && $ebgp_multihop;

        push @{ $bgp_router->{neighbor_groups} }, $neighbor_group;

        # Configure address-family unicast
        my $ipversion = Net::IP::ip_is_ipv6($ifaceip) ? "ipv6" : "ipv4";
        my $mask = Net::IP::ip_is_ipv6($ifaceip) ? "128" : "32";
        my $af_key = "${ipversion}_unicast";

        $bgp_router->{address_families}->{$af_key} //= {
            networks => [],
            neighbors => [{
                name => "BGP",
                soft_reconfiguration_inbound => 1,
            }],
        };

        push @{ $bgp_router->{address_families}->{$af_key}->{networks} }, "$ifaceip/$mask"
            if $loopback;
    }

    # Configure route-map for source IP correction with loopback
    if ($loopback) {
        $config->{frr}->{prefix_lists}->{loopbacks_ips} = [{
            seq => 10,
            action => 'permit',
            network => '0.0.0.0/0',
            le => 32,
            is_ipv6 => 0,
        }];

        $config->{frr}->{protocol_routemaps}->{bgp}->{v4} = "correct_src";

        my $routemap_config = {
            protocol_type => 'ip',
            match_type => 'address',
            value => { list_type => 'prefixlist', list_name => 'loopbacks_ips' },
        };
        my $routemap = {
            matches => [$routemap_config],
            sets => [{ set_type => 'src', value => $ifaceip }],
            action => "permit",
            seq => 1,
        };
        push(@{ $config->{frr}->{routemaps}->{'correct_src'} }, $routemap);
    }

    return $config;
}

sub generate_zone_frr_config {
    my ($class, $plugin_config, $controller, $controller_cfg, $id, $uplinks, $config) = @_;

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

    # we can only have 1 bgp controller by node
    my $local_node = PVE::INotify::nodename();
    my $controllernb = 0;
    foreach my $id (keys %{ $controller_cfg->{ids} }) {
        next if $id eq $controllerid;
        my $controller = $controller_cfg->{ids}->{$id};
        next if $controller->{type} ne "bgp";
        next if $controller->{node} ne $local_node;
        $controllernb++;
        die "only 1 bgp controller can be defined" if $controllernb > 1;
    }
}

1;
