package PVE::Network::SDN::VxlanPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Plugin;
use PVE::Tools;

use base('PVE::Network::SDN::Plugin');

PVE::JSONSchema::register_format('pve-sdn-vxlanrange', \&pve_verify_sdn_vxlanrange);
sub pve_verify_sdn_vxlanrange {
   my ($vxlanstr) = @_;

   PVE::Network::SDN::Plugin::parse_tag_number_or_range($vxlanstr, '16777216');

   return $vxlanstr;
}

sub type {
    return 'vxlan';
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
	'unicast-address' => {
	    description => "Unicast peers address ip list.",
	    type => 'string',  #fixme: format 
	},
	'vrf' => {
	    description => "vrf name.",
	    type => 'string',  #fixme: format 
	},
	'vrf-vxlan' => {
	    type => 'integer',
	    description => "l3vni.",
	},
    };
}

sub options {

    return {
	'uplink-id' => { optional => 0 },
        'multicast-address' => { optional => 1 },
        'unicast-address' => { optional => 1 },
        'vxlan-allowed' => { optional => 1 },
        'vrf' => { optional => 1 },
        'vrf-vxlan' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $uplinks) = @_;

    my $tag = $vnet->{tag};
    my $alias = $vnet->{alias};
    my $multicastaddress = $plugin_config->{'multicast-address'};
    my @unicastaddress = split(',', $plugin_config->{'unicast-address'}) if $plugin_config->{'unicast-address'};

    my $uplink = $plugin_config->{'uplink-id'};
    my $vxlanallowed = $plugin_config->{'vxlan-allowed'};
    my $vrf = $plugin_config->{'vrf'};
    my $vrfvxlan = $plugin_config->{'vrf-vxlan'};

    die "missing vxlan tag" if !$tag;
    my $iface = "uplink$uplink";
    my $ifaceip = "";

    if($uplinks->{$uplink}->{name}) {
	$iface = $uplinks->{$uplink}->{name};
	$ifaceip = PVE::Network::SDN::Plugin::get_first_local_ipv4_from_interface($iface);
    }

    my $mtu = 1450;
    $mtu = $uplinks->{$uplink}->{mtu} - 50 if $uplinks->{$uplink}->{mtu};
    $mtu = $vnet->{mtu} if $vnet->{mtu};

    my $config = "\n";
    $config .= "auto vxlan$vnetid\n";
    $config .= "iface vxlan$vnetid inet manual\n";
    $config .= "       vxlan-id $tag\n";

    if($multicastaddress) {
	$config .= "       vxlan-svcnodeip $multicastaddress\n";
	$config .= "       vxlan-physdev $iface\n";
    } elsif (@unicastaddress) {

	foreach my $address (@unicastaddress) {
	    next if $address eq $ifaceip;
	    $config .= "       vxlan_remoteip $address\n";
	}
    } else {
	$config .= "       vxlan-local-tunnelip $ifaceip\n" if $ifaceip;
	$config .= "       bridge-learning off\n";
	$config .= "       bridge-arp-nd-suppress on\n";
    }

    $config .= "       mtu $mtu\n" if $mtu;
    $config .= "\n";
    $config .= "auto $vnetid\n";
    $config .= "iface $vnetid inet manual\n";
    $config .= "       bridge_ports vxlan$vnetid\n";
    $config .= "       bridge_stp off\n";
    $config .= "       bridge_fd 0\n";
    $config .= "       mtu $mtu\n" if $mtu;
    $config .= "       alias $alias\n" if $alias;
    $config .= "       vrf $vrf\n" if $vrf;

    if ($vrf) {
	$config .= "\n";
	$config .= "auto $vrf\n";
	$config .= "iface $vrf\n";
	$config .= "       vrf-table auto\n";

	if ($vrfvxlan) {

	    my $vxlanvrf = "vxlan$vrf";
	    my $brvrf = "br$vrf";

	    $config .= "\n";
	    $config .= "auto $vxlanvrf\n";
	    $config .= "iface $vxlanvrf\n";
	    $config .= "	vxlan-id $vrfvxlan\n";
	    $config .= "	vxlan-local-tunnelip $ifaceip\n" if $ifaceip;
	    $config .= "	bridge-learning off\n";
	    $config .= "	bridge-arp-nd-suppress on\n";
	    $config .= "	mtu $mtu\n" if $mtu;

	    $config .= "\n";
	    $config .= "auto $brvrf\n";
	    $config .= "	bridge-ports $vxlanvrf\n";
	    $config .= "	bridge_stp off\n";
	    $config .= "	bridge_fd 0\n";
	    $config .= "	mtu $mtu\n" if $mtu;
	    $config .= "	vrf $vrf\n";
	}
    }

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


