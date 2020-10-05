package PVE::Network::SDN::Vnets;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use Net::IP;
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

    my $cfg = {};
    if($running) {
	my $cfg = PVE::Network::SDN::config();
	$cfg = $cfg->{vnets};
    } else {
	$cfg = PVE::Network::SDN::Vnets::config();
    }

    my $vnet = PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $vnetid, 1);

    return $vnet;
}

sub get_subnets {
    my ($vnetid) = @_;

    my $subnets = undef;
    my $subnets_cfg = PVE::Network::SDN::Subnets::config();
    foreach my $subnetid (sort keys %{$subnets_cfg->{ids}}) {
	my $subnet = PVE::Network::SDN::Subnets::sdn_subnets_config($subnets_cfg, $subnetid);
	next if !$subnet->{vnet} || $subnet->{vnet} ne $vnetid;
	$subnets->{$subnetid} = $subnet;
    }
    return $subnets;

}

sub get_next_free_cidr {
    my ($vnetid, $hostname, $description, $ipversion) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
    my $zoneid = $vnet->{zone};
    my $zone = PVE::Network::SDN::Zones::get_zone($zoneid);

    $ipversion = 4 if !$ipversion;
    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);
    my $ip = undef;
    my $subnetcount = 0;

    foreach my $subnetid (sort keys %{$subnets}) {
        my $subnet = $subnets->{$subnetid};
	my $network = $subnet->{network};

	next if $ipversion != Net::IP::ip_get_version($network);
	$subnetcount++;
	if ($zone->{ipam}) {
	    eval {
		$ip = PVE::Network::SDN::Subnets::next_free_ip($zone, $subnetid, $subnet, $hostname, $description);
	    };
	    warn $@ if $@;
	}
	last if $ip;
    }
    die "can't find any free ip" if !$ip && $subnetcount > 0;

    return $ip;
}

sub add_cidr {
    my ($vnetid, $cidr, $hostname, $description) = @_;

    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);
    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
    my $zoneid = $vnet->{zone};
    my $zone = PVE::Network::SDN::Zones::get_zone($zoneid);

    my ($ip, $mask) = split(/\//, $cidr);
    die "ip address is not in cidr format" if !$mask;
    my ($subnetid, $subnet) = PVE::Network::SDN::Subnets::find_ip_subnet($ip, $mask, $subnets);

    PVE::Network::SDN::Subnets::add_ip($zone, $subnetid, $subnet, $ip, $hostname, $description);
}

sub del_cidr {
    my ($vnetid, $cidr, $hostname) = @_;

    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);
    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
    my $zoneid = $vnet->{zone};
    my $zone = PVE::Network::SDN::Zones::get_zone($zoneid);

    my ($ip, $mask) = split(/\//, $cidr);
    die "ip address is not in cidr format" if !$mask;
    my ($subnetid, $subnet) = PVE::Network::SDN::Subnets::find_ip_subnet($ip, $mask, $subnets);

    PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $subnet, $ip, $hostname);
}

1;
