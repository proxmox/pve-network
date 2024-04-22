package PVE::Network::SDN::Zones::SimplePlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Network::SDN::Dhcp::Plugin;
use PVE::Exception qw(raise raise_param_exc);
use PVE::Cluster;
use PVE::Tools;

use base('PVE::Network::SDN::Zones::Plugin');

sub type {
    return 'simple';
}

sub properties {
    return {
	dns => {
	    type => 'string',
	    description => "dns api server",
	},
	reversedns => {
	    type => 'string',
	    description => "reverse dns api server",
	},
	dnszone => {
	    type => 'string', format => 'dns-name',
	    description => "dns domain zone  ex: mydomain.com",
	},
	dhcp => {
	    description => 'Type of the DHCP backend for this zone',
	    type => 'string',
	    enum => PVE::Network::SDN::Dhcp::Plugin->lookup_types(),
	},
    };
}

sub options {
    return {
	nodes => { optional => 1},
	mtu => { optional => 1 },
	dns => { optional => 1 },
	reversedns => { optional => 1 },
	dnszone => { optional => 1 },
	ipam => { optional => 1 },
	dhcp => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $controller_cfg, $subnet_cfg, $interfaces_config, $config) = @_;

    return $config if$config->{$vnetid}; # nothing to do

    my $mac = $vnet->{mac};
    my $alias = $vnet->{alias};
    my $mtu = $class->get_mtu($plugin_config);

    # vnet bridge
    my @iface_config = ();

    my $address = {};
    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);

    my $ipv4 = undef;
    my $ipv6 = undef;
    my $enable_forward_v4 = undef;
    my $enable_forward_v6 = undef;

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

	if ( $ipversion == 6) {
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

	#add route for /32 pointtopoint
	push @iface_config, "up ip route add $cidr dev $vnetid" if $mask == 32 && $ipversion == 4;
	if ($subnet->{snat}) {
	    #find outgoing interface
	    my ($outip, $outiface) = PVE::Network::SDN::Zones::Plugin::get_local_route_ip($checkrouteip);
	    if ($outip && $outiface) {
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
    push @iface_config, "bridge_ports none";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    if ($vnet->{vlanaware}) {
        push @iface_config, "bridge-vlan-aware yes";
        push @iface_config, "bridge-vids 2-4094";
    }
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push @iface_config, "ip-forward on" if $enable_forward_v4;
    push @iface_config, "ip6-forward on" if $enable_forward_v6;

    push @{$config->{$vnetid}}, @iface_config;

    return $config;
}

sub vnet_update_hook {
    my ($class, $vnet_cfg, $vnetid, $zone_cfg) = @_;

    my $vnet = $vnet_cfg->{ids}->{$vnetid};
    my $tag = $vnet->{tag};

    raise_param_exc({ tag => "vlan tag is not allowed on simple zone"}) if defined($tag);

    if (!defined($vnet->{mac})) {
        my $dc = PVE::Network::SDN::Zones::Plugin::datacenter_config();
        $vnet->{mac} = PVE::Tools::random_ether_addr($dc->{mac_prefix});
    }
}

sub get_mtu {
    my ($class, $plugin_config) = @_;

    return $plugin_config->{mtu};
}

1;


