package PVE::Network::SDN::Zones::EvpnPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::VxlanPlugin;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Exception qw(raise raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw($IPV4RE);
use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;
use Net::IP;

use PVE::Network::SDN::Controllers::EvpnPlugin;

use base('PVE::Network::SDN::Zones::VxlanPlugin');

sub type {
    return 'evpn';
}

PVE::JSONSchema::register_format('pve-sdn-bgp-rt', \&pve_verify_sdn_bgp_rt);
sub pve_verify_sdn_bgp_rt {
    my ($rt) = @_;

    if ($rt =~ m/^(\d+):(\d+)$/) {
	my $asn = $1;
	my $id = $2;

	if ($asn < 0 || $asn > 4294967295) {
	    die "value does not look like a valid bgp route-target\n";
	}
	if ($id < 0 || $id > 4294967295) {
	    die "value does not look like a valid bgp route-target\n";
	}
    } else {
	die "value does not look like a valid bgp route-target\n";
    }
    return $rt;
}

sub properties {
    return {
	'vrf-vxlan' => {
	    type => 'integer',
	    description => "l3vni.",
	},
	'controller' => {
	    type => 'string',
	    description => "Frr router name",
	},
	'mac' => {
	    type => 'string',
	    description => "Anycast logical router mac address",
	    optional => 1, format => 'mac-addr'
	},
	'exitnodes' => get_standard_option('pve-node-list'),
	'exitnodes-local-routing' => {
	    type => 'boolean',
	    description => "Allow exitnodes to connect to evpn guests",
	    optional => 1
	},
	'exitnodes-primary' => get_standard_option('pve-node', {
	    description => "Force traffic to this exitnode first."}),
	'advertise-subnets' => {
	    type => 'boolean',
	    description => "Advertise evpn subnets if you have silent hosts",
	    optional => 1
	},
	'disable-arp-nd-suppression' => {
	    type => 'boolean',
	    description => "Disable ipv4 arp && ipv6 neighbour discovery suppression",
	    optional => 1
	},
	'rt-import' => {
	    type => 'string',
	    description => "Route-Target import",
	    optional => 1, format => 'pve-sdn-bgp-rt-list'
        }
    };
}

sub options {
    return {
	nodes => { optional => 1},
	'vrf-vxlan' => { optional => 0 },
	controller => { optional => 0 },
	exitnodes => { optional => 1 },
	'exitnodes-local-routing' => { optional => 1 },
	'exitnodes-primary' => { optional => 1 },
	'advertise-subnets' => { optional => 1 },
	'disable-arp-nd-suppression' => { optional => 1 },
        'bridge-disable-mac-learning' => { optional => 1 },
	'rt-import' => { optional => 1 },
	'vxlan-port' => { optional => 1 },
	mtu => { optional => 1 },
	mac => { optional => 1 },
	dns => { optional => 1 },
	reversedns => { optional => 1 },
	dnszone => { optional => 1 },
	ipam => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $controller_cfg, $subnet_cfg, $interfaces_config, $config) = @_;

    my $tag = $vnet->{tag};
    my $alias = $vnet->{alias};
    my $mac = $plugin_config->{'mac'};
    my $vxlanport = $plugin_config->{'vxlan-port'};

    my $vrf_iface = "vrf_$zoneid";
    my $vrfvxlan = $plugin_config->{'vrf-vxlan'};
    my $local_node = PVE::INotify::nodename();

    die "missing vxlan tag" if !$tag;
    die "missing controller" if !$controller;

    my @peers = PVE::Tools::split_list($controller->{'peers'});

    my $loopback = undef;
    my $bgprouter = PVE::Network::SDN::Controllers::EvpnPlugin::find_bgp_controller($local_node, $controller_cfg);
    my $isisrouter = PVE::Network::SDN::Controllers::EvpnPlugin::find_isis_controller($local_node, $controller_cfg);
    if ($bgprouter->{loopback}) {
	$loopback = $bgprouter->{loopback};
    } elsif ($isisrouter->{loopback}) {
	$loopback = $isisrouter->{loopback};
    }

    my ($ifaceip, $iface) = PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers, $loopback);
    my $is_evpn_gateway = $plugin_config->{'exitnodes'}->{$local_node};
    my $exitnodes_local_routing = $plugin_config->{'exitnodes-local-routing'};


    my $mtu = 1450;
    $mtu = $interfaces_config->{$iface}->{mtu} - 50 if $interfaces_config->{$iface}->{mtu};
    $mtu = $plugin_config->{mtu} if $plugin_config->{mtu};

    #vxlan interface
    my $vxlan_iface = "vxlan_$vnetid";
    my @iface_config = ();
    push @iface_config, "vxlan-id $tag";
    push @iface_config, "vxlan-local-tunnelip $ifaceip" if $ifaceip;
    push @iface_config, "vxlan-port $vxlanport" if $vxlanport;
    push @iface_config, "bridge-learning off";
    push @iface_config, "bridge-arp-nd-suppress on" if !$plugin_config->{'disable-arp-nd-suppression'};

    push @iface_config, "mtu $mtu" if $mtu;
    push(@{$config->{$vxlan_iface}}, @iface_config) if !$config->{$vxlan_iface};

    #vnet bridge
    @iface_config = ();

    my $address = {};
    my $ipv4 = undef;
    my $ipv6 = undef;
    my $enable_forward_v4 = undef;
    my $enable_forward_v6 = undef;
    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);
    foreach my $subnetid (sort keys %{$subnets}) {
	my $subnet = $subnets->{$subnetid};
	my $cidr = $subnet->{cidr};
	my $mask = $subnet->{mask};

	my $gateway = $subnet->{gateway};
	if ($gateway) {
	    push @iface_config, "address $gateway/$mask" if !defined($address->{$gateway});
	    $address->{$gateway} = 1;
	}

        my $iptables = undef;
        my $checkrouteip = undef;
        my $ipversion = Net::IP::ip_is_ipv6($gateway) ? 6 : 4;

	if ($ipversion == 6) {
	    $ipv6 = 1;
	    $iptables = "ip6tables";
	    $checkrouteip = '2001:4860:4860::8888';
	    $enable_forward_v6 = 1 if $gateway;
	} else {
	    $ipv4 = 1;
	    $iptables = "iptables";
	    $checkrouteip = '8.8.8.8';
	    $enable_forward_v4 = 1 if $gateway;
	}

	if ($subnet->{snat}) {

            #find outgoing interface
            my ($outip, $outiface) = PVE::Network::SDN::Zones::Plugin::get_local_route_ip($checkrouteip);
            if ($outip && $outiface && $is_evpn_gateway) {
                #use snat, faster than masquerade
                push @iface_config, "post-up $iptables -t nat -A POSTROUTING -s '$cidr' -o $outiface -j SNAT --to-source $outip";
                push @iface_config, "post-down $iptables -t nat -D POSTROUTING -s '$cidr' -o $outiface -j SNAT --to-source $outip";
                #add conntrack zone once on outgoing interface
                push @iface_config, "post-up $iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1";
                push @iface_config, "post-down $iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1";
            }
        }
    }

    push @iface_config, "hwaddress $mac" if $mac;
    push @iface_config, "bridge_ports $vxlan_iface";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push @iface_config, "ip-forward on" if $enable_forward_v4;
    push @iface_config, "ip6-forward on" if $enable_forward_v6;
    push @iface_config, "arp-accept on" if $ipv4||$ipv6;
    push @iface_config, "vrf $vrf_iface" if $vrf_iface;
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};

    if ($vrf_iface) {
	#vrf interface
	@iface_config = ();
	push @iface_config, "vrf-table auto";
	if(!$is_evpn_gateway) {
	    push @iface_config, "post-up ip route add vrf $vrf_iface unreachable default metric 4278198272";
	} else {
	    push @iface_config, "post-up ip route del vrf $vrf_iface unreachable default metric 4278198272";
	}

	push(@{$config->{$vrf_iface}}, @iface_config) if !$config->{$vrf_iface};

	if ($vrfvxlan) {
	    #l3vni vxlan interface
	    my $iface_vrf_vxlan = "vrfvx_$zoneid";
	    @iface_config = ();
	    push @iface_config, "vxlan-id $vrfvxlan";
	    push @iface_config, "vxlan-local-tunnelip $ifaceip" if $ifaceip;
	    push @iface_config, "vxlan-port $vxlanport" if $vxlanport;
	    push @iface_config, "bridge-learning off";
	    push @iface_config, "bridge-arp-nd-suppress on" if !$plugin_config->{'disable-arp-nd-suppression'};
	    push @iface_config, "mtu $mtu" if $mtu;
	    push(@{$config->{$iface_vrf_vxlan}}, @iface_config) if !$config->{$iface_vrf_vxlan};

	    #l3vni bridge
	    my $brvrf = "vrfbr_$zoneid";
	    @iface_config = ();
	    push @iface_config, "bridge-ports $iface_vrf_vxlan";
	    push @iface_config, "bridge_stp off";
	    push @iface_config, "bridge_fd 0";
	    push @iface_config, "mtu $mtu" if $mtu;
	    push @iface_config, "vrf $vrf_iface";
	    push(@{$config->{$brvrf}}, @iface_config) if !$config->{$brvrf};
	}

	if ( $is_evpn_gateway && $exitnodes_local_routing ) {
	    #add a veth pair for local cross-vrf routing
	    my $iface_xvrf = "xvrf_$zoneid";
	    my $iface_xvrfp = "xvrfp_$zoneid";

	    @iface_config = ();
	    push @iface_config, "link-type veth";
	    push @iface_config, "address 10.255.255.1/30";
	    push @iface_config, "veth-peer-name $iface_xvrfp";
	    push @iface_config, "mtu ".($mtu+50) if $mtu;
	    push(@{$config->{$iface_xvrf}}, @iface_config) if !$config->{$iface_xvrf};

	    @iface_config = ();
	    push @iface_config, "link-type veth";
	    push @iface_config, "address 10.255.255.2/30";
	    push @iface_config, "veth-peer-name $iface_xvrf";
	    push @iface_config, "vrf $vrf_iface";
	    push @iface_config, "mtu ".($mtu+50) if $mtu;
	    push(@{$config->{$iface_xvrfp}}, @iface_config) if !$config->{$iface_xvrfp};
	}
    }
    return $config;
}

