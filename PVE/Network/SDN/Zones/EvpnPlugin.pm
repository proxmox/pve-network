package PVE::Network::SDN::Zones::EvpnPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::VxlanPlugin;
use PVE::Exception qw(raise raise_param_exc);
use PVE::Tools qw($IPV4RE);
use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;

use PVE::Network::SDN::Controllers::EvpnPlugin;

use base('PVE::Network::SDN::Zones::VxlanPlugin');

sub type {
    return 'evpn';
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
    };
}

sub options {

    return {
        nodes => { optional => 1},
        'vrf-vxlan' => { optional => 0 },
        'controller' => { optional => 0 },
	mtu => { optional => 1 },
	dns => { optional => 1 },
	reversedns => { optional => 1 },
	dnszone => { optional => 1 },
	ipam => { optional => 0 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $subnet_cfg, $interfaces_config, $config) = @_;

    my $tag = $vnet->{tag};
    my $alias = $vnet->{alias};
    my $ipv4 = $vnet->{ipv4};
    my $ipv6 = $vnet->{ipv6};
    my $mac = $vnet->{mac};

    my $vrf_iface = "vrf_$zoneid";
    my $vrfvxlan = $plugin_config->{'vrf-vxlan'};
    my $local_node = PVE::INotify::nodename();

    die "missing vxlan tag" if !$tag;
    warn "vlan-aware vnet can't be enabled with evpn plugin" if $vnet->{vlanaware};

    my @peers = PVE::Tools::split_list($controller->{'peers'});
    my ($ifaceip, $iface) = PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers);

    my $mtu = 1450;
    $mtu = $interfaces_config->{$iface}->{mtu} - 50 if $interfaces_config->{$iface}->{mtu};
    $mtu = $plugin_config->{mtu} if $plugin_config->{mtu};

    #vxlan interface
    my $vxlan_iface = "vxlan_$vnetid";
    my @iface_config = ();
    push @iface_config, "vxlan-id $tag";
    push @iface_config, "vxlan-local-tunnelip $ifaceip" if $ifaceip;
    push @iface_config, "bridge-learning off";
    push @iface_config, "bridge-arp-nd-suppress on";

    push @iface_config, "mtu $mtu" if $mtu;
    push(@{$config->{$vxlan_iface}}, @iface_config) if !$config->{$vxlan_iface};

    #vnet bridge
    @iface_config = ();

    my $address = {};
    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);
    foreach my $subnetid (sort keys %{$subnets}) {
	my $subnet = $subnets->{$subnetid};
	my $cidr = $subnetid =~ s/-/\//r;
	my $gateway = $subnet->{gateway};
	if ($gateway) {
	    push @iface_config, "address $gateway" if !defined($address->{$gateway});
	    $address->{$gateway} = 1;
	}
	if ($subnet->{snat}) {
	    my $gatewaynodes = $controller->{'gateway-nodes'};
	    my $is_evpn_gateway = "";
	    foreach my $evpn_gatewaynode (PVE::Tools::split_list($gatewaynodes)) {
		$is_evpn_gateway = 1 if $evpn_gatewaynode eq $local_node;
	    }
            #find outgoing interface
            my ($outip, $outiface) = PVE::Network::SDN::Zones::Plugin::get_local_route_ip('8.8.8.8');
            if ($outip && $outiface && $is_evpn_gateway) {
                #use snat, faster than masquerade
                push @iface_config, "post-up iptables -t nat -A POSTROUTING -s '$cidr' -o $outiface -j SNAT --to-source $outip";
                push @iface_config, "post-down iptables -t nat -D POSTROUTING -s '$cidr' -o $outiface -j SNAT --to-source $outip";
                #add conntrack zone once on outgoing interface
                push @iface_config, "post-up iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1";
                push @iface_config, "post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1";
            }
        }
    }

    push @iface_config, "hwaddress $mac" if $mac;
    push @iface_config, "bridge_ports $vxlan_iface";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push @iface_config, "ip-forward on" if $ipv4;
    push @iface_config, "ip6-forward on" if $ipv6;
    push @iface_config, "arp-accept on" if $ipv4||$ipv6;
    push @iface_config, "vrf $vrf_iface" if $vrf_iface;
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};

    if ($vrf_iface) {
	#vrf interface
	@iface_config = ();
	push @iface_config, "vrf-table auto";
	push(@{$config->{$vrf_iface}}, @iface_config) if !$config->{$vrf_iface};

	if ($vrfvxlan) {
	    #l3vni vxlan interface
	    my $iface_vrf_vxlan = "vrfvx_$zoneid";
	    @iface_config = ();
	    push @iface_config, "vxlan-id $vrfvxlan";
	    push @iface_config, "vxlan-local-tunnelip $ifaceip" if $ifaceip;
	    push @iface_config, "bridge-learning off";
	    push @iface_config, "bridge-arp-nd-suppress on";
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

}


sub vnet_update_hook {
    my ($class, $vnet) = @_;

    raise_param_exc({ tag => "missing vxlan tag"}) if !defined($vnet->{tag});
    raise_param_exc({ tag => "vxlan tag max value is 16777216"}) if $vnet->{tag} > 16777216;

    if (!defined($vnet->{mac})) {
	my $dc = PVE::Cluster::cfs_read_file('datacenter.cfg');
	$vnet->{mac} = PVE::Tools::random_ether_addr($dc->{mac_prefix});
    }
}


1;


