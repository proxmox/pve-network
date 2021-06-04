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


my $ipamdb_file = "priv/ipam.db";

PVE::Cluster::cfs_register_file($ipamdb_file,
                                 sub { PVE::Network::SDN::Ipams::PVEPlugin->parse_config(@_); },
                                 sub { PVE::Network::SDN::Ipams::PVEPlugin->write_config(@_); });

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

	die "cannot delete subnet '$cidr', not empty\n" if keys %{$dbsubnet->{ips}} > 0;

	delete $dbzone->{subnets}->{$cidr};

	write_db($db);
    });
    die "$@" if $@;

}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description, $is_gateway) = @_;

    my $cidr = $subnet->{cidr};
    my $zone = $subnet->{zone};

    cfs_lock_file($ipamdb_file, undef, sub {

	my $db = read_db();
	my $dbzone = $db->{zones}->{$zone};
	die "zone '$zone' doesn't exist in IPAM DB\n" if !$dbzone;
	my $dbsubnet = $dbzone->{subnets}->{$cidr};
	die "subnet '$cidr' doesn't exist in IPAM DB\n" if !$dbsubnet;

	die "IP '$ip' already exist\n" if defined($dbsubnet->{ips}->{$ip});

	$dbsubnet->{ips}->{$ip} = {};

	write_db($db);
    });
    die "$@" if $@;
}

sub update_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description, $is_gateway) = @_;
    return;
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $description) = @_;

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

    return "$freeip/$mask";
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
