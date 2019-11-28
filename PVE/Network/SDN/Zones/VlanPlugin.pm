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
	'uplink-id' => {
	    type => 'integer',
	    minimum => 1, maximum => 4096,
	    description => 'Uplink interface',
	},
    };
}

sub options {

    return {
        nodes => { optional => 1},
	'uplink-id' => { optional => 0 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $interfaces_config, $config) = @_;

    my $tag = $vnet->{tag};
    my $mtu = $vnet->{mtu};
    my $alias = $vnet->{alias};
    my $uplink = $plugin_config->{'uplink-id'};

    die "missing vlan tag" if !$tag;

    my $iface = PVE::Network::SDN::Zones::Plugin::get_uplink_iface($interfaces_config, $uplink);

    $iface .= ".$tag";

    #tagged interface
    my @iface_config = ();
    push @iface_config, "mtu $mtu" if $mtu;
    push(@{$config->{$iface}}, @iface_config) if !$config->{$iface};

    #vnet bridge
    @iface_config = ();
    push @iface_config, "bridge_ports $iface";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};

    return $config;
}

1;


