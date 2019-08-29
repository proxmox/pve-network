package PVE::Network::SDN::VlanPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Plugin;

use base('PVE::Network::SDN::Plugin');

sub type {
    return 'vlan';
}

PVE::JSONSchema::register_format('pve-sdn-vlanrange', \&pve_verify_sdn_vlanrange);
sub pve_verify_sdn_vlanrange {
   my ($vlanstr) = @_;

   PVE::Network::SDN::Plugin::parse_tag_number_or_range($vlanstr, '4096');

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
	'vlan-aware' => {
            type => 'boolean',
	    description => "enable 802.1q stacked vlan",
	},
	'vlan-protocol' => {
	    type => 'string',
            enum => ['802.1q', '802.1ad'],
	    default => '802.1q',
	    optional => 1,
	    description => "vlan protocol",
	}
    };
}

sub options {

    return {
	'uplink-id' => { optional => 0 },
        'vlan-allowed' => { optional => 1 },
	'vlan-protocol' => { optional => 1 },
	'vlan-aware' => { optional => 1 },

    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $uplinks, $config) = @_;

    my $tag = $vnet->{tag};
    my $mtu = $vnet->{mtu};
    my $alias = $vnet->{alias};
    my $vlanaware = $plugin_config->{'vlan-aware'};
    my $vlanprotocol = $plugin_config->{'vlan-protocol'};
    my $uplink = $plugin_config->{'uplink-id'};
    my $vlanallowed = $plugin_config->{'vlan-allowed'};

    die "missing vlan tag" if !$tag;

    my $iface = $uplinks->{$uplink}->{name};
    $iface = "uplink${uplink}" if !$iface;
    $iface .= ".$tag";

    #tagged interface
    my @iface_config = ();
    push @iface_config, "vlan-protocol $vlanprotocol" if $vlanprotocol;
    push @iface_config, "mtu $mtu" if $mtu;
    push(@{$config->{$iface}}, @iface_config) if !$config->{$iface};

    #vnet bridge
    @iface_config = ();
    push @iface_config, "bridge_ports $iface";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    push @iface_config, "bridge-vlan-aware yes" if $vlanaware;
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
			PVE::Network::SDN::Plugin::parse_tag_number_or_range($vlanallowed, '4096', $tag);
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


