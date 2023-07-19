package PVE::Network::SDN::Zones::QinQPlugin;

use strict;
use warnings;

use PVE::Exception qw(raise raise_param_exc);

use PVE::Network::SDN::Zones::Plugin;

use base('PVE::Network::SDN::Zones::Plugin');

sub type {
    return 'qinq';
}

sub properties {
    return {
	tag => {
	    type => 'integer',
	    minimum => 0,
	    description => "Service-VLAN Tag",
	},
	mtu => {
	    type => 'integer',
	    description => "MTU",
	    optional => 1,
	},
	'vlan-protocol' => {
	    type => 'string',
	    enum => ['802.1q', '802.1ad'],
	    default => '802.1q',
	    optional => 1,
	}
    };
}

sub options {
    return {
	nodes => { optional => 1},
	'tag' => { optional => 0 },
	'bridge' => { optional => 0 },
        'bridge-disable-mac-learning' => { optional => 1 },
	'mtu' => { optional => 1 },
	'vlan-protocol' => { optional => 1 },
	dns => { optional => 1 },
	reversedns => { optional => 1 },
	dnszone => { optional => 1 },
	ipam => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $controller_cfg, $subnet_cfg, $interfaces_config, $config) = @_;

    my ($bridge, $mtu, $stag) = $plugin_config->@{'bridge', 'mtu', 'tag'};
    my $vlanprotocol = $plugin_config->{'vlan-protocol'};

    PVE::Network::SDN::Zones::Plugin::find_bridge($bridge);

    my $vlan_aware = PVE::Network::SDN::Zones::Plugin::is_vlanaware($bridge);
    my $is_ovs = PVE::Network::SDN::Zones::Plugin::is_ovs($bridge);

    my @iface_config = ();
    my $zone_notag_uplink = "ln_${zoneid}";
    my $zone_notag_uplinkpeer = "pr_${zoneid}";
    my $zone = "z_${zoneid}";

    my $vnet_bridge_ports = "";
    if (my $ctag = $vnet->{tag}) {
	$vnet_bridge_ports = "$zone.$ctag";
    } else {
	$vnet_bridge_ports = $zone_notag_uplinkpeer;
    }

    my $zone_bridge_ports = "";
    if ($is_ovs) {
        # ovs--->ovsintport(dot1q-tunnel tag)------->vlanawarebrige-----(tag)--->vnet

	$vlanprotocol = "802.1q" if !$vlanprotocol;
	my $svlan_iface = "sv_".$zoneid;

	# ovs dot1q-tunnel port
	@iface_config = ();
	push @iface_config, "ovs_type OVSIntPort";
	push @iface_config, "ovs_bridge $bridge";
	push @iface_config, "ovs_mtu $mtu" if $mtu;
	push @iface_config, "ovs_options vlan_mode=dot1q-tunnel tag=$stag other_config:qinq-ethtype=$vlanprotocol";
	push(@{$config->{$svlan_iface}}, @iface_config) if !$config->{$svlan_iface};

        # redefine main ovs bridge, ifupdown2 will merge ovs_ports
	@{$config->{$bridge}}[0] = "ovs_ports" if !@{$config->{$bridge}}[0];
	my @ovs_ports = split / / , @{$config->{$bridge}}[0];
	@{$config->{$bridge}}[0] .= " $svlan_iface" if !grep( $_ eq $svlan_iface, @ovs_ports );

	$zone_bridge_ports = $svlan_iface;

    } elsif ($vlan_aware) {
        # VLAN_aware_brige-(tag)----->vlanwarebridge-(tag)----->vnet

	$zone_bridge_ports = "$bridge.$stag";

	if ($vlanprotocol) {
	    @iface_config = ();
	    push @iface_config, "bridge-vlan-protocol $vlanprotocol";
	    push(@{$config->{$bridge}}, @iface_config) if !$config->{$bridge};

	    @iface_config = ();
	    push @iface_config, "vlan-protocol $vlanprotocol";
	    push(@{$config->{$zone_bridge_ports}}, @iface_config) if !$config->{$zone_bridge_ports};
	}

    } else {
	# eth--->eth.x(svlan)----->vlanwarebridge-(tag)----->vnet---->vnet

	my @bridge_ifaces = PVE::Network::SDN::Zones::Plugin::get_bridge_ifaces($bridge);

	for my $bridge_iface (@bridge_ifaces) {
	    # use named vlan interface to avoid too long names
	    my $svlan_iface = "sv_$zoneid";

	    # svlan
	    @iface_config = ();
	    push @iface_config, "vlan-raw-device $bridge_iface";
	    push @iface_config, "vlan-id $stag";
	    push @iface_config, "vlan-protocol $vlanprotocol" if $vlanprotocol;
	    push(@{$config->{$svlan_iface}}, @iface_config) if !$config->{$svlan_iface};

	    $zone_bridge_ports = $svlan_iface;
	    last;
        }
   }

    # veth peer for notag vnet
    @iface_config = ();
    push @iface_config, "link-type veth";
    push @iface_config, "veth-peer-name $zone_notag_uplinkpeer";
    push(@{$config->{$zone_notag_uplink}}, @iface_config) if !$config->{$zone_notag_uplink};

    @iface_config = ();
    push @iface_config, "link-type veth";
    push @iface_config, "veth-peer-name $zone_notag_uplink";
    push(@{$config->{$zone_notag_uplinkpeer}}, @iface_config) if !$config->{$zone_notag_uplinkpeer};

    # zone vlan aware bridge
    @iface_config = ();
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "bridge-stp off";
    push @iface_config, "bridge-ports $zone_bridge_ports $zone_notag_uplink";
    push @iface_config, "bridge-fd 0";
    push @iface_config, "bridge-vlan-aware yes";
    push @iface_config, "bridge-vids 2-4094";
    push(@{$config->{$zone}}, @iface_config) if !$config->{$zone};

    # vnet bridge
    @iface_config = ();
    push @iface_config, "bridge_ports $vnet_bridge_ports";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    if($vnet->{vlanaware}) {
	push @iface_config, "bridge-vlan-aware yes";
	push @iface_config, "bridge-vids 2-4094";
    }
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $vnet->{alias}" if $vnet->{alias};
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};
}

