package PVE::Network::SDN::Subnets;

use strict;
use warnings;

use Net::Subnet qw(subnet_matcher);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use Net::IP;

use PVE::Network::SDN::Ipams;
use PVE::Network::SDN::Dns;
use PVE::Network::SDN::SubnetPlugin;
PVE::Network::SDN::SubnetPlugin->register();
PVE::Network::SDN::SubnetPlugin->init();

sub sdn_subnets_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn subnet ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn subnet '$id' does not exist\n" if (!$noerr && !$scfg);

    if($scfg) {
	my ($zone, $network, $mask) = split(/-/, $id);
	$scfg->{cidr} = "$network/$mask";
	$scfg->{zone} = $zone;
	$scfg->{network} = $network;
	$scfg->{mask} = $mask;
    }

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn/subnets.cfg");
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/subnets.cfg", $cfg);
}

sub sdn_subnets_ids {
    my ($cfg) = @_;

    return sort keys %{$cfg->{ids}};
}

sub complete_sdn_subnet {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::Subnets::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::Subnets::sdn_subnets_ids($cfg) ];
}

sub get_subnet {
    my ($subnetid, $running) = @_;

    my $cfg = {};
    if($running) {
	my $cfg = PVE::Network::SDN::config();
	$cfg = $cfg->{subnets};
    } else {
	$cfg = PVE::Network::SDN::Subnets::config();
    }

    my $subnet = PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $subnetid, 1);
    return $subnet;
}

sub find_ip_subnet {
    my ($ip, $mask, $subnets) = @_;

    my $subnet = undef;
    my $subnetid = undef;

    foreach my $id (sort keys %{$subnets}) {

	next if $mask ne $subnets->{$id}->{mask};
	my $cidr = $subnets->{$id}->{cidr};
	my $subnet_matcher = subnet_matcher($cidr);
	next if !$subnet_matcher->($ip);
	$subnet = $subnets->{$id};
	$subnetid = $id;
	last;
    }
    die  "can't find any subnet for ip $ip" if !$subnet;

    return ($subnetid, $subnet);
}

my $verify_dns_zone = sub {
    my ($zone, $dns) = @_;

    return if !$zone || !$dns;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->verify_zone($plugin_config, $zone);
};

my $get_reversedns_zone = sub {
    my ($subnetid, $subnet, $dns, $ip) = @_;

    return if !$subnetid || !$dns || !$ip;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->get_reversedns_zone($plugin_config, $subnetid, $subnet, $ip);
};

my $add_dns_record = sub {
    my ($zone, $dns, $hostname, $dnszoneprefix, $ip) = @_;
    return if !$zone || !$dns || !$hostname || !$ip;

    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->add_a_record($plugin_config, $zone, $hostname, $ip);

};

my $add_dns_ptr_record = sub {
    my ($reversezone, $zone, $dns, $hostname, $dnszoneprefix, $ip) = @_;

    return if !$zone || !$reversezone || !$dns || !$hostname || !$ip;

    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;
    $hostname .= ".$zone";
    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->add_ptr_record($plugin_config, $reversezone, $hostname, $ip);
};

my $del_dns_record = sub {
    my ($zone, $dns, $hostname, $dnszoneprefix, $ip) = @_;

    return if !$zone || !$dns || !$hostname || !$ip;

    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->del_a_record($plugin_config, $zone, $hostname, $ip);
};

my $del_dns_ptr_record = sub {
    my ($reversezone, $dns, $ip) = @_;

    return if !$reversezone || !$dns || !$ip;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->del_ptr_record($plugin_config, $reversezone, $ip);
};

sub next_free_ip {
    my ($zone, $subnetid, $subnet, $hostname) = @_;

    my $cidr = undef;
    my $ip = undef;

    my $ipamid = $zone->{ipam};
    my $dns = $zone->{dns};
    my $dnszone = $zone->{dnszone};
    my $reversedns = $zone->{reversedns};
    my $dnszoneprefix = $subnet->{dnszoneprefix};

    #verify dns zones before ipam
    &$verify_dns_zone($dnszone, $dns);

    if($ipamid) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	eval {
	    $cidr = $plugin->add_next_freeip($plugin_config, $subnetid, $subnet);
	    ($ip, undef) = split(/\//, $cidr);
	};
	die $@ if $@;
    }

    eval {
	my $reversednszone = &$get_reversedns_zone($subnetid, $subnet, $reversedns, $ip);

	#add dns
	&$add_dns_record($dnszone, $dns, $hostname, $dnszoneprefix, $ip);
	#add reverse dns
	&$add_dns_ptr_record($reversednszone, $dnszone, $reversedns, $hostname, $dnszoneprefix, $ip);
    };
    if ($@) {
	#rollback
	my $err = $@;
	eval {
	    PVE::Network::SDN::Subnets::del_ip($subnetid, $subnet, $ip, $hostname)
	};
	die $err;
    }
    return $cidr;
}

sub add_ip {
    my ($zone, $subnetid, $subnet, $ip, $hostname) = @_;

    return if !$subnet || !$ip; 

    my $ipamid = $zone->{ipam};
    my $dns = $zone->{dns};
    my $dnszone = $zone->{dnszone};
    my $reversedns = $zone->{reversedns};
    my $reversednszone = &$get_reversedns_zone($subnetid, $subnet, $reversedns, $ip);
    my $dnszoneprefix = $subnet->{dnszoneprefix};

    #verify dns zones before ipam
    &$verify_dns_zone($dnszone, $dns);
    &$verify_dns_zone($reversednszone, $reversedns);

    if ($ipamid) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	eval {
	    $plugin->add_ip($plugin_config, $subnetid, $subnet, $ip);
	};
	die $@ if $@;
    }

    eval {
	#add dns
	&$add_dns_record($dnszone, $dns, $hostname, $dnszoneprefix, $ip);
	#add reverse dns
	&$add_dns_ptr_record($reversednszone, $dnszone, $reversedns, $hostname, $dnszoneprefix, $ip);
    };
    if ($@) {
	#rollback
	my $err = $@;
	eval {
	    PVE::Network::SDN::Subnets::del_ip($subnetid, $subnet, $ip, $hostname)
	};
	die $err;
    }
}

sub del_ip {
    my ($zone, $subnetid, $subnet, $ip, $hostname) = @_;

    return if !$subnet;

    my $ipamid = $zone->{ipam};
    my $dns = $zone->{dns};
    my $dnszone = $zone->{dnszone};
    my $reversedns = $zone->{reversedns};
    my $reversednszone = &$get_reversedns_zone($subnetid, $subnet, $reversedns, $ip);
    my $dnszoneprefix = $subnet->{dnszoneprefix};

    &$verify_dns_zone($dnszone, $dns);
    &$verify_dns_zone($reversednszone, $reversedns);

    if ($ipamid) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	$plugin->del_ip($plugin_config, $subnetid, $subnet, $ip);
    }

    eval {
	&$del_dns_record($dnszone, $dns, $hostname, $dnszoneprefix, $ip);
	&$del_dns_ptr_record($reversednszone, $reversedns, $ip);
    };
    if ($@) {
	warn $@;
    }
}

1;
