package PVE::Network::SDN::Ipams;

use strict;
use warnings;

use Data::Dumper;
use JSON;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network;

use PVE::Network::SDN::Ipams::PVEPlugin;
use PVE::Network::SDN::Ipams::NetboxPlugin;
use PVE::Network::SDN::Ipams::PhpIpamPlugin;
use PVE::Network::SDN::Ipams::Plugin;

PVE::Network::SDN::Ipams::PVEPlugin->register();
PVE::Network::SDN::Ipams::NetboxPlugin->register();
PVE::Network::SDN::Ipams::PhpIpamPlugin->register();
PVE::Network::SDN::Ipams::Plugin->init();


sub sdn_ipams_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn ipam ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn '$id' does not exist\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn/ipams.cfg");
    #add default internal pve
    $config->{ids}->{pve}->{type} = 'pve';
    return $config;
}

sub get_plugin_config {
    my ($vnet) = @_;
    my $ipamid = $vnet->{ipam};
    my $ipam_cfg = PVE::Network::SDN::Ipams::config();
    return $ipam_cfg->{ids}->{$ipamid};
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/ipams.cfg", $cfg);
}

sub sdn_ipams_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_sdn_vnet {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::Ipams::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::Vnets::sdn_ipams_ids($cfg) ];
}

1;

