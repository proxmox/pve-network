package PVE::Network::SDN::Zones::VlanPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::Plugin;

use base('PVE::Network::SDN::Zones::Plugin');

sub type {
    return 'vlan';
}

PVE::JSONSchema::register_format('pve-sdn-vlanrange', \&pve_verify_sdn_vlanrange);
sub pve_verify_sdn_vlanrange {
   my ($vlanstr) = @_;

   PVE::Network::SDN::Zones::Plugin::parse_tag_number_or_range($vlanstr, '4096');

   return $vlanstr;
}

sub properties {
    return {
	'bridge' => {
	    type => 'string',
	},
    };
}

sub options {

    return {
        nodes => { optional => 1},
	'bridge' => { optional => 0 },
	mtu => { optional => 1 }
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $interfaces_config, $config) = @_;

    my $bridge = $plugin_config->{bridge};
    die "can't find bridge $bridge" if !-d "/sys/class/net/$bridge";

    my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");
    my $is_ovs = !-d "/sys/class/net/$bridge/brif";

    my $tag = $vnet->{tag};
    my $alias = $vnet->{alias};
    my $mtu = $plugin_config->{mtu};

    my $vnet_uplink = "ln_".$vnetid;
    my $vnet_uplinkpeer = "pr_".$vnetid;

    my @iface_config = ();

    if($is_ovs) {

        # keep vmbrXvY for compatibility with existing network
        # eth0----ovs vmbr0--(ovsintport tag)---->vnet---->vm

	@iface_config = ();
	push @iface_config, "ovs_type OVSIntPort";
	push @iface_config, "ovs_bridge $bridge";
	push @iface_config, "ovs_mtu $mtu" if $mtu;
	if($vnet->{vlanaware}) {
	    push @iface_config, "ovs_options vlan_mode=dot1q-tunnel other_config:qinq-ethtype=802.1q tag=$tag";
	} else {
	    push @iface_config, "ovs_options tag=$tag";
	}
	push(@{$config->{$vnet_uplink}}, @iface_config) if !$config->{$vnet_uplink};

	#redefine main ovs bridge, ifupdown2 will merge ovs_ports
	@iface_config = ();
	push @iface_config, "ovs_ports $vnet_uplink";
	push(@{$config->{$bridge}}, @iface_config);

    } elsif ($vlan_aware) {
        # eth0----vlanaware bridge vmbr0--(vmbr0.X tag)---->vnet---->vm
	$vnet_uplink = "$bridge.$tag";
    } else {

        # keep vmbrXvY for compatibility with existing network
        # eth0<---->eth0.X----vmbr0v10------vnet---->vm

	my $bridgevlan = $bridge."v".$tag;

	my @bridge_ifaces = ();
	my $dir = "/sys/class/net/$bridge/brif";
	PVE::Tools::dir_glob_foreach($dir, '(((eth|bond)\d+|en[^.]+)(\.\d+)?)', sub {
	    push @bridge_ifaces, $_[0];
	});

	my $bridge_ports = "";
	foreach my $bridge_iface (@bridge_ifaces) {
	    $bridge_ports .= " $bridge_iface.$tag";
	}

	@iface_config = ();
	push @iface_config, "link-type veth";
	push @iface_config, "veth-peer-name $vnet_uplinkpeer";
	push(@{$config->{$vnet_uplink}}, @iface_config) if !$config->{$vnet_uplink};

	@iface_config = ();
	push @iface_config, "link-type veth";
	push @iface_config, "veth-peer-name $vnet_uplink";
	push(@{$config->{$vnet_uplinkpeer}}, @iface_config) if !$config->{$vnet_uplinkpeer};

	@iface_config = ();
	push @iface_config, "bridge_ports $bridge_ports $vnet_uplinkpeer";
	push @iface_config, "bridge_stp off";
	push @iface_config, "bridge_fd 0";
	push(@{$config->{$bridgevlan}}, @iface_config) if !$config->{$bridgevlan};
    }

    #vnet bridge
    @iface_config = ();
    push @iface_config, "bridge_ports $vnet_uplink";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    if($vnet->{vlanaware}) {
        push @iface_config, "bridge-vlan-aware yes";
        push @iface_config, "bridge-vids 2-4094";
    }
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};

    return $config;
}

sub status {
    my ($class, $plugin_config, $zone, $vnetid, $vnet, $status) = @_;

    my $bridge = $plugin_config->{bridge};

    my $err_msg = [];
    if (!-d "/sys/class/net/$bridge") {
        push @$err_msg, "missing $bridge";
	return $err_msg;
    }

    my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");
    my $is_ovs = !-d "/sys/class/net/$bridge/brif";

    my $tag = $vnet->{tag};
    my $vnet_uplink = "ln_".$vnetid;
    my $vnet_uplinkpeer = "pr_".$vnetid;

    # ifaces to check
    my $ifaces = [ $vnetid, $bridge ];
    if($is_ovs) {
	push @$ifaces, $vnet_uplink;
    } elsif (!$vlan_aware) {
	my $bridgevlan = $bridge."v".$tag;
	push @$ifaces, $bridgevlan;
	push @$ifaces, $vnet_uplink;
	push @$ifaces, $vnet_uplinkpeer;
    }

    foreach my $iface (@{$ifaces}) {
	if (!$status->{$iface}->{status}) {
	    push @$err_msg, "missing $iface";
        } elsif ($status->{$iface}->{status} ne 'pass') {
	    push @$err_msg, "error iface $iface";
	}
    }
    return $err_msg;
}

1;


