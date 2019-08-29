package PVE::Network::SDN;

use strict;
use warnings;

use Data::Dumper;
use JSON;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network::SDN::Plugin;
use PVE::Network::SDN::VnetPlugin;
use PVE::Network::SDN::VlanPlugin;
use PVE::Network::SDN::VxlanMulticastPlugin;

PVE::Network::SDN::VnetPlugin->register();
PVE::Network::SDN::VlanPlugin->register();
PVE::Network::SDN::VxlanMulticastPlugin->register();
PVE::Network::SDN::Plugin->init();


sub sdn_config {
    my ($cfg, $sdnid, $noerr) = @_;

    die "no sdn ID specified\n" if !$sdnid;

    my $scfg = $cfg->{ids}->{$sdnid};
    die "sdn '$sdnid' does not exists\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn.cfg.new");
    $config = cfs_read_file("sdn.cfg") if !keys %{$config->{ids}};
    return $config;
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn.cfg.new", $cfg);
}

sub lock_sdn_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file("sdn.cfg.new", undef, $code);
    if (my $err = $@) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub sdn_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_sdn {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::sdn_ids($cfg) ];
}

sub status {

    my $cmd = ['ifquery', '-a', '-c', '-o','json'];

    my $result = '';
    my $reader = sub { $result .= shift };

    eval {
	run_command($cmd, outfunc => $reader);
    };

    my $resultjson = decode_json($result);
    my $interfaces = {};

    foreach my $interface (@$resultjson) {
	my $name = $interface->{name};
	$interfaces->{$name} = {
	    status => $interface->{status},
	    config => $interface->{config},
	    config_status => $interface->{config_status},
	};
    }

    return $interfaces;
}


sub generate_etc_network_config {

    my $sdn_cfg = PVE::Cluster::cfs_read_file('sdn.cfg');
    return if !$sdn_cfg;

    #read main config for physical interfaces
    my $current_config_file = "/etc/network/interfaces";
    my $fh = IO::File->new($current_config_file);
    my $interfaces_config = PVE::INotify::read_etc_network_interfaces(1,$fh);
    $fh->close();

    #check uplinks
    my $uplinks = {};
    foreach my $id (keys %{$interfaces_config->{ifaces}}) {
	my $interface = $interfaces_config->{ifaces}->{$id};
	if (my $uplink = $interface->{'uplink-id'}) {
	    die "uplink-id $uplink is already defined on $uplinks->{$uplink}" if $uplinks->{$uplink};
	    $interface->{name} = $id;
	    $uplinks->{$interface->{'uplink-id'}} = $interface;
	}
    }

    my $vnet_cfg = undef;
    my $transport_cfg = undef;

    foreach my $id (keys %{$sdn_cfg->{ids}}) {
	if ($sdn_cfg->{ids}->{$id}->{type} eq 'vnet') {
	    $vnet_cfg->{ids}->{$id} = $sdn_cfg->{ids}->{$id};
	} else {
	    $transport_cfg->{ids}->{$id} = $sdn_cfg->{ids}->{$id};
	}
    }

    #generate configuration
    my $rawconfig = "";
    foreach my $id (keys %{$vnet_cfg->{ids}}) {
	my $vnet = $vnet_cfg->{ids}->{$id};
	my $zone = $vnet->{transportzone};

	if(!$zone) {
	    warn "can't generate vnet $vnet : zone $zone don't exist";
	    next;
	}

	my $plugin_config = $transport_cfg->{ids}->{$zone};

	if (!defined($plugin_config)) {
	    warn "can't generate vnet $vnet : zone $zone don't exist";
	    next;
	}

	my $plugin = PVE::Network::SDN::Plugin->lookup($plugin_config->{type});
	$rawconfig .= $plugin->generate_sdn_config($plugin_config, $zone, $id, $vnet, $uplinks);
    }

    return $rawconfig;
}

sub write_etc_network_config {
    my ($rawconfig) = @_;

    return if !$rawconfig;
    my $sdn_interfaces_file = "/etc/network/interfaces.d/sdn";

    my $writefh = IO::File->new($sdn_interfaces_file,">");
    print $writefh $rawconfig;
    $writefh->close();
}

1;