sub status {
    my ($class, $plugin_config, $zone, $vnetid, $vnet, $status) = @_;

    my $bridge = $plugin_config->{bridge};

    if (!-d "/sys/class/net/$bridge") {
	return ["missing $bridge"];
    }

    my $vlan_aware = PVE::Network::SDN::Zones::Plugin::is_vlanaware($bridge);

    my $tag = $vnet->{tag};
    my $vnet_uplink = "ln_".$vnetid;
    my $vnet_uplinkpeer = "pr_".$vnetid;
    my $zone_notag_uplink = "ln_".$zone;
    my $zone_notag_uplinkpeer = "pr_".$zone;
    my $zonebridge = "z_$zone";

    # ifaces to check
    my $ifaces = [ $vnetid, $bridge ];

    push @$ifaces, $zonebridge;
    push @$ifaces, $zone_notag_uplink;
    push @$ifaces, $zone_notag_uplinkpeer;

    if (!$vlan_aware) {
	my $svlan_iface = "sv_$zone";
	push @$ifaces, $svlan_iface;
    }

    return $class->generate_status_message($vnetid, $status, $ifaces);
}

sub vnet_update_hook {
    my ($class, $vnet_cfg, $vnetid, $zone_cfg) = @_;

    my $vnet = $vnet_cfg->{ids}->{$vnetid};

    my $tag = $vnet->{tag};
    raise_param_exc({ tag => "VLAN tag maximal value is 4096" }) if $tag && $tag > 4096;

    # verify that tag is not already defined in another vnet on same zone
    for my $id (sort keys %{$vnet_cfg->{ids}}) {
	next if $id eq $vnetid;
	my $other_vnet = $vnet_cfg->{ids}->{$id};
	next if $vnet->{zone} ne $other_vnet->{zone};
	my $other_tag = $other_vnet->{tag};
	if ($tag) {
	    raise_param_exc({ tag => "tag $tag already exist in zone $vnet->{zone} vnet $id"})
		if $other_tag && $tag eq $other_tag;
	} else {
	    raise_param_exc({ tag => "tag-less vnet already exists in zone $vnet->{zone} vnet $id"})
		if !$other_tag;
	}
    }
}

1;


