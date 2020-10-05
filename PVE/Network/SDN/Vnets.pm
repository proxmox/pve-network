package PVE::Network::SDN::Vnets;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use Net::IP;
use PVE::Network::SDN::Subnets;

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

    return keys %{$cfg->{ids}};
}

sub complete_sdn_vnet {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::Vnets::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::Vnets::sdn_vnet_ids($cfg) ];
}

sub get_vnet {
    my ($vnetid) = @_;

    my $cfg = PVE::Network::SDN::Vnets::config();
    my $vnet = PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $vnetid, 1);
    return $vnet;
}

sub get_next_free_ip {
    my ($vnet, $hostname, $ipversion) = @_;

    $ipversion = 4 if !$ipversion;
    my $subnets_cfg = PVE::Network::SDN::Subnets::config();
    my @subnets = PVE::Tools::split_list($vnet->{subnets}) if $vnet->{subnets};
    my $ip = undef;
    my $subnet = undef;
    my $subnetcount = 0;
    foreach my $s (@subnets) {
	my $subnetid = $s =~ s/\//-/r;
	my ($network, $mask) = split(/-/, $subnetid);
	next if $ipversion != Net::IP::ip_get_version($network);
	$subnetcount++;
	$subnet = $subnets_cfg->{ids}->{$subnetid};
	if ($subnet && $subnet->{ipam}) {
	    eval {
		$ip = PVE::Network::SDN::Subnets::next_free_ip($subnetid, $subnet, $hostname);
	    };
	    warn $@ if $@;
	}
	last if $ip;
    }
    die "can't find any free ip" if !$ip && $subnetcount > 0;

    return $ip;
}

sub add_ip {
    my ($vnet, $cidr, $hostname) = @_;

    my ($ip, $mask) = split(/\//, $cidr);
    my ($subnetid, $subnet) = PVE::Network::SDN::Subnets::find_ip_subnet($ip, $vnet->{subnets});
    return if !$subnet->{ipam};

    PVE::Network::SDN::Subnets::add_ip($subnetid, $subnet, $ip, $hostname);
}

sub del_ip {
    my ($vnet, $cidr, $hostname) = @_;

    my ($ip, $mask) = split(/\//, $cidr);
    my ($subnetid, $subnet) = PVE::Network::SDN::Subnets::find_ip_subnet($ip, $vnet->{subnets});
    return if !$subnet->{ipam};

    PVE::Network::SDN::Subnets::del_ip($subnetid, $subnet, $ip, $hostname);
}

1;
