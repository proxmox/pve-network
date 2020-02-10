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
    };
}

sub options {

    return {
        nodes => { optional => 1},
	'tag' => { optional => 0 },
	'bridge' => { optional => 0 },
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

1;


