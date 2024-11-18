package PVE::Network::SDN::Ipams::PVEPlugin;

use strict;
use warnings;
use PVE::INotify;
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_register_file cfs_lock_file);
use PVE::Tools;
use JSON;
use NetAddr::IP qw(:lower);

use Net::IP;
use Digest::SHA;

use base('PVE::Network::SDN::Ipams::Plugin');


my $ipamdb_file = "sdn/pve-ipam-state.json";
my $ipamdb_file_legacy = "priv/ipam.db";

PVE::Cluster::cfs_register_file(
    $ipamdb_file,
    sub {
	my ($filename, $data) = @_;
	if (defined($data)) {
	    return PVE::Network::SDN::Ipams::PVEPlugin->parse_config($filename, $data);
	} else {
	    # TODO: remove legacy state file handling with PVE 9+ after ensuring all call sites got
	    # switched over.
	    return cfs_read_file($ipamdb_file_legacy);
	}
    },
    sub {
	my ($filename, $data) = @_;
	# TODO: remove below with PVE 9+, add a pve8to9 check to allow doing so.
	if (-e $ipamdb_file_legacy && -e $ipamdb_file) {
	    # only clean-up if we succeeded to write the new path at least once
	    unlink $ipamdb_file_legacy or $!{ENOENT} or warn "failed to unlink legacy IPAM DB - $!\n";
	}
	return PVE::Network::SDN::Ipams::PVEPlugin->write_config($filename, $data);
    },
);

PVE::Cluster::cfs_register_file(
    $ipamdb_file_legacy,
    sub { PVE::Network::SDN::Ipams::PVEPlugin->parse_config(@_); },
    undef, # no writer for legacy file, all must go to the new file.
);

sub type {
    return 'pve';
}

sub properties {
}

sub options {
}

# Plugin implementation

sub add_subnet {
    my ($class, $plugin_config, $subnetid, $subnet) = @_;

    my $cidr = $subnet->{cidr};
    my $zone = $subnet->{zone};
    my $gateway = $subnet->{gateway};


    cfs_lock_file($ipamdb_file, undef, sub {
	my $db = {};
	$db = read_db();

	$db->{zones}->{$zone} = {} if !$db->{zones}->{$zone};
	my $zonedb = $db->{zones}->{$zone};

	if(!$zonedb->{subnets}->{$cidr}) {
	    #create subnet
	    $zonedb->{subnets}->{$cidr}->{ips} = {};
	    write_db($db);
	}
    });
    die "$@" if $@;
}

sub only_gateway_remains {
    my ($ips) = @_;

    if (keys %{$ips} == 1 &&
	(values %{$ips})[0]->{gateway} == 1) {
	return 1;
    }
    return 0;
};

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet) = @_;

    my $cidr = $subnet->{cidr};
    my $zone = $subnet->{zone};

    cfs_lock_file($ipamdb_file, undef, sub {

	my $db = read_db();

	my $dbzone = $db->{zones}->{$zone};
	die "zone '$zone' doesn't exist in IPAM DB\n" if !$dbzone;
	my $dbsubnet = $dbzone->{subnets}->{$cidr};
	die "subnet '$cidr' doesn't exist in IPAM DB\n" if !$dbsubnet;

	my $ips = $dbsubnet->{ips};

	if (keys %{$ips} > 0 && !only_gateway_remains($ips)) {
	    die "cannot delete subnet '$cidr', not empty\n";
	}

	delete $dbzone->{subnets}->{$cidr};

	write_db($db);
    });
    die "$@" if $@;

}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway) = @_;

    my $cidr = $subnet->{cidr};
    my $zone = $subnet->{zone};

    cfs_lock_file($ipamdb_file, undef, sub {

	my $db = read_db();
	my $dbzone = $db->{zones}->{$zone};
	die "zone '$zone' doesn't exist in IPAM DB\n" if !$dbzone;
	my $dbsubnet = $dbzone->{subnets}->{$cidr};
	die "subnet '$cidr' doesn't exist in IPAM DB\n" if !$dbsubnet;

	die "IP '$ip' already exist\n" if (!$is_gateway && defined($dbsubnet->{ips}->{$ip})) || ($is_gateway && defined($dbsubnet->{ips}->{$ip}) && !defined($dbsubnet->{ips}->{$ip}->{gateway}));

        my $data = {};
	if ($is_gateway) {
	    $data->{gateway} = 1;
	} else {
	    $data->{vmid} = $vmid if $vmid;
	    $data->{hostname} = $hostname if $hostname;
	    $data->{mac} = $mac if $mac;
	}

	$dbsubnet->{ips}->{$ip} = $data;

	write_db($db);
    });
    die "$@" if $@;
}

