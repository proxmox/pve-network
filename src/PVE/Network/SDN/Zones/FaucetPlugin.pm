package PVE::Network::SDN::Zones::FaucetPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::VlanPlugin;

use base('PVE::Network::SDN::Zones::VlanPlugin');

sub type {
    return 'faucet';
}

sub properties {
    return {
        'dp-id' => {
            type => 'integer',
            description => 'Faucet dataplane id',
        },
    };
}

sub options {

    return {
	nodes => { optional => 1},
	'dp-id' => { optional => 0 },
#	'uplink-id' => { optional => 0 },
	'controller' => { optional => 0 },
	dns => { optional => 1 },
	reversedns => { optional => 1 },
	dnszone => { optional => 1 },
	ipam => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $uplinks, $controller, $config) = @_;

    my $mtu = $vnet->{mtu};
    my $uplink = $plugin_config->{'uplink-id'};
    my $dpid = $plugin_config->{'dp-id'};
    my $dphex = printf("%x",$dpid);  #fixme :should be 16characters hex

    my $iface = $uplinks->{$uplink}->{name};
    $iface = "uplink${uplink}" if !$iface;

    #tagged interface
    my @iface_config = ();
    push @iface_config, "ovs_type OVSPort";
    push @iface_config, "ovs_bridge $zoneid";
    push @iface_config, "ovs_mtu $mtu" if $mtu;
    push(@{$config->{$iface}}, @iface_config) if !$config->{$iface};

    #vnet bridge
    @iface_config = ();
    push @iface_config, "ovs_port $iface";
    push @iface_config, "ovs_type OVSBridge";
    push @iface_config, "ovs_mtu $mtu" if $mtu;

    push @iface_config, "ovs_extra set bridge $zoneid other-config:datapath-id=$dphex";
    push @iface_config, "ovs_extra set bridge $zoneid other-config:disable-in-band=true";
    push @iface_config, "ovs_extra set bridge $zoneid fail_mode=secure";
    push @iface_config, "ovs_extra set-controller $vnetid tcp:127.0.0.1:6653";

    push(@{$config->{$zoneid}}, @iface_config) if !$config->{$zoneid};

    return $config;
}


1;


