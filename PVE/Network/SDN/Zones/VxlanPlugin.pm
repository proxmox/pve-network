package PVE::Network::SDN::Zones::VxlanPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Tools qw($IPV4RE);
use PVE::INotify;
use PVE::Network::SDN::Controllers::EvpnPlugin;

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
    };
}

sub options {

    return {
        nodes => { optional => 1},
        peers => { optional => 0 },
	mtu => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $interfaces_config, $config) = @_;

    my $tag = $vnet->{tag};
    my $alias = $vnet->{alias};
    my $ipv4 = $vnet->{ipv4};
    my $ipv6 = $vnet->{ipv6};
    my $mac = $vnet->{mac};
    my $multicastaddress = $plugin_config->{'multicast-address'};
    my @peers = split(',', $plugin_config->{'peers'}) if $plugin_config->{'peers'};

    die "missing vxlan tag" if !$tag;

    my ($ifaceip, $iface) = PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers);

    my $mtu = 1450;
    $mtu = $interfaces_config->{$iface}->{mtu} - 50 if $interfaces_config->{$iface}->{mtu};
    $mtu = $vnet->{mtu} if $plugin_config->{mtu};

    #vxlan interface
    my @iface_config = ();
    push @iface_config, "vxlan-id $tag";

    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	push @iface_config, "vxlan_remoteip $address";
    }

    push @iface_config, "mtu $mtu" if $mtu;
    push(@{$config->{"vxlan$vnetid"}}, @iface_config) if !$config->{"vxlan$vnetid"};

    #vnet bridge
    @iface_config = ();
    push @iface_config, "address $ipv4" if $ipv4;
    push @iface_config, "address $ipv6" if $ipv6;
    push @iface_config, "hwaddress $mac" if $mac;
    push @iface_config, "bridge_ports vxlan$vnetid";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};

    return $config;
}

1;


