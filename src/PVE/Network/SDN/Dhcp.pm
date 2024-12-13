package PVE::Network::SDN::Dhcp;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file);

use PVE::Network::SDN;
use PVE::Network::SDN::SubnetPlugin;
use PVE::Network::SDN::Dhcp qw(config);
use PVE::Network::SDN::Ipams;
use PVE::Network::SDN::Subnets qw(sdn_subnets_config config get_dhcp_ranges);
use PVE::Network::SDN::Dhcp::Plugin;
use PVE::Network::SDN::Dhcp::Dnsmasq;

use PVE::INotify qw(nodename);

PVE::Network::SDN::Dhcp::Plugin->init();

PVE::Network::SDN::Dhcp::Dnsmasq->register();
PVE::Network::SDN::Dhcp::Dnsmasq->init();

sub add_mapping {
    my ($vnetid, $mac, $ip4, $ip6) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
    return if !$vnet;

    my $zoneid = $vnet->{zone};
    my $zone = PVE::Network::SDN::Zones::get_zone($zoneid);

    return if !$zone->{ipam} || !$zone->{dhcp};

    my $dhcptype = $zone->{dhcp};

    my $macdb = PVE::Network::SDN::Ipams::read_macdb();
    my $dhcp_plugin = PVE::Network::SDN::Dhcp::Plugin->lookup($dhcptype);
    $dhcp_plugin->add_ip_mapping($zoneid, $macdb, $mac, $ip4, $ip6)
}

sub remove_mapping {
    my ($vnetid, $mac) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
    return if !$vnet;

    my $zoneid = $vnet->{zone};
    my $zone = PVE::Network::SDN::Zones::get_zone($zoneid);

    return if !$zone->{ipam} || !$zone->{dhcp};

    my $dhcp_plugin = PVE::Network::SDN::Dhcp::Plugin->lookup($zone->{dhcp});
    $dhcp_plugin->del_ip_mapping($zoneid, $mac);
}

sub regenerate_config {
    my ($reload) = @_;

    my $cfg = PVE::Network::SDN::running_config();

    my $zone_cfg = $cfg->{zones};
    my $vnet_cfg = $cfg->{vnets};
    my $subnet_cfg = $cfg->{subnets};
    return if !$zone_cfg && !$subnet_cfg;

    my $nodename = PVE::INotify::nodename();

    my $plugins = PVE::Network::SDN::Dhcp::Plugin->lookup_types();

    my $any_zone_needs_dhcp = grep { $_->{dhcp} } values $zone_cfg->{ids}->%*;

    foreach my $plugin_name (@$plugins) {
	my $plugin = PVE::Network::SDN::Dhcp::Plugin->lookup($plugin_name);
	eval { $plugin->before_regenerate(!$any_zone_needs_dhcp) };
	die "Could not run before_regenerate for DHCP plugin $plugin_name $@\n" if $@;
    }

    foreach my $zoneid (sort keys %{$zone_cfg->{ids}}) {
        my $zone = $zone_cfg->{ids}->{$zoneid};
        next if !$zone->{dhcp};

	my $dhcp_plugin_name = $zone->{dhcp};
	my $dhcp_plugin = PVE::Network::SDN::Dhcp::Plugin->lookup($dhcp_plugin_name);

	die "Could not find DHCP plugin: $dhcp_plugin_name" if !$dhcp_plugin;

	eval { $dhcp_plugin->before_configure($zoneid, $zone) };
	die "Could not run before_configure for DHCP server $zoneid $@\n" if $@;

	for my $vnetid (sort keys %{$vnet_cfg->{ids}}) {
	    my $vnet = $vnet_cfg->{ids}->{$vnetid};
	    next if $vnet->{zone} ne $zoneid;

	    my $config = [];
	    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid);

	    foreach my $subnet_id (sort keys %{$subnets}) {
		my $subnet_config = $subnets->{$subnet_id};
		my $dhcp_ranges = PVE::Network::SDN::Subnets::get_dhcp_ranges($subnet_config);

		my ($zone, $subnet_network, $subnet_mask) = split(/-/, $subnet_id);
		next if $zone ne $zoneid;

		eval { $dhcp_plugin->configure_subnet($config, $zoneid, $vnetid, $subnet_config) };
		warn "Could not configure subnet $subnet_id: $@\n" if $@;

		foreach my $dhcp_range (@$dhcp_ranges) {
		    eval { $dhcp_plugin->configure_range($config, $zoneid, $vnetid, $subnet_config, $dhcp_range) };
		    warn "Could not configure DHCP range for $subnet_id: $@\n" if $@;
		}
	    }

	    eval { $dhcp_plugin->configure_vnet($config, $zoneid, $vnetid, $vnet) };
	    warn "Could not configure vnet $vnetid: $@\n" if $@;
	}

	eval { $dhcp_plugin->after_configure($zoneid, !$any_zone_needs_dhcp) };
	warn "Could not run after_configure for DHCP server $zoneid $@\n" if $@;

    }

    foreach my $plugin_name (@$plugins) {
	my $plugin = PVE::Network::SDN::Dhcp::Plugin->lookup($plugin_name);

	eval { $plugin->after_regenerate() };
	warn "Could not run after_regenerate for DHCP plugin $plugin_name $@\n" if $@;
    }
}

1;
