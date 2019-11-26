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
	'vlan-allowed' => {
	    type => 'string', format => 'pve-sdn-vlanrange',
	    description => "Allowed vlan range",
	},
    };
}

sub options {

    return {
	'uplink-id' => { optional => 0 },
        'vlan-allowed' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $uplinks, $config) = @_;

    my $tag = $vnet->{tag};
    my $mtu = $vnet->{mtu};
    my $alias = $vnet->{alias};
    my $uplink = $plugin_config->{'uplink-id'};

    die "missing vlan tag" if !$tag;

    my $iface = $uplinks->{$uplink}->{name};
    $iface = "uplink${uplink}" if !$iface;
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

    # verify that vlan-allowed don't conflict with another vlan-allowed transport

    # verify that vlan-allowed is matching currently vnet tag in this transport
    my $vlanallowed = $transport->{'vlan-allowed'};
    if ($vlanallowed) {
	foreach my $id (keys %{$sdn_cfg->{ids}}) {
	    my $sdn = $sdn_cfg->{ids}->{$id};
	    if ($sdn->{type} eq 'vnet' && defined($sdn->{tag})) {
		if(defined($sdn->{transportzone}) && $sdn->{transportzone} eq $transportid) {
		    my $tag = $sdn->{tag};
		    eval {
			PVE::Network::SDN::Zones::Plugin::parse_tag_number_or_range($vlanallowed, '4096', $tag);
		    };
		    if($@) {
			die "vlan $tag is not allowed in transport $transportid";
		    }
		}
	    }
	}
    }
}

1;


