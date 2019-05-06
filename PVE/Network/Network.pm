package PVE::Network::Network;

use strict;
use warnings;
use Data::Dumper;
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network::Network::Plugin;
use PVE::Network::Network::VnetPlugin;
use PVE::Network::Network::VlanPlugin;
use PVE::Network::Network::VxlanMulticastPlugin;

PVE::Network::Network::VnetPlugin->register();
PVE::Network::Network::VlanPlugin->register();
PVE::Network::Network::VxlanMulticastPlugin->register();
PVE::Network::Network::Plugin->init();


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
    my $err = $@;
    if ($err) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub networks_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_network {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::Network::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::Network::networks_ids($cfg) ];
}

1;