sub update_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway) = @_;
    return;
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $vmid, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $network = $subnet->{network};
    my $zone = $subnet->{zone};
    my $mask = $subnet->{mask};
    my $freeip = undef;

    cfs_lock_file($ipamdb_file, undef, sub {

	my $db = read_db();
	my $dbzone = $db->{zones}->{$zone};
	die "zone '$zone' doesn't exist in IPAM DB\n" if !$dbzone;
	my $dbsubnet = $dbzone->{subnets}->{$cidr};
	die "subnet '$cidr' doesn't exist in IPAM DB" if !$dbsubnet;

	if (Net::IP::ip_is_ipv4($network) && $mask == 32) {
	    die "cannot find free IP in subnet '$cidr'\n" if defined($dbsubnet->{ips}->{$network});
	    $freeip = $network;
	} else {
	    my $iplist = NetAddr::IP->new($cidr);
	    my $lastip = $iplist->last()->canon();
	    $iplist++ if Net::IP::ip_is_ipv4($network); #skip network address for ipv4
	    while(1) {
		my $ip = $iplist->canon();
		if (defined($dbsubnet->{ips}->{$ip})) {
		    last if $ip eq $lastip;
		    $iplist++;
		    next;
		} 
		$freeip = $ip;
		last;
	    }
	}

	die "can't find free ip in subnet '$cidr'\n" if !$freeip;

	$dbsubnet->{ips}->{$freeip} = {};

	write_db($db);
    });
    die "$@" if $@;

    return $freeip;
}

sub add_range_next_freeip {
    my ($class, $plugin_config, $subnet, $range, $data, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $zone = $subnet->{zone};

    cfs_lock_file($ipamdb_file, undef, sub {
	my $db = read_db();

	my $dbzone = $db->{zones}->{$zone};
	die "zone '$zone' doesn't exist in IPAM DB\n" if !$dbzone;

	my $dbsubnet = $dbzone->{subnets}->{$cidr};
	die "subnet '$cidr' doesn't exist in IPAM DB\n" if !$dbsubnet;

	my $ip = new Net::IP ("$range->{'start-address'} - $range->{'end-address'}")
	    or die "Invalid IP address(es) in Range!\n";
	my $mac = $data->{mac};

	do {
	    my $ip_address = $ip->version() == 6 ? $ip->short() : $ip->ip();
	    if (!$dbsubnet->{ips}->{$ip_address}) {
		$dbsubnet->{ips}->{$ip_address} = $data;
		write_db($db);

		return $ip_address;
	    }
	} while (++$ip);

	die "No free IP left in Range $range->{'start-address'}:$range->{'end-address'}}\n";
    });
}

sub del_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip) = @_;

    my $cidr = $subnet->{cidr};
    my $zone = $subnet->{zone};

    cfs_lock_file($ipamdb_file, undef, sub {

	my $db = read_db();
	die "zone $zone don't exist in ipam db" if !$db->{zones}->{$zone};
	my $dbzone = $db->{zones}->{$zone};
	die "subnet $cidr don't exist in ipam db" if !$dbzone->{subnets}->{$cidr};
	my $dbsubnet = $dbzone->{subnets}->{$cidr};

	die "IP '$ip' does not exist in IPAM DB\n" if !defined($dbsubnet->{ips}->{$ip});
	delete $dbsubnet->{ips}->{$ip};
	write_db($db);
    });
    die "$@" if $@;
}

sub get_ips_from_mac {
    my ($class, $plugin_config, $mac, $zoneid) = @_;

    #just in case, as this should already be cached in local macs.db

    my $ip4 = undef;
    my $ip6 = undef;

    my $db = read_db();
    die "zone $zoneid don't exist in ipam db" if !$db->{zones}->{$zoneid};
    my $dbzone = $db->{zones}->{$zoneid};
    my $subnets = $dbzone->{subnets};

    for my $subnet ( keys %$subnets) {
	next if Net::IP::ip_is_ipv4($subnet) && $ip4;
	next if $ip6;
	my $ips = $subnets->{$subnet}->{ips};
	for my $ip (keys %$ips) {
	    my $ipobject = $ips->{$ip};
	    if ($ipobject->{mac} && $ipobject->{mac} eq $mac) {
		if (Net::IP::ip_is_ipv4($ip)) {
		    $ip4 = $ip;
		} else {
		    $ip6 = $ip;
		}
	    }
	}
	last if $ip4 && $ip6;
    }
    return ($ip4, $ip6);
}

#helpers

sub read_db {
    my $db = cfs_read_file($ipamdb_file);
    return $db;
}

sub write_db {
    my ($cfg) = @_;

    my $json = to_json($cfg);
    cfs_write_file($ipamdb_file, $json);
}

sub write_config {
    my ($class, $filename, $cfg) = @_;

    return $cfg;
}

sub parse_config {
    my ($class, $filename, $raw) = @_;

    $raw = '{}' if !defined($raw) ||$raw eq '';
    my $cfg = from_json($raw);

    return $cfg;
}

1;
