package PVE::Network::Transport;

use strict;
use warnings;
use Data::Dumper;
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network::Plugin;
use PVE::Network::VlanPlugin;
use PVE::Network::VxlanMulticastPlugin;

PVE::Network::VlanPlugin->register();
PVE::Network::VxlanMulticastPlugin->register();
PVE::Network::Plugin->init();


sub transport_config {
    my ($cfg, $transportid, $noerr) = @_;

    die "no transport ID specified\n" if !$transportid;

    my $scfg = $cfg->{ids}->{$transportid};
    die "transport '$transportid' does not exists\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {

    return cfs_read_file("network/transports.cfg");
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("network/transports.cfg", $cfg);
}

sub lock_transport_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file("network/transports.cfg", undef, $code);
    my $err = $@;
    if ($err) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub transports_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_transport {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::Transport::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::Transport::transports_ids($cfg) ];
}

1;
