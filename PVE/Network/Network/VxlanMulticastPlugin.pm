package PVE::Network::Network::VxlanMulticastPlugin;

use strict;
use warnings;
use PVE::Network::Network::Plugin;

use base('PVE::Network::Network::Plugin');

PVE::JSONSchema::register_format('pve-network-vxlanrange', \&pve_verify_network_vxlanrange);
sub pve_verify_network_vxlanrange {
   my ($vxlanstr) = @_;

   PVE::Network::Network::Plugin::parse_tag_number_or_range($vxlanstr, '16777216');

   return $vxlanstr;
}

sub type {
    return 'vxlanmulticast';
}

sub properties {
    return {
        'vxlan-allowed' => {
            type => 'string', format => 'pve-network-vxlanrange',
            description => "Allowed vlan range",
        },
        'multicast-address' => {
            description => "Multicast address.",
            type => 'string',  #fixme: format 
        },

    };
}

sub options {

    return {
	'uplink-id' => { optional => 0 },
        'multicast-address' => { optional => 0 },
        'vxlan-allowed' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_network_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $uplinks) = @_;

    my $tag = $vnet->{tag};
    my $mtu = $vnet->{mtu};
    my $multicastaddress = $plugin_config->{'multicast-address'};
    my $uplink = $plugin_config->{'uplink-id'};
    my $vxlanallowed = $plugin_config->{'vxlan-allowed'};

    die "missing vxlan tag" if !$tag;
    die "uplink $uplink is not defined" if !$uplinks->{$uplink};
    my $iface = $uplinks->{$uplink};

    eval {
	PVE::Network::Network::Plugin::parse_tag_number_or_range($vxlanallowed, '16777216', $tag) if $vxlanallowed;
    };
    if($@) {
	die "vlan $tag is not allowed in transport $zoneid";
    }

    my $config = "\n";
    $config .= "auto vxlan$vnetid\n";
    $config .= "iface vxlan$vnetid inet manual\n";
    $config .= "       vxlan-id $tag\n" if $tag;
    $config .= "       vxlan-svcnodeip $multicastaddress\n" if $multicastaddress;
    $config .= "       vxlan-physdev $iface\n" if $iface;
    $config .= "\n";
    $config .= "auto $vnetid\n";
    $config .= "iface $vnetid inet manual\n";
    $config .= "        bridge_ports vxlan$vnetid\n";
    $config .= "        bridge_stp off\n";
    $config .= "        bridge_fd 0\n";
    $config .= "        mtu $mtu\n" if $mtu;

    return $config;
}

1;


