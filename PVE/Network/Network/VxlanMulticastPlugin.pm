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
    my $alias = $vnet->{alias};
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
    $config .= "auto vxlan$tag\n";
    $config .= "iface vxlan$tag inet manual\n";
    $config .= "       vxlan-id $tag\n";
    $config .= "       vxlan-svcnodeip $multicastaddress\n" if $multicastaddress;
    $config .= "       vxlan-physdev $iface\n" if $iface;
    $config .= "       mtu $mtu\n" if $mtu;
    $config .= "\n";
    $config .= "auto $vnetid\n";
    $config .= "iface $vnetid inet manual\n";
    $config .= "        bridge_ports vxlan$tag\n";
    $config .= "        bridge_stp off\n";
    $config .= "        bridge_fd 0\n";
    $config .= "        mtu $mtu\n" if $mtu;
    $config .= "        alias $alias\n" if $alias;

    return $config;
}

sub on_delete_hook {
    my ($class, $transportid, $network_cfg) = @_;

    # verify that no vnet are associated to this transport
    foreach my $id (keys %{$network_cfg->{ids}}) {
	my $network = $network_cfg->{ids}->{$id};
	die "transport $transportid is used by vnet $id" 
	    if ($network->{type} eq 'vnet' && defined($network->{transportzone}) && $network->{transportzone} eq $transportid);
    }
}

sub on_update_hook {
    my ($class, $transportid, $network_cfg) = @_;

    my $transport = $network_cfg->{ids}->{$transportid};

    # verify that vxlan-allowed don't conflict with another vxlan-allowed transport

    # verify that vxlan-allowed is matching currently vnet tag in this transport  
    my $vxlanallowed = $transport->{'vxlan-allowed'};
    if ($vxlanallowed) {
	foreach my $id (keys %{$network_cfg->{ids}}) {
	    my $network = $network_cfg->{ids}->{$id};
	    if ($network->{type} eq 'vnet' && defined($network->{tag})) {
		if(defined($network->{transportzone}) && $network->{transportzone} eq $transportid) {
		    my $tag = $network->{tag};
		    eval {
			PVE::Network::Network::Plugin::parse_tag_number_or_range($vxlanallowed, '16777216', $tag);
		    };
		    if($@) {
			die "vnet $id - vlan $tag is not allowed in transport $transportid";
		    }
		}
	    }
	}
    }
}

1;


