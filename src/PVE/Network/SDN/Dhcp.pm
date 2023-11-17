package PVE::Network::SDN::Dhcp;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file);

use PVE::Network::SDN;
use PVE::Network::SDN::SubnetPlugin;
use PVE::Network::SDN::Dhcp qw(config);
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

    my $dhcp_plugin = PVE::Network::SDN::Dhcp::Plugin->lookup($zone->{dhcp});
    $dhcp_plugin->add_ip_mapping($zoneid, $mac, $ip4) if $ip4;
    $dhcp_plugin->add_ip_mapping($zoneid, $mac, $ip6) if $ip6;
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
    my $subnet_cfg = $cfg->{subnets};
    return if !$zone_cfg && !$subnet_cfg;

    my $nodename = PVE::INotify::nodename();

    my $plugins = PVE::Network::SDN::Dhcp::Plugin->lookup_types();

    foreach my $plugin_name (@$plugins) {
	my $plugin = PVE::Network::SDN::Dhcp::Plugin->lookup($plugin_name);
	eval { $plugin->before_regenerate() };
	die "Could not run before_regenerate for DHCP plugin $plugin_name $@\n" if $@;
    }

    foreach my $zoneid (sort keys %{$zone_cfg->{ids}}) {
        my $zone = $zone_cfg->{ids}->{$zoneid};
        next if !$zone->{dhcp};

	my $dhcp_plugin_name = $zone->{dhcp};
	my $dhcp_plugin = PVE::Network::SDN::Dhcp::Plugin->lookup($dhcp_plugin_name);

	die "Could not find DHCP plugin: $dhcp_plugin_name" if !$dhcp_plugin;

	eval { $dhcp_plugin->before_configure($zoneid) };
	die "Could not run before_configure for DHCP server $zoneid $@\n" if $@;


	foreach my $subnet_id (keys %{$subnet_cfg->{ids}}) {
	    my $subnet_config = PVE::Network::SDN::Subnets::sdn_subnets_config($subnet_cfg, $subnet_id);
	    my $dhcp_ranges = PVE::Network::SDN::Subnets::get_dhcp_ranges($subnet_config);

	    my ($zone, $subnet_network, $subnet_mask) = split(/-/, $subnet_id);
	    next if $zone ne $zoneid;
	    next if !$dhcp_ranges;

	    eval { $dhcp_plugin->configure_subnet($zoneid, $subnet_config) };
	    warn "Could not configure subnet $subnet_id: $@\n" if $@;

	    foreach my $dhcp_range (@$dhcp_ranges) {
		eval { $dhcp_plugin->configure_range($zoneid, $subnet_config, $dhcp_range) };
		warn "Could not configure DHCP range for $subnet_id: $@\n" if $@;
	    }
	}

	eval { $dhcp_plugin->after_configure($zoneid) };
	warn "Could not run after_configure for DHCP server $zoneid $@\n" if $@;

    }

    foreach my $plugin_name (@$plugins) {
	my $plugin = PVE::Network::SDN::Dhcp::Plugin->lookup($plugin_name);

	eval { $plugin->after_regenerate() };
	warn "Could not run after_regenerate for DHCP plugin $plugin_name $@\n" if $@;
    }
}

1;
