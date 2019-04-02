package PVE::Network::Vnet;

use strict;
use warnings;
use Data::Dumper;
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);


sub vnet_config {
    my ($cfg, $vnetid, $noerr) = @_;

    die "no vnet ID specified\n" if !$vnetid;

    my $scfg = $cfg->{ids}->{$vnetid};
    die "vnet '$vnetid' does not exists\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {

    return cfs_read_file("network/vnet.cfg");
}

sub write_config {
    my ($cfg) = @_;
    cfs_write_file("network/vnet.cfg", $cfg);
}

sub lock_vnet_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file("network/vnet.cfg", undef, $code);
    my $err = $@;
    if ($err) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub vnets_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_vnet {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::Vnet::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::Vnet::vnets_ids($cfg) ];
}


my $format_config_line = sub {
    my ($schema, $key, $value) = @_;

    my $ct = $schema->{type};

    die "property '$key' contains a line feed\n"
        if ($key =~ m/[\n\r]/) || ($value =~ m/[\n\r]/);

    if ($ct eq 'boolean') {
        return "\t$key " . ($value ? 1 : 0) . "\n"
            if defined($value);
    } else {
        return "\t$key $value\n" if "$value" ne '';
    }
};

1;
