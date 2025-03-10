package PVE::Network::SDN::Subnets;

use strict;
use warnings;

use Net::Subnet qw(subnet_matcher);
use Net::IP;
use NetAddr::IP qw(:lower);

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::JSONSchema qw(parse_property_string);
use PVE::Network::SDN::Dns;
use PVE::Network::SDN::Ipams;

use PVE::Network::SDN::SubnetPlugin;
PVE::Network::SDN::SubnetPlugin->register();
PVE::Network::SDN::SubnetPlugin->init();

sub sdn_subnets_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn subnet ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn subnet '$id' does not exist\n" if (!$noerr && !$scfg);

    if ($scfg) {
	$scfg->{id} = $id;

	my ($zone, $network, $mask) = split(/-/, $id);
	$scfg->{cidr} = "$network/$mask";
	$scfg->{zone} = $zone;
	$scfg->{network} = $network;
	$scfg->{mask} = $mask;
    }

    return $scfg;
}

sub get_dhcp_ranges {
    my ($subnet_config) = @_;

    my @dhcp_ranges = ();

    if ($subnet_config->{'dhcp-range'}) {
	foreach my $element (@{$subnet_config->{'dhcp-range'}}) {
	    my $dhcp_range = eval { parse_property_string('pve-sdn-dhcp-range', $element) };

	    if ($@ || !$dhcp_range) {
		warn "Unable to parse dhcp-range string: $element\n";
		warn "$@\n" if $@;
		next;
	    }

	    push @dhcp_ranges, $dhcp_range;
	}
    }

    return \@dhcp_ranges;
}

sub config {
    my ($running) = @_;

    if ($running) {
	my $cfg = PVE::Network::SDN::running_config();
	return $cfg->{subnets};
    }

    return cfs_read_file("sdn/subnets.cfg");
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

    my $cfg = PVE::Network::SDN::Subnets::config($running);
    return PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $subnetid, 1);
}

sub find_ip_subnet {
    my ($ip, $subnets) = @_;

    my $subnet = undef;
    my $subnetid = undef;

    foreach my $id (sort keys %{$subnets}) {
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

sub verify_dns_zone {
    my ($zone, $dns) = @_;

    return if !$zone || !$dns;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->verify_zone($plugin_config, $zone);
}

sub get_reversedns_zone {
    my ($subnetid, $subnet, $dns, $ip) = @_;

    return if !$subnetid || !$dns || !$ip;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->get_reversedns_zone($plugin_config, $subnetid, $subnet, $ip);
}

sub add_dns_record {
    my ($zone, $dns, $hostname, $ip) = @_;
    return if !$zone || !$dns || !$hostname || !$ip;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->add_a_record($plugin_config, $zone, $hostname, $ip);

}

sub add_dns_ptr_record {
    my ($reversezone, $zone, $dns, $hostname, $ip) = @_;

    return if !$zone || !$reversezone || !$dns || !$hostname || !$ip;

    $hostname .= ".$zone";
    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->add_ptr_record($plugin_config, $reversezone, $hostname, $ip);
}

sub del_dns_record {
    my ($zone, $dns, $hostname, $ip) = @_;

    return if !$zone || !$dns || !$hostname || !$ip;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->del_a_record($plugin_config, $zone, $hostname, $ip);
}

sub del_dns_ptr_record {
    my ($reversezone, $dns, $ip) = @_;

    return if !$reversezone || !$dns || !$ip;

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dns};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
    $plugin->del_ptr_record($plugin_config, $reversezone, $ip);
}

sub add_subnet {
    my ($zone, $subnetid, $subnet) = @_;

    my $ipam = $zone->{ipam};
    return if !$ipam;
    my $ipam_cfg = PVE::Network::SDN::Ipams::config();
    my $plugin_config = $ipam_cfg->{ids}->{$ipam};
    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
    $plugin->add_subnet($plugin_config, $subnetid, $subnet);
}

sub update_subnet {
    my ($zone, $subnetid, $subnet, $old_subnet) = @_;

    my $ipam = $zone->{ipam};
    return if !$ipam;

    my $ipam_cfg = PVE::Network::SDN::Ipams::config();
    my $plugin_config = $ipam_cfg->{ids}->{$ipam};
    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
    $plugin->update_subnet($plugin_config, $subnetid, $subnet, $old_subnet);
}

sub del_subnet {
    my ($zone, $subnetid, $subnet) = @_;

    my $ipam = $zone->{ipam};
    return if !$ipam;
    my $ipam_cfg = PVE::Network::SDN::Ipams::config();
    my $plugin_config = $ipam_cfg->{ids}->{$ipam};
    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
    $plugin->del_subnet($plugin_config, $subnetid, $subnet);
}

sub add_next_free_ip {
    my ($zone, $subnetid, $subnet, $hostname, $mac, $vmid, $skipdns, $dhcprange, $ipversion) = @_;

    my $cidr = undef;
    my $ip = undef;

    my $ipamid = $zone->{ipam};
    my $dns = $zone->{dns};
    my $dnszone = $zone->{dnszone};
    my $reversedns = $zone->{reversedns};
    my $dnszoneprefix = $subnet->{dnszoneprefix};

    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;

    #verify dns zones before ipam
    verify_dns_zone($dnszone, $dns) if !$skipdns;

    if($ipamid) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	eval {
	    if ($dhcprange) {
		my $data = {
		    mac => $mac,
		    hostname => $hostname,
		    vmid => $vmid,
		};

		my $dhcp_ranges = PVE::Network::SDN::Subnets::get_dhcp_ranges($subnet);

		foreach my $range (@$dhcp_ranges) {
		    $ip = $plugin->add_range_next_freeip($plugin_config, $subnet, $range, $data);
		    last if $ip;
		}
	    } else {
		$ip = $plugin->add_next_freeip($plugin_config, $subnetid, $subnet, $hostname, $mac, $vmid);
	    }
	};

	die $@ if $@;

	eval { PVE::Network::SDN::Ipams::add_cache_mac_ip($mac, $ip); };
	warn $@ if $@;
    }

    eval {
	my $reversednszone = get_reversedns_zone($subnetid, $subnet, $reversedns, $ip);

	if(!$skipdns) {
	    #add dns
	    add_dns_record($dnszone, $dns, $hostname, $ip);
	    #add reverse dns
	    add_dns_ptr_record($reversednszone, $dnszone, $reversedns, $hostname, $ip);
	}
    };
    if ($@) {
	#rollback
	my $err = $@;
	eval {
	    PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $subnet, $ip, $hostname, $mac)
	};
	die $err;
    }
    return $ip;
}

