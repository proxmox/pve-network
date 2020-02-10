package PVE::Network::SDN::Zones::QinQPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::VlanPlugin;

use base('PVE::Network::SDN::Zones::VlanPlugin');

sub type {
    return 'qinq';
}

sub properties {
    return {
        tag => {
            type => 'integer',
            description => "vlan tag",
        },
	mtu => {
	    type => 'integer',
	    description => "mtu",
	    optional => 1,
	},
    };
}

sub options {

    return {
        nodes => { optional => 1},
	'tag' => { optional => 0 },
	'bridge' => { optional => 0 },
	'mtu' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $interfaces_config, $config) = @_;

    my $tag = $plugin_config->{tag};
    my $mtu = $plugin_config->{mtu};
    my $bridge = $plugin_config->{'bridge'};

    die "missing vlan tag" if !$tag;

    if (!$config->{$zoneid}) {
	#zone vlan bridge
	my @iface_config = ();
	push @iface_config, "mtu $mtu" if $mtu;
	push @iface_config, "bridge-stp off";
	push @iface_config, "bridge-fd 0";
	push @iface_config, "bridge-vlan-aware yes";
	push @iface_config, "bridge-vids 2-4094";
	push(@{$config->{$zoneid}}, @iface_config);

	#main bridge. ifupdown2 will merge it
	@iface_config = ();
	push @iface_config, "bridge-ports $zoneid.$tag";
	push(@{$config->{$bridge}}, @iface_config);
	return $config;
    }
}

sub status {
    my ($class, $plugin_config, $zone, $id, $vnet, $err_config, $status, $vnet_status, $zone_status) = @_;

    my $bridge = $plugin_config->{bridge};
    $vnet_status->{$id}->{zone} = $zone;
    $zone_status->{$zone}->{status} = 'available' if !defined($zone_status->{$zone}->{status});

    if($err_config) {
	$vnet_status->{$id}->{status} = 'pending';
	$vnet_status->{$id}->{statusmsg} = $err_config;
	$zone_status->{$zone}->{status} = 'pending';
    } elsif ($status->{$bridge}->{status} && $status->{$bridge}->{status} eq 'pass') {
	$vnet_status->{$id}->{status} = 'available';
    } else {
	$vnet_status->{$id}->{status} = 'error';
	$vnet_status->{$id}->{statusmsg} = 'missing bridge';
	$zone_status->{$zone}->{status} = 'error';
    }
}

sub get_bridge_vlan {
    my ($class, $plugin_config, $zoneid, $vnetid, $tag) = @_;

    my $bridge = $plugin_config->{bridge};
    die "bridge $bridge is missing" if !-d "/sys/class/net/$bridge/";

    my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");
    my $is_ovs = 1 if !-d "/sys/class/net/$bridge/brif";

    die "ovs $bridge is not supported by qinq" if $is_ovs;
    die "bridge $bridge is not vlan aware" if !$vlan_aware;

    return ($bridge, $tag);
}

1;


