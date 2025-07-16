package PVE::Network::SDN::Fabrics;

use strict;
use warnings;

use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file cfs_write_file);
use PVE::JSONSchema qw(get_standard_option);
use PVE::INotify;
use PVE::RS::SDN::Fabrics;

cfs_register_file(
    'sdn/fabrics.cfg', \&parse_fabrics_config, \&write_fabrics_config,
);

sub parse_fabrics_config {
    my ($filename, $raw) = @_;
    return $raw // '';
}

sub write_fabrics_config {
    my ($filename, $config) = @_;
    return $config // '';
}

sub config {
    my ($running) = @_;

    if ($running) {
        my $running_config = PVE::Network::SDN::running_config();

        # if the config hasn't yet been applied after the introduction of
        # fabrics then the key does not exist in the running config so we
        # default to an empty hash
        my $fabrics_config = $running_config->{fabrics}->{ids} // {};
        return PVE::RS::SDN::Fabrics->running_config($fabrics_config);
    }

    my $fabrics_config = cfs_read_file("sdn/fabrics.cfg");
    return PVE::RS::SDN::Fabrics->config($fabrics_config);
}

sub write_config {
    my ($config) = @_;
    cfs_write_file("sdn/fabrics.cfg", $config->to_raw(), 1);
}

sub get_frr_daemon_status {
    my ($fabric_config) = @_;

    my $daemon_status = {};
    my $nodename = PVE::INotify::nodename();

    my $enabled_daemons = $fabric_config->enabled_daemons($nodename);

    for my $daemon (@$enabled_daemons) {
        $daemon_status->{$daemon} = 1;
    }

    return $daemon_status;
}

sub generate_frr_raw_config {
    my ($fabric_config) = @_;

    my @raw_config = ();

    my $nodename = PVE::INotify::nodename();

    my $frr_config = $fabric_config->get_frr_raw_config($nodename);
    push @raw_config, @$frr_config if @$frr_config;

    return \@raw_config;
}

1;
