package PVE::Network::SDN::Vnets;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);


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
    my $config = cfs_read_file("sdn/vnets.cfg.new");
    $config = cfs_read_file("sdn/vnets.cfg") if !keys %{$config->{ids}};
    return $config;
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/vnets.cfg.new", $cfg);
}

sub lock_sdn_vnets_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file("sdn/vnets.cfg.new", undef, $code);
    if (my $err = $@) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
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

1;
