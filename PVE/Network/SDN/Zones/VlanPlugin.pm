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
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $interfaces_config, $config) = @_;
    return "";
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

1;


