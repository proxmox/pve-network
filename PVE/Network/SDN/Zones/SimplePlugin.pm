package PVE::Network::SDN::Zones::SimplePlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::Plugin;

use base('PVE::Network::SDN::Zones::Plugin');

sub type {
    return 'simple';
}

sub options {

    return {
        nodes => { optional => 1},
	mtu => { optional => 1 }
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $interfaces_config, $config) = @_;

    my $ipv4 = $vnet->{ipv4};
    my $ipv6 = $vnet->{ipv6};
    my $mac = $vnet->{mac};
    my $alias = $vnet->{alias};
    my $mtu = $plugin_config->{mtu} if $plugin_config->{mtu};

    #vnet bridge
    my @iface_config = ();
    push @iface_config, "address $ipv4" if $ipv4;
    push @iface_config, "address $ipv6" if $ipv6;
    push @iface_config, "hwaddress $mac" if $mac;
    push @iface_config, "bridge_ports none";
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

    my $err_msg = [];

    # ifaces to check
    my $ifaces = [ $vnetid];

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