sub on_update_hook {
    my ($class, $zoneid, $zone_cfg, $controller_cfg) = @_;

    # verify that controller exist
    my $controller = $zone_cfg->{ids}->{$zoneid}->{controller};
    if (!defined($controller_cfg->{ids}->{$controller})) {
	die "controller $controller don't exist";
    } else {
	die "$controller is not a evpn controller type" if $controller_cfg->{ids}->{$controller}->{type} ne 'evpn';
    }

    #vrf-vxlan need to be defined

    my $vrfvxlan = $zone_cfg->{ids}->{$zoneid}->{'vrf-vxlan'};
    # verify that vrf-vxlan is not already declared in another zone
    foreach my $id (keys %{$zone_cfg->{ids}}) {
	next if $id eq $zoneid;
	die "vrf-vxlan $vrfvxlan is already declared in $id"
		if (defined($zone_cfg->{ids}->{$id}->{'vrf-vxlan'}) && $zone_cfg->{ids}->{$id}->{'vrf-vxlan'} eq $vrfvxlan);
    }

    if (!defined($zone_cfg->{ids}->{$zoneid}->{'mac'})) {
        my $dc = PVE::Network::SDN::Zones::Plugin->datacenter_config();
	$zone_cfg->{ids}->{$zoneid}->{'mac'} = PVE::Tools::random_ether_addr($dc->{mac_prefix});
    }
}


sub vnet_update_hook {
    my ($class, $vnet_cfg, $vnetid, $zone_cfg) = @_;

    my $vnet = $vnet_cfg->{ids}->{$vnetid};
    my $tag = $vnet->{tag};

    raise_param_exc({ tag => "missing vxlan tag"}) if !defined($tag);
    raise_param_exc({ tag => "vxlan tag max value is 16777216"}) if $tag > 16777216;
    raise_param_exc({ 'vlan-aware' => "vlan-aware option can't be enabled with evpn"}) if $vnet->{vlanaware};

    # verify that tag is not already defined globally (vxlan-id are unique)
    foreach my $id (keys %{$vnet_cfg->{ids}}) {
	next if $id eq $vnetid;
	my $othervnet = $vnet_cfg->{ids}->{$id};
	my $other_tag = $othervnet->{tag};
	my $other_zoneid = $othervnet->{zone};
	my $other_zone = $zone_cfg->{ids}->{$other_zoneid};
	next if $other_zone->{type} ne 'vxlan' && $other_zone->{type} ne 'evpn';
	raise_param_exc({ tag => "vxlan tag $tag already exist in vnet $id in zone $other_zoneid "}) if $other_tag && $tag eq $other_tag;
    }
}

1;


