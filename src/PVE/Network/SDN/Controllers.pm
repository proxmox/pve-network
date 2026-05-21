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
    $config = cfs_read_file("sdn/controllers.cfg") if !keys %{ $config->{ids} };
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

    my @sorted_ids = sort keys $cfg->{ids}->%*;
    return @sorted_ids;
}

sub complete_sdn_controller {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::running_config();

    return $cmdname eq 'add' ? [] : [PVE::Network::SDN::sdn_controllers_ids($cfg)];
}

sub read_etc_network_interfaces {
    # read main config for physical interfaces
    my $current_config_file = "/etc/network/interfaces";
    my $fh = IO::File->new($current_config_file)
        or die "failed to open $current_config_file - $!\n";
    my $interfaces_config = PVE::INotify::read_etc_network_interfaces($current_config_file, $fh);
    $fh->close();

    return $interfaces_config;
}

sub generate_frr_config {
    my ($frr_config, $sdn_config) = @_;

    my $vnet_cfg = $sdn_config->{vnets};
    my $zone_cfg = $sdn_config->{zones};
    my $controller_cfg = $sdn_config->{controllers};

    return if !$vnet_cfg && !$zone_cfg && !$controller_cfg;

    my $interfaces_config = read_etc_network_interfaces();

    # check uplinks
    my $uplinks = {};
    foreach my $id (keys %{ $interfaces_config->{ifaces} }) {
        my $interface = $interfaces_config->{ifaces}->{$id};
        if (my $uplink = $interface->{'uplink-id'}) {
            die "uplink-id $uplink is already defined on $uplinks->{$uplink}"
                if $uplinks->{$uplink};
            $interface->{name} = $id;
            $uplinks->{ $interface->{'uplink-id'} } = $interface;
        }
    }

    my $allowed_communities = {};

    foreach my $id (sort keys %{ $controller_cfg->{ids} }) {
        my $plugin_config = $controller_cfg->{ids}->{$id};
        my $plugin = PVE::Network::SDN::Controllers::Plugin->lookup($plugin_config->{type});
        $plugin->generate_frr_config($plugin_config, $controller_cfg, $id, $uplinks, $frr_config);

        if ($plugin_config->{type} eq 'evpn') {
            $allowed_communities->{$id} = {
                type => 'standard',
            };
        }
    }

    foreach my $id (sort keys %{ $zone_cfg->{ids} }) {
        my $plugin_config = $zone_cfg->{ids}->{$id};

        my $controllerid = $plugin_config->{controller};
        next if !$controllerid;

        my $controller = $controller_cfg->{ids}->{$controllerid};

        if ($controller) {
            my $controller_plugin =
                PVE::Network::SDN::Controllers::Plugin->lookup($controller->{type});
            $controller_plugin->generate_zone_frr_config(
                $plugin_config, $controller, $controller_cfg, $id, $uplinks, $frr_config,
            );

        }

        my @route_targets;

        if ($plugin_config->{'rt-import'}) {
            @route_targets = PVE::Tools::split_list($plugin_config->{'rt-import'});
        } else {
            $allowed_communities->{$controllerid}->{type} = 'expanded';
            push @route_targets, ".*:$plugin_config->{'vrf-vxlan'}";
        }

        push($allowed_communities->{$controllerid}->{entries}->@*, @route_targets);

        if ($plugin_config->{'secondary-controllers'}) {
            for my $id ($plugin_config->{'secondary-controllers'}->@*) {
                $allowed_communities->{$id}->{type} = 'expanded' if !$plugin_config->{'rt-import'};
                push $allowed_communities->{$id}->{entries}->@*, @route_targets;
            }
        }
    }

    foreach my $id (sort keys %{ $vnet_cfg->{ids} }) {
        my $plugin_config = $vnet_cfg->{ids}->{$id};
        my $zoneid = $plugin_config->{zone};
        next if !$zoneid;
        my $zone = $zone_cfg->{ids}->{$zoneid};
        next if !$zone;
        my $controllerid = $zone->{controller};
        next if !$controllerid;
        my $controller = $controller_cfg->{ids}->{$controllerid};

        my $route_target = ".*:$plugin_config->{'tag'}";

        if ($controller) {
            my $controller_plugin =
                PVE::Network::SDN::Controllers::Plugin->lookup($controller->{type});
            $controller_plugin->generate_vnet_frr_config(
                $plugin_config, $controller, $zone, $zoneid, $id, $frr_config,
            );

            if (!$zone->{'rt-import'}) {
                push $allowed_communities->{$controllerid}->{entries}->@*, $route_target;
            }
        }

        if ($zone->{'secondary-controllers'} && !$zone->{'rt-import'}) {
            for my $id ($zone->{'secondary-controllers'}->@*) {
                push $allowed_communities->{$id}->{entries}->@*, $route_target;
            }
        }
    }

    if (!PVE::Network::SDN::Controllers::EvpnPlugin::skip_route_target_filtering($controller_cfg)) {
        $frr_config->{frr}->{bgp}->{ext_community_lists} = {};

        for my $controller_id (sort keys $allowed_communities->%*) {
            my $community_list_type = $allowed_communities->{$controller_id}->{type};
            my $route_targets = $allowed_communities->{$controller_id}->{entries};

            my $community_list_name = "pve_controller_$controller_id";

            if (defined($route_targets) && scalar($route_targets->@*)) {
                my @entries = map { {
                    action => 'permit',
                    match_entry => ($community_list_type eq 'expanded')
                    ? "^RT:$_\$"
                    : {
                        type => 'rt',
                        value => $_,
                    },
                } } $route_targets->@*;

                $frr_config->{frr}->{bgp}->{ext_community_lists}->{$community_list_name} = {
                    type => $community_list_type,
                    entries => \@entries,
                };
            } else {
                # Since it's impossible to create empty community lists create a
                # community list with one deny entry instead. This works,
                # because the default verdict is to deny any extcommunity that
                # doesn't match an entry in the community list. So this
                # extcommunity-list effectively blocks *every* route.

                $frr_config->{frr}->{bgp}->{ext_community_lists}->{$community_list_name} = {
                    type => 'standard',
                    entries => [
                        {
                            action => 'deny',
                            match_entry => {
                                type => 'rt',
                                value => "0:0",
                            },
                        },
                    ],
                };
            }
        }
    }
}

1;
