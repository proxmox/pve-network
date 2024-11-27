package PVE::Network::SDN::Vnets;

use strict;
use warnings;

use Net::IP;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network::SDN;
use PVE::Network::SDN::Dhcp;
use PVE::Network::SDN::Subnets;
use PVE::Network::SDN::Zones;

use PVE::Network::SDN::VnetPlugin;
PVE::Network::SDN::VnetPlugin->register();
PVE::Network::SDN::VnetPlugin->init();

sub sdn_vnets_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn vnet ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn vnet '$id' does not exist\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my ($running) = @_;

    if ($running) {
	my $cfg = PVE::Network::SDN::running_config();
	return $cfg->{vnets};
    }

    return cfs_read_file("sdn/vnets.cfg");
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/vnets.cfg", $cfg);
}

sub sdn_vnets_ids {
    my ($cfg) = @_;

    return sort keys %{$cfg->{ids}};
}

sub complete_sdn_vnet {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::Vnets::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::Vnets::sdn_vnet_ids($cfg) ];
}

sub get_vnet {
    my ($vnetid, $running) = @_;

    return if !$vnetid;

    my $cfg = PVE::Network::SDN::Vnets::config($running);
    return PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $vnetid, 1);
}

sub get_subnets {
    my ($vnetid, $running) = @_;

    my $subnets = undef;
    my $subnets_cfg = PVE::Network::SDN::Subnets::config($running);

    foreach my $subnetid (sort keys %{$subnets_cfg->{ids}}) {
	my $subnet = PVE::Network::SDN::Subnets::sdn_subnets_config($subnets_cfg, $subnetid);
	next if !$subnet->{vnet} || ($vnetid && $subnet->{vnet} ne $vnetid);
	$subnets->{$subnetid} = $subnet;
    }

    return $subnets;
}

sub get_subnet_from_vnet_ip {
    my ($vnetid, $ip) = @_;

    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);
    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
    my $zoneid = $vnet->{zone};
    my $zone = PVE::Network::SDN::Zones::get_zone($zoneid);

    my ($subnetid, $subnet) = PVE::Network::SDN::Subnets::find_ip_subnet($ip, $subnets);

    return ($zone, $subnetid, $subnet, $ip);
}

sub add_next_free_cidr {
    my ($vnetid, $hostname, $mac, $vmid, $skipdns, $dhcprange, $ipversion) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
    return if !$vnet;

    my $zoneid = $vnet->{zone};
    my $zone = PVE::Network::SDN::Zones::get_zone($zoneid);

    return if !$zone->{ipam} || !$zone->{dhcp};

    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);

    my $ips = {};

    my @ipversions = defined($ipversion) ? ($ipversion) : qw/ 4 6 /;
    for my $ipversion (@ipversions) {
	my $ip = undef;
	my $subnetcount = 0;
	foreach my $subnetid (sort keys %{$subnets}) {
	    my $subnet = $subnets->{$subnetid};
	    my $network = $subnet->{network};

	    next if Net::IP::ip_get_version($network) != $ipversion || $ips->{$ipversion};
	    $subnetcount++;

	    eval {
		$ip = PVE::Network::SDN::Subnets::add_next_free_ip($zone, $subnetid, $subnet, $hostname, $mac, $vmid, $skipdns, $subnet->{'dhcp-range'});
	    };
	    die $@ if $@;

	    if ($ip) {
		$ips->{$ipversion} = $ip;
		last;
	    }
	}

	if (!$ip && $subnetcount > 0) {
	    foreach my $version (sort keys %{$ips}) {
		my $ip = $ips->{$version};
		my ($subnetid, $subnet) = PVE::Network::SDN::Subnets::find_ip_subnet($ip, $subnets);

		PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $subnet, $ip, $hostname, $mac, $skipdns);
	    }

	    die "can't find any free ip in zone $zoneid for IPv$ipversion";
	}
    }
}

sub add_ip {
    my ($vnetid, $ip, $hostname, $mac, $vmid, $skipdns) = @_;

    return if !$vnetid;
    
    my ($zone, $subnetid, $subnet) = PVE::Network::SDN::Vnets::get_subnet_from_vnet_ip($vnetid, $ip);
    PVE::Network::SDN::Subnets::add_ip($zone, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, undef, $skipdns);
}

sub update_ip {
    my ($vnetid, $ip, $hostname, $oldhostname, $mac, $vmid, $skipdns) = @_;

    return if !$vnetid;

    my ($zone, $subnetid, $subnet) = PVE::Network::SDN::Vnets::get_subnet_from_vnet_ip($vnetid, $ip);
    PVE::Network::SDN::Subnets::update_ip($zone, $subnetid, $subnet, $ip, $hostname, $oldhostname, $mac, $vmid, $skipdns);
}

sub del_ip {
    my ($vnetid, $ip, $hostname, $mac, $skipdns) = @_;

    return if !$vnetid;

    my ($zone, $subnetid, $subnet) = PVE::Network::SDN::Vnets::get_subnet_from_vnet_ip($vnetid, $ip);
    PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $subnet, $ip, $hostname, $mac, $skipdns);
}

sub get_ips_from_mac {
    my ($vnetid, $mac) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
    return if !$vnet;

    my $zoneid = $vnet->{zone};
    my $zone = PVE::Network::SDN::Zones::get_zone($zoneid);

    return if !$zone->{ipam} || !$zone->{dhcp};

    return PVE::Network::SDN::Ipams::get_ips_from_mac($mac, $zoneid, $zone);
}

sub del_ips_from_mac {
    my ($vnetid, $mac, $hostname) = @_;

    my ($ip4, $ip6) = PVE::Network::SDN::Vnets::get_ips_from_mac($vnetid, $mac);
    PVE::Network::SDN::Vnets::del_ip($vnetid, $ip4, $hostname, $mac) if $ip4;
    PVE::Network::SDN::Vnets::del_ip($vnetid, $ip6, $hostname, $mac) if $ip6;

    return ($ip4, $ip6);
}

sub add_dhcp_mapping {
    my ($vnetid, $mac, $vmid, $name) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
    return if !$vnet;
    my $zoneid = $vnet->{zone};
    my $zone = PVE::Network::SDN::Zones::get_zone($zoneid);

    return if !$zone->{ipam} || !$zone->{dhcp};

    my ($ip4, $ip6) = PVE::Network::SDN::Vnets::get_ips_from_mac($vnetid, $mac);
    add_next_free_cidr($vnetid, $name, $mac, "$vmid", undef, 1, 4) if ! $ip4;
    add_next_free_cidr($vnetid, $name, $mac, "$vmid", undef, 1, 6) if ! $ip6;

    ($ip4, $ip6) = PVE::Network::SDN::Vnets::get_ips_from_mac($vnetid, $mac);
    PVE::Network::SDN::Dhcp::add_mapping($vnetid, $mac, $ip4, $ip6) if $ip4 || $ip6;
}

1;
