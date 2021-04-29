package PVE::Network::SDN::Zones::QinQPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Exception qw(raise raise_param_exc);

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

    my $stag = $plugin_config->{tag};
    my $mtu = $plugin_config->{mtu};
    my $bridge = $plugin_config->{'bridge'};
    my $vlanprotocol = $plugin_config->{'vlan-protocol'};
    my $ctag = $vnet->{tag};
    my $alias = $vnet->{alias};

    PVE::Network::SDN::Zones::Plugin::find_bridge($bridge);

    my $vlan_aware = PVE::Network::SDN::Zones::Plugin::is_vlanaware($bridge);
    my $is_ovs = PVE::Network::SDN::Zones::Plugin::is_ovs($bridge);

    my @iface_config = ();
    my $vnet_bridge_ports = "";

    if($is_ovs) {

        #ovs--->ovsintport(dot1q-tunnel tag)------->vlanawarebrige-----(tag)--->vnet

	$vlanprotocol = "802.1q" if !$vlanprotocol;
	my $svlan_iface = "sv_".$zoneid;
	my $zone = "z_$zoneid";

	#ovs dot1q-tunnel port
	@iface_config = ();
	push @iface_config, "ovs_type OVSIntPort";
	push @iface_config, "ovs_bridge $bridge";
	push @iface_config, "ovs_mtu $mtu" if $mtu;
	push @iface_config, "ovs_options vlan_mode=dot1q-tunnel tag=$stag other_config:qinq-ethtype=$vlanprotocol";
	push(@{$config->{$svlan_iface}}, @iface_config) if !$config->{$svlan_iface};

        #redefine main ovs bridge, ifupdown2 will merge ovs_ports
	@{$config->{$bridge}}[0] = "ovs_ports" if !@{$config->{$bridge}}[0];
	my @ovs_ports = split / / , @{$config->{$bridge}}[0];
	@{$config->{$bridge}}[0] .= " $svlan_iface" if !grep( $_ eq $svlan_iface, @ovs_ports );

	#zone vlan aware bridge
	@iface_config = ();
	push @iface_config, "mtu $mtu" if $mtu;
	push @iface_config, "bridge-stp off";
	push @iface_config, "bridge-ports $svlan_iface";
	push @iface_config, "bridge-fd 0";
	push @iface_config, "bridge-vlan-aware yes";
	push @iface_config, "bridge-vids 2-4094";
	push(@{$config->{$zone}}, @iface_config) if !$config->{$zone};

	$vnet_bridge_ports = "$zone.$ctag";

    } elsif ($vlan_aware) {

        #vlanawarebrige-(tag)----->vlanwarebridge-(tag)----->vnet

	my $zone = "z_$zoneid";

	if($vlanprotocol) {
	    @iface_config = ();
	    push @iface_config, "bridge-vlan-protocol $vlanprotocol";
	    push(@{$config->{$bridge}}, @iface_config) if !$config->{$bridge};
	}

	#zone vlan bridge
	@iface_config = ();
	push @iface_config, "mtu $mtu" if $mtu;
	push @iface_config, "bridge-stp off";
	push @iface_config, "bridge-ports $bridge.$stag";
	push @iface_config, "bridge-fd 0";
	push @iface_config, "bridge-vlan-aware yes";
	push @iface_config, "bridge-vids 2-4094";
	push(@{$config->{$zone}}, @iface_config) if !$config->{$zone};

	$vnet_bridge_ports = "$zone.$ctag";

    } else {

	#eth--->eth.x(svlan)--->eth.x.y(cvlan)---->vnet

	my @bridge_ifaces = PVE::Network::SDN::Zones::Plugin::get_bridge_ifaces($bridge);

	foreach my $bridge_iface (@bridge_ifaces) {

	    # use named vlan interface to avoid too long names
	    my $svlan_iface = "sv_$vnetid";
	    my $cvlan_iface = "cv_$vnetid";

	    #svlan
	    @iface_config = ();
	    push @iface_config, "vlan-raw-device $bridge_iface";
	    push @iface_config, "vlan-id $stag";
	    push @iface_config, "vlan-protocol $vlanprotocol" if $vlanprotocol;
	    push(@{$config->{$svlan_iface}}, @iface_config) if !$config->{$svlan_iface};

	    #cvlan
	    @iface_config = ();
	    push @iface_config, "vlan-raw-device $svlan_iface";
	    push @iface_config, "vlan-id $ctag";
	    push(@{$config->{$cvlan_iface}}, @iface_config) if !$config->{$cvlan_iface};

	    $vnet_bridge_ports .= " $cvlan_iface";
        }
   }

    #vnet bridge
    @iface_config = ();
    push @iface_config, "bridge_ports $vnet_bridge_ports";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    if($vnet->{vlanaware}) {
	push @iface_config, "bridge-vlan-aware yes";
	push @iface_config, "bridge-vids 2-4094";
    }
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};

}

sub status {
    my ($class, $plugin_config, $zone, $vnetid, $vnet, $status) = @_;

    my $bridge = $plugin_config->{bridge};
    my $err_msg = [];

    if (!-d "/sys/class/net/$bridge") {
        push @$err_msg, "missing $bridge";
        return $err_msg;
    }

    my $vlan_aware = PVE::Network::SDN::Zones::Plugin::is_vlanaware($bridge);
    my $is_ovs = PVE::Network::SDN::Zones::Plugin::is_ovs($bridge);

    my $tag = $vnet->{tag};
    my $vnet_uplink = "ln_".$vnetid;
    my $vnet_uplinkpeer = "pr_".$vnetid;

    # ifaces to check
    my $ifaces = [ $vnetid, $bridge ];
    if($is_ovs) {
	my $svlan_iface = "sv_".$zone;
	my $zonebridge = "z_$zone";
	push @$ifaces, $svlan_iface;
	push @$ifaces, $zonebridge;
    } elsif ($vlan_aware) {
	my $zonebridge = "z_$zone";
	push @$ifaces, $zonebridge;
    } else {
	my $svlan_iface = "sv_$vnetid";
	my $cvlan_iface = "cv_$vnetid";
	push @$ifaces, $svlan_iface;
	push @$ifaces, $cvlan_iface;
    }

    foreach my $iface (@{$ifaces}) {
	if (!$status->{$iface}->{status}) {
	    push @$err_msg, "missing $iface";
        } elsif ($status->{$iface}->{status} ne 'pass') {
	    push @$err_msg, "error $iface";
	}
    }
    return $err_msg;
}

sub vnet_update_hook {
    my ($class, $vnet_cfg, $vnetid, $zone_cfg) = @_;

    my $vnet = $vnet_cfg->{ids}->{$vnetid};
    my $tag = $vnet->{tag};

    raise_param_exc({ tag => "missing vlan tag"}) if !defined($vnet->{tag});
    raise_param_exc({ tag => "vlan tag max value is 4096"}) if $vnet->{tag} > 4096;

    # verify that tag is not already defined in another vnet on same zone
    foreach my $id (keys %{$vnet_cfg->{ids}}) {
	next if $id eq $vnetid;
	my $othervnet = $vnet_cfg->{ids}->{$id};
	my $other_tag = $othervnet->{tag};
	next if $vnet->{zone} ne $othervnet->{zone};
        raise_param_exc({ tag => "tag $tag already exist in vnet $id"}) if $other_tag && $tag eq $other_tag;
    }
}

1;