sub add_ip {
    my ($zone, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $skipdns) = @_;

    return if !$subnet || !$ip; 

    my $ipaddr = NetAddr::IP->new($ip);
    $ip = $ipaddr->canon();

    my $ipamid = $zone->{ipam};
    my $dns = $zone->{dns};
    my $dnszone = $zone->{dnszone};
    my $reversedns = $zone->{reversedns};
    my $reversednszone = get_reversedns_zone($subnetid, $subnet, $reversedns, $ip);
    my $dnszoneprefix = $subnet->{dnszoneprefix};

    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;

    #verify dns zones before ipam
    if(!$skipdns) {
	verify_dns_zone($dnszone, $dns);
	verify_dns_zone($reversednszone, $reversedns);
    }

    if ($ipamid) {

	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});

	eval {
	    $plugin->add_ip($plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway);
	};
	die $@ if $@;

	eval { PVE::Network::SDN::Ipams::add_cache_mac_ip($mac, $ip) if $mac; };
	warn $@ if $@;
    }

    eval {
	if(!$skipdns) {
	    #add dns
	    add_dns_record($dnszone, $dns, $hostname, $ip);
	    #add reverse dns
	    add_dns_ptr_record($reversednszone, $dnszone, $reversedns, $hostname, $ip);
	}
    };
    if ($@) {
	#rollback
	my $err = $@;
	eval {
	    PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $subnet, $ip, $hostname, $mac)
	};
	die $err;
    }
}

sub update_ip {
    my ($zone, $subnetid, $subnet, $ip, $hostname, $oldhostname, $mac, $vmid, $skipdns) = @_;

    return if !$subnet || !$ip; 

    my $ipaddr = NetAddr::IP->new($ip);
    $ip = $ipaddr->canon();

    my $ipamid = $zone->{ipam};
    my $dns = $zone->{dns};
    my $dnszone = $zone->{dnszone};
    my $reversedns = $zone->{reversedns};
    my $reversednszone = get_reversedns_zone($subnetid, $subnet, $reversedns, $ip);
    my $dnszoneprefix = $subnet->{dnszoneprefix};

    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;

    #verify dns zones before ipam
    if(!$skipdns) {
	verify_dns_zone($dnszone, $dns);
	verify_dns_zone($reversednszone, $reversedns);
    }

    if ($ipamid) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	eval {
	    $plugin->update_ip($plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid);
	};
	die $@ if $@;
    }

    return if $hostname eq $oldhostname;

    eval {
	if(!$skipdns) {
	    #add dns
	    del_dns_record($dnszone, $dns, $oldhostname, $ip);
	    add_dns_record($dnszone, $dns, $hostname, $ip);
	    #add reverse dns
	    del_dns_ptr_record($reversednszone, $reversedns, $ip);
	    add_dns_ptr_record($reversednszone, $dnszone, $reversedns, $hostname, $ip);
	}
    };
}

sub del_ip {
    my ($zone, $subnetid, $subnet, $ip, $hostname, $mac, $skipdns) = @_;

    return if !$subnet || !$ip;

    my $ipaddr = NetAddr::IP->new($ip);
    $ip = $ipaddr->canon();

    my $ipamid = $zone->{ipam};
    my $dns = $zone->{dns};
    my $dnszone = $zone->{dnszone};
    my $reversedns = $zone->{reversedns};
    my $reversednszone = get_reversedns_zone($subnetid, $subnet, $reversedns, $ip);
    my $dnszoneprefix = $subnet->{dnszoneprefix};
    $hostname .= ".$dnszoneprefix" if $dnszoneprefix;

    if(!$skipdns) {
	verify_dns_zone($dnszone, $dns);
	verify_dns_zone($reversednszone, $reversedns);
    }

    if ($ipamid) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	$plugin->del_ip($plugin_config, $subnetid, $subnet, $ip);

	if ($mac) {
	    eval { PVE::Network::SDN::Ipams::del_cache_mac_ip($mac, $ip) };
	    warn $@ if $@;
	}
    }

    eval {
	if(!$skipdns) {
	    del_dns_record($dnszone, $dns, $hostname, $ip);
	    del_dns_ptr_record($reversednszone, $reversedns, $ip);
	}
    };
    if ($@) {
	warn $@;
    }
}

1;
