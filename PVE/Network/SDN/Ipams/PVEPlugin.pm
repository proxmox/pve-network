package PVE::Network::SDN::Ipams::PVEPlugin;

use strict;
use warnings;
use PVE::INotify;
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_register_file cfs_lock_file);
use PVE::Tools;
use JSON;
use NetAddr::IP;
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

    my $cidr = $subnetid =~ s/-/\//r;
    my $gateway = $subnet->{gateway};

    cfs_lock_file($ipamdb_file, undef, sub {
	my $config = read_db();
	#create subnet
	if (!defined($config->{subnets}->{$cidr})) {
	    $config->{subnets}->{$cidr}->{ips} = {};
	    write_db($config);
	}
    });
    die "$@" if $@;
}

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet) = @_;

    my $cidr = $subnetid =~ s/-/\//r;

    cfs_lock_file($ipamdb_file, undef, sub {

	my $db = read_db();
	my $ips = $db->{subnets}->{$cidr}->{ips};
	die "cannot delete subnet '$cidr', not empty\n" if keys %{$ips} > 0;
	delete $db->{subnets}->{$cidr};
	write_db($db);
    });
    die "$@" if $@;

}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $ip, $is_gateway) = @_;

    my $cidr = $subnetid =~ s/-/\//r;

    cfs_lock_file($ipamdb_file, undef, sub {

	my $db = read_db();
	my $s = $db->{subnets}->{$cidr};

	die "IP '$ip' already exist\n" if defined($s->{ips}->{$ip});

	#verify that ip is valid for this subnet
	$s->{ips}->{$ip} = 1;
	write_db($db);
    });
    die "$@" if $@;
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet) = @_;

    my $cidr = $subnetid =~ s/-/\//r;
    my $freeip = undef;

    cfs_lock_file($ipamdb_file, undef, sub {

	my $db = read_db();
	my $s = $db->{subnets}->{$cidr};
	my $iplist = new NetAddr::IP($cidr);
	my $broadcast = $iplist->broadcast();

	while (1) {
	    $iplist++;
	    last if $iplist eq $broadcast;
	    my $ip = $iplist->addr();
	    next if defined($s->{ips}->{$ip});
	    $freeip = $ip;
	    last;
	}

	die "can't find free ip in subnet '$cidr'\n" if !$freeip;

	$s->{ips}->{$freeip} = 1;
	write_db($db);
    });
    die "$@" if $@;

    my ($network, $mask) = split(/-/, $subnetid);
    return "$freeip/$mask";
}

sub del_ip {
    my ($class, $plugin_config, $subnetid, $ip) = @_;

    my $cidr = $subnetid =~ s/-/\//r;

    cfs_lock_file($ipamdb_file, undef, sub {

	my $db = read_db();
	my $s = $db->{subnets}->{$cidr};
	return if !$ip;

	die "IP '$ip' does not exist in IPAM DB\n" if !defined($s->{ips}->{$ip});
	delete $s->{ips}->{$ip};
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
