package PVE::Network::SDN::Zones::VxlanPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Tools qw($IPV4RE);
use PVE::INotify;
use PVE::Network::SDN::Controllers::EvpnPlugin;
use PVE::Exception qw(raise raise_param_exc);

use base('PVE::Network::SDN::Zones::Plugin');

PVE::JSONSchema::register_format('pve-sdn-vxlanrange', \&pve_verify_sdn_vxlanrange);
sub pve_verify_sdn_vxlanrange {
   my ($vxlanstr) = @_;

   PVE::Network::SDN::Zones::Plugin::parse_tag_number_or_range($vxlanstr, '16777216');

   return $vxlanstr;
}

sub type {
    return 'vxlan';
}

sub properties {
    return {
        'peers' => {
            description => "peers address list.",
            type => 'string', format => 'ip-list'
        },
        'vxlan-port' => {
            description => "Vxlan tunnel udp port (default 4789).",
            minimum => 1,
            maximum => 65536,
            type => 'integer'
        },
    };
}

sub options {
    return {
	nodes => { optional => 1},
	peers => { optional => 0 },
	'vxlan-port' => { optional => 1 },
	mtu => { optional => 1 },
	dns => { optional => 1 },
	reversedns => { optional => 1 },
	dnszone => { optional => 1 },
	ipam => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $controller_cfg, $subnet_cfg, $interfaces_config, $config) = @_;

    my $tag = $vnet->{tag};
    my $alias = $vnet->{alias};
    my $multicastaddress = $plugin_config->{'multicast-address'};
    my $vxlanport = $plugin_config->{'vxlan-port'};
    my @peers;
    @peers = PVE::Tools::split_list($plugin_config->{'peers'}) if $plugin_config->{'peers'};
    my $vxlan_iface = "vxlan_$vnetid";

    die "missing vxlan tag" if !$tag;

    my ($ifaceip, $iface) = PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers);

    my $mtu = 1450;
    $mtu = $interfaces_config->{$iface}->{mtu} - 50 if $interfaces_config->{$iface}->{mtu};
    $mtu = $plugin_config->{mtu} if $plugin_config->{mtu};

    #vxlan interface
    my @iface_config = ();
    push @iface_config, "vxlan-id $tag";

    for my $address (@peers) {
	next if $address eq $ifaceip;
	push @iface_config, "vxlan_remoteip $address";
    }
    push @iface_config, "vxlan-port $vxlanport" if $vxlanport;


    push @iface_config, "mtu $mtu" if $mtu;
    push(@{$config->{$vxlan_iface}}, @iface_config) if !$config->{$vxlan_iface};

    #vnet bridge
    @iface_config = ();
    push @iface_config, "bridge_ports $vxlan_iface";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    if ($vnet->{vlanaware}) {
	push @iface_config, "bridge-vlan-aware yes";
	push @iface_config, "bridge-vids 2-4094";
    }
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};

    return $config;
}

sub vnet_update_hook {
    my ($class, $vnet_cfg, $vnetid, $zone_cfg) = @_;

    my $vnet = $vnet_cfg->{ids}->{$vnetid};
    my $tag = $vnet->{tag};

    raise_param_exc({ tag => "missing vxlan tag"}) if !defined($tag);
    raise_param_exc({ tag => "vxlan tag max value is 16777216"}) if $tag > 16777216;

    # verify that tag is not already defined globally (vxlan-id are unique)
    for my $id (sort keys %{$vnet_cfg->{ids}}) {
	next if $id eq $vnetid;
	my $othervnet = $vnet_cfg->{ids}->{$id};
	my $other_tag = $othervnet->{tag};
	my $other_zoneid = $othervnet->{zone};
	my $other_zone = $zone_cfg->{ids}->{$other_zoneid};
	next if $other_zone->{type} ne 'vxlan' && $other_zone->{type} ne 'evpn';
	raise_param_exc({ tag => "vxlan tag $tag already exist in vnet $id in zone $other_zoneid "}) if $other_tag && $tag eq $other_tag;
    }
}

1;


