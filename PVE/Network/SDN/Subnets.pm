package PVE::Network::SDN::Subnets;

use strict;
use warnings;

use Net::Subnet qw(subnet_matcher);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);

use PVE::Network::SDN::Ipams;
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

sub find_ip_subnet {
    my ($ip, $subnetslist) = @_;

    my $subnets_cfg = PVE::Network::SDN::Subnets::config();
    my @subnets = PVE::Tools::split_list($subnetslist) if $subnetslist;

    my $subnet = undef;
    my $subnetid = undef;

    foreach my $s (@subnets) {
        my $subnet_matcher = subnet_matcher($s);
        next if !$subnet_matcher->($ip);
        $subnetid = $s =~ s/\//-/r;
        $subnet = $subnets_cfg->{ids}->{$subnetid};
        last;
    }
    die  "can't find any subnet for ip $ip" if !$subnet;

    return ($subnetid, $subnet);
}

sub next_free_ip {
    my ($subnetid, $subnet) = @_;

    my $ipamid = $subnet->{ipam};
    return if !$ipamid;

    my $ipam_cfg = PVE::Network::SDN::Ipams::config();
    my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
    my $ip = $plugin->add_next_freeip($plugin_config, $subnetid, $subnet);
    return $ip;
}

sub add_ip {
    my ($subnetid, $subnet, $ip) = @_;

    my $ipamid = $subnet->{ipam};
    return if !$ipamid;

    my $ipam_cfg = PVE::Network::SDN::Ipams::config();
    my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
    $plugin->add_ip($plugin_config, $subnetid, $ip);
}

sub del_ip {
    my ($subnetid, $subnet, $ip) = @_;

    my $ipamid = $subnet->{ipam};
    return if !$ipamid;

    my $ipam_cfg = PVE::Network::SDN::Ipams::config();
    my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
    $plugin->del_ip($plugin_config, $subnetid, $ip);
}

1;
