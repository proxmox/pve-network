package PVE::Network::SDN;

use strict;
use warnings;

use Data::Dumper;
use JSON;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network::SDN::Plugin;
use PVE::Network::SDN::VnetPlugin;
use PVE::Network::SDN::VlanPlugin;
use PVE::Network::SDN::VxlanMulticastPlugin;

PVE::Network::SDN::VnetPlugin->register();
PVE::Network::SDN::VlanPlugin->register();
PVE::Network::SDN::VxlanMulticastPlugin->register();
PVE::Network::SDN::Plugin->init();


sub network_config {
    my ($cfg, $networkid, $noerr) = @_;

    die "no network ID specified\n" if !$networkid;

    my $scfg = $cfg->{ids}->{$networkid};
    die "network '$networkid' does not exists\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("networks.cfg.new");
    $config = cfs_read_file("networks.cfg") if !keys %{$config->{ids}};
    return $config;
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("networks.cfg.new", $cfg);
}

sub lock_network_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file("networks.cfg.new", undef, $code);
    if (my $err = $@) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub networks_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_network {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::networks_ids($cfg) ];
}

sub status {

    my $cmd = ['ifquery', '-a', '-c', '-o','json'];

    my $result = '';
    my $reader = sub { $result .= shift };

    eval {
	run_command($cmd, outfunc => $reader);
    };

    my $resultjson = decode_json($result);
    my $interfaces = {};

    foreach my $interface (@$resultjson) {
	my $name = $interface->{name};
	$interfaces->{$name} = {
	    status => $interface->{status},
	    config => $interface->{config},
	    config_status => $interface->{config_status},
	};
    }

    return $interfaces;
}

1;
