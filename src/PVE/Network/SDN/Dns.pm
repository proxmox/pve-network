package PVE::Network::SDN::Dns;

use strict;
use warnings;

use JSON;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network;

use PVE::Network::SDN::Dns::PowerdnsPlugin;
use PVE::Network::SDN::Dns::Plugin;

PVE::Network::SDN::Dns::PowerdnsPlugin->register();
PVE::Network::SDN::Dns::Plugin->init();


sub sdn_dns_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn dns ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn '$id' does not exist\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn/dns.cfg");
    return $config;
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/dns.cfg", $cfg);
}

sub sdn_dns_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_sdn_dns {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::Dns::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::Dns::sdn_dns_ids($cfg) ];
}

1;

