package PVE::Network::SDN::Zones;

use strict;
use warnings;

use Data::Dumper;
use JSON;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Network;

use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones::VlanPlugin;
use PVE::Network::SDN::Zones::QinQPlugin;
use PVE::Network::SDN::Zones::VxlanPlugin;
use PVE::Network::SDN::Zones::EvpnPlugin;
use PVE::Network::SDN::Zones::FaucetPlugin;
use PVE::Network::SDN::Zones::Plugin;

PVE::Network::SDN::Zones::VlanPlugin->register();
PVE::Network::SDN::Zones::QinQPlugin->register();
PVE::Network::SDN::Zones::VxlanPlugin->register();
PVE::Network::SDN::Zones::EvpnPlugin->register();
PVE::Network::SDN::Zones::FaucetPlugin->register();
PVE::Network::SDN::Zones::Plugin->init();


sub sdn_zones_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn zone ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn '$id' does not exist\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn/zones.cfg.new");
    $config = cfs_read_file("sdn/zones.cfg") if !keys %{$config->{ids}};
    return $config;
}

sub get_plugin_config {
    my ($vnet) = @_;
    my $zoneid = $vnet->{zone};
    my $zone_cfg = PVE::Network::SDN::Zones::config();
    return $zone_cfg->{ids}->{$zoneid};
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/zones.cfg.new", $cfg);
}

sub lock_sdn_zones_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file("sdn/zones.cfg.new", undef, $code);
    if (my $err = $@) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub sdn_zones_ids {
    my ($cfg) = @_;

    return keys %{$cfg->{ids}};
}

sub complete_sdn_zone {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::sdn_zones_ids($cfg) ];
}


sub generate_etc_network_config {

    my $vnet_cfg = PVE::Cluster::cfs_read_file('sdn/vnets.cfg');
    my $zone_cfg = PVE::Cluster::cfs_read_file('sdn/zones.cfg');
    my $controller_cfg = PVE::Cluster::cfs_read_file('sdn/controllers.cfg');
    return if !$vnet_cfg && !$zone_cfg;

    my $interfaces_config = PVE::INotify::read_file('interfaces');

    #generate configuration
    my $config = {};
    my $nodename = PVE::INotify::nodename();

    foreach my $id (keys %{$vnet_cfg->{ids}}) {
	my $vnet = $vnet_cfg->{ids}->{$id};
	my $zone = $vnet->{zone};

	if(!$zone) {
	    warn "can't generate vnet $vnet : zone $zone don't exist";
	    next;
	}

	my $plugin_config = $zone_cfg->{ids}->{$zone};

	if (!defined($plugin_config)) {
	    warn "can't generate vnet $vnet : zone $zone don't exist";
	    next;
	}

	next if defined($plugin_config->{nodes}) && !$plugin_config->{nodes}->{$nodename};

	my $controller = undef;
	if($plugin_config->{controller}) {
	    my $controllerid = $plugin_config->{controller};
	    $controller	= $controller_cfg->{ids}->{$controllerid};
	}

	my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
	$plugin->generate_sdn_config($plugin_config, $zone, $id, $vnet, $controller, $interfaces_config, $config);
    }

    my $raw_network_config = "";
    foreach my $iface (sort keys %$config) {
	$raw_network_config .= "\n";
	$raw_network_config .= "auto $iface\n";
	$raw_network_config .= "iface $iface\n";
	foreach my $option (@{$config->{$iface}}) {
	    $raw_network_config .= "\t$option\n";
	}
    }

    return $raw_network_config;
}

sub write_etc_network_config {
    my ($rawconfig) = @_;

    return if !$rawconfig;
    my $sdn_interfaces_file = "/etc/network/interfaces.d/sdn";

    my $writefh = IO::File->new($sdn_interfaces_file,">");
    print $writefh $rawconfig;
    $writefh->close();
}

sub ifquery_check {

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

# improve me : move status code inside plugins ?
sub status {

    my $cluster_vnet_file = "/etc/pve/sdn/vnets.cfg";
    my $cluster_zone_file = "/etc/pve/sdn/zones.cfg";
    my $local_sdn_file = "/etc/network/interfaces.d/sdn";
    my $err_config = undef;

    return if !-e $cluster_vnet_file && !-e $cluster_zone_file;

    if (!-e $local_sdn_file) {

	$err_config = "local sdn network configuration is not yet generated, please reload";
	warn "$err_config\n";
    } else {
	# fixme : use some kind of versioning info?
	my $cluster_vnet_timestamp = (stat($cluster_vnet_file))[9];
	my $cluster_zone_timestamp = (stat($cluster_zone_file))[9];
	my $local_sdn_timestamp = (stat($local_sdn_file))[9];

	if ($local_sdn_timestamp < $cluster_vnet_timestamp || $local_sdn_timestamp < $cluster_zone_timestamp) {
	    $err_config = "local sdn network configuration is too old, please reload";
	    warn "$err_config\n";
	}
    }

    my $status = ifquery_check();

    my $vnet_cfg = PVE::Cluster::cfs_read_file('sdn/vnets.cfg');
    my $zone_cfg = PVE::Cluster::cfs_read_file('sdn/zones.cfg');
    my $nodename = PVE::INotify::nodename();


    my $vnet_status = {};
    my $zone_status = {};

    foreach my $id (sort keys %{$vnet_cfg->{ids}}) {
	my $vnet = $vnet_cfg->{ids}->{$id};
	my $zone = $vnet->{zone};
	next if !$zone;

	my $plugin_config = $zone_cfg->{ids}->{$zone};
	next if defined($plugin_config->{nodes}) && !$plugin_config->{nodes}->{$nodename};

	my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
	$plugin->status($plugin_config, $zone, $id, $vnet, $err_config, $status, $vnet_status, $zone_status);
    }

    return($zone_status, $vnet_status);
}

sub get_bridge_vlan {
    my ($vnetid) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);

    return ($vnetid, undef) if !$vnet; # fallback for classic bridge

    my $plugin_config = get_plugin_config($vnet);
    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    return $plugin->get_bridge_vlan($plugin_config, $vnetid, $vnet->{tag});
}

sub tap_create {
    my ($iface, $bridge) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge);
    if (!$vnet) { # fallback for classic bridge
	PVE::Network::tap_create($iface, $bridge);
	return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->tap_create($plugin_config, $vnet, $iface, $bridge);
}

sub veth_create {
    my ($veth, $vethpeer, $bridge, $hwaddr) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge);
    if (!$vnet) { # fallback for classic bridge
	PVE::Network::veth_create($veth, $vethpeer, $bridge, $hwaddr);
	return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->veth_create($plugin_config, $vnet, $veth, $vethpeer, $bridge, $hwaddr);
}

sub tap_plug {
    my ($iface, $bridge, $tag, $firewall, $trunks, $rate) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge);
    if (!$vnet) { # fallback for classic bridge
	PVE::Network::tap_plug($iface, $bridge, $tag, $firewall, $trunks, $rate);
	return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $nodename = PVE::INotify::nodename();

    die "vnet $bridge is not allowed on this node\n"
	if $plugin_config->{nodes} && !defined($plugin_config->{nodes}->{$nodename});

    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->tap_plug($plugin_config, $vnet, $iface, $bridge, $firewall, $rate);
}

1;

