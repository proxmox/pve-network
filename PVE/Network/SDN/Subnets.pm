package PVE::Network::SDN::Subnets;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);

use PVE::Network::SDN::SubnetPlugin;
PVE::Network::SDN::SubnetPlugin->register();
PVE::Network::SDN::SubnetPlugin->init();

sub sdn_subnets_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn subnet ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn subnet '$id' does not exist\n" if (!$noerr && !$scfg);

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

    return keys %{$cfg->{ids}};
}

sub complete_sdn_subnet {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::Subnets::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::Subnets::sdn_subnets_ids($cfg) ];
}

sub get_subnet {
    my ($subnetid) = @_;

    my $cfg = PVE::Network::SDN::Subnets::config();
    my $subnet = PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $subnetid, 1);
    return $subnet;
}

1;
