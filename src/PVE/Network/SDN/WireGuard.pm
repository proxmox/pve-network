package PVE::Network::SDN::WireGuard;

use strict;
use warnings;

=head1 NAME

C<PVE::Network::SDN::WireGuard> - Helper module for WireGuard

=head1 DESCRIPTION

This module contains helpers for handling and applying WireGuard configuration.

=cut

use File::Basename;

use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file cfs_write_file);
use PVE::File;
use PVE::INotify;
use PVE::RESTEnvironment qw(log_warn);
use PVE::RS::SDN::WireGuard::PrivateKeys;
use PVE::Tools qw(file_get_contents file_set_contents run_command);

use PVE::Network::SDN::Fabrics;

my $local_wireguard_lock = "/var/lock/proxmox_wg.lock";

my $wireguard_config_folder = "/etc/wireguard/proxmox";
my $wireguard_private_key_file = "/etc/pve/priv/wg-keys.cfg";

cfs_register_file(
    'priv/wg-keys.cfg', \&parse_wg_keys, \&write_wg_keys,
);

sub parse_wg_keys {
    my ($filename, $raw) = @_;
    return $raw // '';
}

sub write_wg_keys {
    my ($filename, $config) = @_;
    return $config // '';
}

=head3 private_keys()

Reads and returns the private key configuration for WireGuard.

=cut

sub private_keys {
    my $private_key_config = cfs_read_file('priv/wg-keys.cfg');
    return PVE::RS::SDN::WireGuard::PrivateKeys->config($private_key_config);
}

=head3 write_private_keys($private_key_config)

Writes the given private key configuration to the section config file.

It is the callers responsibility to only call this function when the SDN domain
lock has been acquired.

=cut

sub write_private_keys {
    my ($config) = @_;
    cfs_write_file("priv/wg-keys.cfg", $config->to_raw(), 1);
}

=head3 cleanup_private_keys($private_keys, $fabric_config)

Removes all keys in $private_keys that are not contained in $fabric_config. This
is used for cleaning up the WireGuard keys after applying the SDN configuration.

=cut

sub cleanup_private_keys {
    my ($private_keys, $fabric_config) = @_;

    $private_keys = private_keys() if !$private_keys;
    $fabric_config = PVE::Network::SDN::Fabrics::config(1) if !$fabric_config;

    write_private_keys($private_keys) if $private_keys->cleanup($fabric_config);
}

=head3 generate_wireguard_config($apply)

Generates the WireGuard configuration files on the current node, based on the
current running SDN configuration. If $apply is passed, then the WireGuard
configuration will be applied via the syncconf command of wg(8).

=cut

sub generate_wireguard_config {
    my ($apply) = @_;

    my $nodename = PVE::INotify::nodename();

    my $fabric_config = PVE::Network::SDN::Fabrics::config(1);
    my $private_keys = private_keys();

    my $raw_config = $fabric_config->get_wireguard_raw_config($nodename, $private_keys);

    write_wireguard_config($raw_config, $apply);
}

=head3 write_wireguard_config($raw_config)

Takes a raw_config of the following format:

   interface_name => "<configuration>"

and generates the respective configuration files in $wireguard_config_folder. If
$apply is set, then the configuration will be synced via the syncconf command of
wg(8). This requires the interfaces to exist on the node, otherwise the wg
command will fail. A warning is emitted in that case.

=cut

sub write_wireguard_config {
    my ($raw_config, $apply) = @_;

    my $code = sub {
        mkdir '/etc/wireguard', 0o755 if !-e '/etc/wireguard';
        mkdir $wireguard_config_folder, 0o700 if !-e $wireguard_config_folder;

        my $has_wireguard_config = scalar($raw_config->%*);
        my $is_wireguard_installed = -e "/usr/bin/wg";

        if (!$is_wireguard_installed && $has_wireguard_config) {
            log_warn(
                "In order to apply the generated WireGuard configuration the package 'wireguard-tools' needs to be installed.\n"
            );
        }

        PVE::Tools::dir_glob_foreach(
            $wireguard_config_folder,
            '.*\.conf',
            sub {
                my ($file) = @_;
                unlink "$wireguard_config_folder/$file";
            },
        );

        for my $interface (keys $raw_config->%*) {
            PVE::File::file_set_contents(
                "$wireguard_config_folder/$interface.conf",
                $raw_config->{$interface},
                0o600,
            );

            if ($apply && $is_wireguard_installed) {
                eval {
                    PVE::Tools::run_command(
                        [
                            'wg',
                            'syncconf',
                            $interface,
                            "/etc/wireguard/proxmox/$interface.conf",
                        ],
                    );
                };

                log_warn($@) if $@;
            }
        }
    };

    PVE::Tools::lock_file($local_wireguard_lock, 10, $code);
    die $@ if $@;

    return;
}

