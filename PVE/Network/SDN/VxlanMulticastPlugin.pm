package PVE::Network::SDN::VxlanMulticastPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Plugin;

use base('PVE::Network::SDN::Plugin');

PVE::JSONSchema::register_format('pve-sdn-vxlanrange', \&pve_verify_sdn_vxlanrange);
sub pve_verify_sdn_vxlanrange {
   my ($vxlanstr) = @_;

   PVE::Network::SDN::Plugin::parse_tag_number_or_range($vxlanstr, '16777216');

   return $vxlanstr;
}

sub type {
    return 'vxlanmulticast';
}

sub properties {
    return {
        'vxlan-allowed' => {
            type => 'string', format => 'pve-sdn-vxlanrange',
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
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $uplinks) = @_;

    my $tag = $vnet->{tag};
    my $alias = $vnet->{alias};
    my $multicastaddress = $plugin_config->{'multicast-address'};
    my $uplink = $plugin_config->{'uplink-id'};
    my $vxlanallowed = $plugin_config->{'vxlan-allowed'};

    die "missing vxlan tag" if !$tag;
    my $iface = $uplinks->{$uplink}->{name} ? $uplinks->{$uplink}->{name} : "uplink$uplink";

    my $mtu = 1450;
    $mtu = $uplinks->{$uplink}->{mtu} - 50 if $uplinks->{$uplink}->{mtu};
    $mtu = $vnet->{mtu} if $vnet->{mtu};

    my $config = "\n";
    $config .= "auto vxlan$vnetid\n";
    $config .= "iface vxlan$vnetid inet manual\n";
    $config .= "       vxlan-id $tag\n";
    $config .= "       vxlan-svcnodeip $multicastaddress\n" if $multicastaddress;
    $config .= "       vxlan-physdev $iface\n" if $iface;
    $config .= "       mtu $mtu\n" if $mtu;
    $config .= "\n";
    $config .= "auto $vnetid\n";
    $config .= "iface $vnetid inet manual\n";
    $config .= "        bridge_ports vxlan$vnetid\n";
    $config .= "        bridge_stp off\n";
    $config .= "        bridge_fd 0\n";
    $config .= "        mtu $mtu\n" if $mtu;
    $config .= "        alias $alias\n" if $alias;

    return $config;
}

sub on_delete_hook {
    my ($class, $transportid, $sdn_cfg) = @_;

    # verify that no vnet are associated to this transport
    foreach my $id (keys %{$sdn_cfg->{ids}}) {
	my $sdn = $sdn_cfg->{ids}->{$id};
	die "transport $transportid is used by vnet $id" 
	    if ($sdn->{type} eq 'vnet' && defined($sdn->{transportzone}) && $sdn->{transportzone} eq $transportid);
    }
}

sub on_update_hook {
    my ($class, $transportid, $sdn_cfg) = @_;

    my $transport = $sdn_cfg->{ids}->{$transportid};

    # verify that vxlan-allowed don't conflict with another vxlan-allowed transport

    # verify that vxlan-allowed is matching currently vnet tag in this transport  
    my $vxlanallowed = $transport->{'vxlan-allowed'};
    if ($vxlanallowed) {
	foreach my $id (keys %{$sdn_cfg->{ids}}) {
	    my $sdn = $sdn_cfg->{ids}->{$id};
	    if ($sdn->{type} eq 'vnet' && defined($sdn->{tag})) {
		if(defined($sdn->{transportzone}) && $sdn->{transportzone} eq $transportid) {
		    my $tag = $sdn->{tag};
		    eval {
			PVE::Network::SDN::Plugin::parse_tag_number_or_range($vxlanallowed, '16777216', $tag);
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


