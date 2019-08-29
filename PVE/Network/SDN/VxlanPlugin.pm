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
	'router' => {
	    type => 'string',
	    description => "Frr router name",
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
        'router' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $uplinks, $config) = @_;

    my $tag = $vnet->{tag};
    my $alias = $vnet->{alias};
    my $ipv4 = $vnet->{ipv4};
    my $ipv6 = $vnet->{ipv6};
    my $mac = $vnet->{mac};
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

    #vxlan interface
    my @iface_config = ();
    push @iface_config, "vxlan-id $tag";

    if($multicastaddress) {
	push @iface_config, "vxlan-svcnodeip $multicastaddress";
	push @iface_config, "vxlan-physdev $iface";
    } elsif (@unicastaddress) {

	foreach my $address (@unicastaddress) {
	    next if $address eq $ifaceip;
	    push @iface_config, "vxlan_remoteip $address";
	}
    } else {
	push @iface_config, "vxlan-local-tunnelip $ifaceip" if $ifaceip;
	push @iface_config, "bridge-learning off";
	push @iface_config, "bridge-arp-nd-suppress on";
    }

    push @iface_config, "mtu $mtu" if $mtu;
    push(@{$config->{"vxlan$vnetid"}}, @iface_config) if !$config->{"vxlan$vnetid"};

    #vnet bridge
    @iface_config = ();
    push @iface_config, "address $ipv4" if $ipv4;
    push @iface_config, "address $ipv6" if $ipv6;
    push @iface_config, "hwaddress $mac" if $mac;
    push @iface_config, "bridge_ports vxlan$vnetid";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push @iface_config, "vrf $vrf" if $vrf;
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};

    if ($vrf) {
	#vrf intreface
	@iface_config = ();
	push @iface_config, "vrf-table auto";
	push(@{$config->{$vrf}}, @iface_config) if !$config->{$vrf};

	if ($vrfvxlan) {
	    #l3vni vxlan interface
	    my $iface_vxlan = "vxlan$vrf";
	    @iface_config = ();
	    push @iface_config, "vxlan-id $vrfvxlan";
	    push @iface_config, "vxlan-local-tunnelip $ifaceip" if $ifaceip;
	    push @iface_config, "bridge-learning off";
	    push @iface_config, "bridge-arp-nd-suppress on";
	    push @iface_config, "mtu $mtu" if $mtu;
	    push(@{$config->{$iface_vxlan}}, @iface_config) if !$config->{$iface_vxlan};

	    #l3vni bridge
	    my $brvrf = "br$vrf";
	    @iface_config = ();
	    push @iface_config, "bridge-ports $iface_vxlan";
	    push @iface_config, "bridge_stp off";
	    push @iface_config, "bridge_fd 0";
	    push @iface_config, "mtu $mtu" if $mtu;
	    push @iface_config, "vrf $vrf";
	    push(@{$config->{$brvrf}}, @iface_config) if !$config->{$brvrf};
	}
    }

    return $config;
}

sub generate_frr_config {
    my ($class, $plugin_config, $asn, $id, $uplinks, $config) = @_;

    my $vrf = $plugin_config->{'vrf'};
    my $vrfvxlan = $plugin_config->{'vrf-vxlan'};
    return if !$vrf || !$vrfvxlan;

    my $uplink = $plugin_config->{'uplink-id'};

    my $iface = "uplink$uplink";
    my $ifaceip = "";

    if($uplinks->{$uplink}->{name}) {
        $iface = $uplinks->{$uplink}->{name};
        $ifaceip = PVE::Network::SDN::Plugin::get_first_local_ipv4_from_interface($iface);
    }

    #vrf
    my @router_config = ();
    push @router_config, "vni $vrfvxlan";
    push @router_config, "exit-vrf";
    push(@{$config->{vrf}->{"vrf $vrf"}}, @router_config);


    #vrf router
    @router_config = ();
    push @router_config, "bgp router-id $ifaceip";
    push @router_config, "!";
    push @router_config, "address-family ipv4 unicast";
    push @router_config, " redistribute connected";
    push @router_config, "exit-address-family";
    push @router_config, "!";
    push @router_config, "address-family l2vpn evpn";
    push @router_config, " advertise ipv4 unicast";
    push @router_config, "exit-address-family";
    push(@{$config->{router}->{"router bgp $asn vrf $vrf"}}, @router_config);

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

    # verify that router exist
    if (defined($sdn_cfg->{ids}->{$transportid}->{router})) {
	my $router = $sdn_cfg->{ids}->{$transportid}->{router};
	if (!defined($sdn_cfg->{ids}->{$router})) {
	    die "router $router don't exist";
	} else {
	    die "$router is not a router type" if $sdn_cfg->{ids}->{$router}->{type} ne 'frr';
	}

	#vrf && vrf-vxlan need to be defined with router
	my $vrf = $sdn_cfg->{ids}->{$transportid}->{vrf};
	if (!defined($vrf)) {
	    die "missing vrf option";
	} else {
	    # verify that vrf is not already declared in another transport
	    foreach my $id (keys %{$sdn_cfg->{ids}}) {
		next if $id eq $transportid;
		die "vrf $vrf is already declared in $id"
			if (defined($sdn_cfg->{ids}->{$id}->{vrf}) && $sdn_cfg->{ids}->{$id}->{vrf} eq $vrf);
	    }
	}

	my $vrfvxlan = $sdn_cfg->{ids}->{$transportid}->{'vrf-vxlan'};
	if (!defined($vrfvxlan)) {
	    die "missing vrf-vxlan option";
	} else {
	    # verify that vrf-vxlan is not already declared in another transport
	    foreach my $id (keys %{$sdn_cfg->{ids}}) {
		next if $id eq $transportid;
		die "vrf-vxlan $vrfvxlan is already declared in $id"
			if (defined($sdn_cfg->{ids}->{$id}->{'vrf-vxlan'}) && $sdn_cfg->{ids}->{$id}->{'vrf-vxlan'} eq $vrfvxlan);
	    }
	}
    } 
}

1;


