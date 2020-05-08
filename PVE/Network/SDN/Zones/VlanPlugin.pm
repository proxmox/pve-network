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
    my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");
    my $is_ovs = 1 if !-d "/sys/class/net/$bridge/brif";
    return if $vlan_aware || $is_ovs;

    my $tag = $vnet->{tag};
    my $alias = $vnet->{alias};
    my $mtu = $plugin_config->{mtu} if $plugin_config->{mtu};
    my $bridgevlan = $bridge."v".$tag;

    my @bridge_ifaces = ();
    my $dir = "/sys/class/net/$bridge/brif";
    PVE::Tools::dir_glob_foreach($dir, '(((eth|bond)\d+|en[^.]+)(\.\d+)?)', sub {
        push @bridge_ifaces, $_[0];
    });

    my $bridge_ports = "";
    $bridge_ports = "none" if scalar(@bridge_ifaces) == 0;

    foreach my $bridge_iface (@bridge_ifaces) {
	$bridge_ports .= " $bridge_iface.$tag";
    }

    #vnet bridge (keep vmbrXvY for compatibility)
    my @iface_config = ();
    push @iface_config, "bridge_ports $bridge_ports";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push(@{$config->{$bridgevlan}}, @iface_config) if !$config->{$vnetid};

    return $config;
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
    my ($class, $plugin_config, $vnetid, $tag) = @_;

    my $bridge = $plugin_config->{bridge};

    die "bridge $bridge is missing" if !-d "/sys/class/net/$bridge/";

    my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");
    my $is_ovs = 1 if !-d "/sys/class/net/$bridge/brif";

    
    return ($bridge."v".$tag, undef) if !$is_ovs && !$vlan_aware;

    return ($bridge, $tag);
}

1;


