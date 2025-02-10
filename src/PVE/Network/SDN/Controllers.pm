package PVE::Network::SDN::Controllers;

use strict;
use warnings;

use JSON;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);

use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones;

use PVE::Network::SDN::Controllers::EvpnPlugin;
use PVE::Network::SDN::Controllers::BgpPlugin;
use PVE::Network::SDN::Controllers::IsisPlugin;
use PVE::Network::SDN::Controllers::FaucetPlugin;
use PVE::Network::SDN::Controllers::Plugin;
PVE::Network::SDN::Controllers::EvpnPlugin->register();
PVE::Network::SDN::Controllers::BgpPlugin->register();
PVE::Network::SDN::Controllers::IsisPlugin->register();
PVE::Network::SDN::Controllers::FaucetPlugin->register();
PVE::Network::SDN::Controllers::Plugin->init();


sub sdn_controllers_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn controller ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn '$id' does not exist\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my $config = cfs_read_file("sdn/controllers.cfg");
    $config = cfs_read_file("sdn/controllers.cfg") if !keys %{$config->{ids}};
    return $config;
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/controllers.cfg", $cfg);
}

sub lock_sdn_controllers_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file("sdn/controllers.cfg", undef, $code);
    if (my $err = $@) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub sdn_controllers_ids {
    my ($cfg) = @_;

    return sort keys %{$cfg->{ids}};
}

sub complete_sdn_controller {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::running_config();

    return  $cmdname eq 'add' ? [] : [ PVE::Network::SDN::sdn_controllers_ids($cfg) ];
}

sub read_etc_network_interfaces {
    # read main config for physical interfaces
    my $current_config_file = "/etc/network/interfaces";
    my $fh = IO::File->new($current_config_file) or die "failed to open $current_config_file - $!\n";
    my $interfaces_config = PVE::INotify::read_etc_network_interfaces($current_config_file, $fh);
    $fh->close();

    return $interfaces_config;
}

sub generate_controller_config {

    my $cfg = PVE::Network::SDN::running_config();
    my $vnet_cfg = $cfg->{vnets};
    my $zone_cfg = $cfg->{zones};
    my $controller_cfg = $cfg->{controllers};

    return if !$vnet_cfg && !$zone_cfg && !$controller_cfg;

    my $interfaces_config = read_etc_network_interfaces();

    # check uplinks
    my $uplinks = {};
    foreach my $id (keys %{$interfaces_config->{ifaces}}) {
	my $interface = $interfaces_config->{ifaces}->{$id};
	if (my $uplink = $interface->{'uplink-id'}) {
	    die "uplink-id $uplink is already defined on $uplinks->{$uplink}" if $uplinks->{$uplink};
	    $interface->{name} = $id;
	    $uplinks->{$interface->{'uplink-id'}} = $interface;
	}
    }

    # generate configuration
    my $config = {};

    foreach my $id (sort keys %{$controller_cfg->{ids}}) {
	my $plugin_config = $controller_cfg->{ids}->{$id};
	my $plugin = PVE::Network::SDN::Controllers::Plugin->lookup($plugin_config->{type});
	$plugin->generate_controller_config($plugin_config, $controller_cfg, $id, $uplinks, $config);
    }

    foreach my $id (sort keys %{$zone_cfg->{ids}}) {
	my $plugin_config = $zone_cfg->{ids}->{$id};
	my $controllerid = $plugin_config->{controller};
	next if !$controllerid;
	my $controller = $controller_cfg->{ids}->{$controllerid};
	if ($controller) {
	    my $controller_plugin = PVE::Network::SDN::Controllers::Plugin->lookup($controller->{type});
	    $controller_plugin->generate_controller_zone_config($plugin_config, $controller, $controller_cfg, $id, $uplinks, $config);
	}
    }

    foreach my $id (sort keys %{$vnet_cfg->{ids}}) {
	my $plugin_config = $vnet_cfg->{ids}->{$id};
	my $zoneid = $plugin_config->{zone};
	next if !$zoneid;
	my $zone = $zone_cfg->{ids}->{$zoneid};
	next if !$zone;
	my $controllerid = $zone->{controller};
	next if !$controllerid;
	my $controller = $controller_cfg->{ids}->{$controllerid};
	if ($controller) {
	    my $controller_plugin = PVE::Network::SDN::Controllers::Plugin->lookup($controller->{type});
	    $controller_plugin->generate_controller_vnet_config($plugin_config, $controller, $zone, $zoneid, $id, $config);
	}
    }

    return $config;
}


sub reload_controller {

    my $cfg = PVE::Network::SDN::running_config();
    my $controller_cfg = $cfg->{controllers};

    return if !$controller_cfg;

    foreach my $id (keys %{$controller_cfg->{ids}}) {
	my $plugin_config = $controller_cfg->{ids}->{$id};
	my $plugin = PVE::Network::SDN::Controllers::Plugin->lookup($plugin_config->{type});
	$plugin->reload_controller();
    }
}

sub generate_controller_rawconfig {
    my ($config) = @_;

    my $cfg = PVE::Network::SDN::running_config();
    my $controller_cfg = $cfg->{controllers};
    return if !$controller_cfg;

    my $rawconfig = "";
    foreach my $id (keys %{$controller_cfg->{ids}}) {
	my $plugin_config = $controller_cfg->{ids}->{$id};
	my $plugin = PVE::Network::SDN::Controllers::Plugin->lookup($plugin_config->{type});
	$rawconfig .= $plugin->generate_controller_rawconfig($plugin_config, $config);
    }
    return $rawconfig;
}

sub write_controller_config {
    my ($config) = @_;

    my $cfg = PVE::Network::SDN::running_config();
    my $controller_cfg = $cfg->{controllers};
    return if !$controller_cfg;

    foreach my $id (keys %{$controller_cfg->{ids}}) {
	my $plugin_config = $controller_cfg->{ids}->{$id};
	my $plugin = PVE::Network::SDN::Controllers::Plugin->lookup($plugin_config->{type});
	$plugin->write_controller_config($plugin_config, $config);
    }
}

1;

