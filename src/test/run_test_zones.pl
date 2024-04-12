#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);
use File::Slurp;

use Test::More;
use Test::MockModule;

use PVE::Network::SDN;
use PVE::Network::SDN::Zones;
use PVE::Network::SDN::Controllers;
use PVE::INotify;

sub read_sdn_config {
    my ($file) = @_;

    # Read structure back in again
    open my $in, '<', $file or die $!;
    my $sdn_config;
    {
	local $/; # slurp mode
	$sdn_config = eval <$in>;
    }
    close $in;

    return $sdn_config;
}

my @tests = grep { -d } glob './zones/*/*';

foreach my $test (@tests) {

    my $sdn_config = read_sdn_config("./$test/sdn_config");

    open(my $fh1, '<', "./$test/interfaces") or die "can't read interfaces file - $!";
    my $interfaces_config = PVE::INotify::__read_etc_network_interfaces($fh1, undef, undef);
    close $fh1;

    my $pve_common_inotify;
    $pve_common_inotify = Test::MockModule->new('PVE::INotify');
    $pve_common_inotify->mock(
	nodename => sub {
	    return 'localhost';
	},
	read_file => sub {
	    # HACK this assumes we are always calling PVE::INotify::read_file('interfaces');
	    return $interfaces_config;
	},
	read_etc_network_interfaces => sub {
	    return $interfaces_config;
	},
    );

    my $mocked_pve_sdn_controllers;
    $mocked_pve_sdn_controllers = Test::MockModule->new('PVE::Network::SDN::Controllers');
    $mocked_pve_sdn_controllers->mock(
	read_etc_network_interfaces => sub {
	    return $interfaces_config;
	}
    );

    my $pve_sdn_subnets;
    $pve_sdn_subnets = Test::MockModule->new('PVE::Network::SDN::Subnets');
    $pve_sdn_subnets->mock(
	config => sub {
	    return $sdn_config->{subnets};
	},
    );

    my $pve_sdn_zones_plugin;
    $pve_sdn_zones_plugin = Test::MockModule->new('PVE::Network::SDN::Zones::Plugin');
    $pve_sdn_zones_plugin->mock(
	get_local_route_ip => sub {
	    my $outiface = "vmbr0";
	    my $outip = $interfaces_config->{ifaces}->{$outiface}->{address};
	    return ($outip, $outiface);
	},
	is_vlanaware => sub {
	    return $interfaces_config->{ifaces}->{vmbr0}->{'bridge_vlan_aware'};
	},
	is_ovs => sub {
	    return 1 if $interfaces_config->{ifaces}->{vmbr0}->{'type'} eq 'OVSBridge';
	},
	get_bridge_ifaces => sub {
	    return ('eth0');
	},
	find_bridge => sub {
	    return;
	},
    );

    my $sdn_module = Test::MockModule->new("PVE::Network::SDN");
    $sdn_module->mock(
	running_config => sub {
	    return $sdn_config;
	},
    );

    my $pve_sdn_controllers_plugin;
    $pve_sdn_controllers_plugin = Test::MockModule->new('PVE::Network::SDN::Controllers::Plugin');
    $pve_sdn_controllers_plugin->mock(
	read_iface_mac => sub {
	    return "bc:24:11:1d:69:60";
	},
    );

    my ($first_plugin) = %{$sdn_config->{controllers}->{ids}} if defined $sdn_config->{controllers};
    if ($first_plugin) {
	my $controller_plugin = PVE::Network::SDN::Controllers::Plugin->lookup(
	    $sdn_config->{controllers}->{ids}->{$first_plugin}->{type}
	);
	my $mocked_controller_plugin = Test::MockModule->new($controller_plugin);
	$mocked_controller_plugin->mock(
	    write_controller_config => sub {
		return;
	    },
	    reload_controller => sub {
		return;
	    },
	    read_local_frr_config => sub {
		return;
	    },
	);
    }

    my $name = $test;
    my $expected = read_file("./$test/expected_sdn_interfaces");

    my $result = eval { PVE::Network::SDN::Zones::generate_etc_network_config() };

    if (my $err = $@) {
	diag("got unexpected error - $err");
	fail($name);
    } else {
	is($result, $expected, $name);
    }

    if ($sdn_config->{controllers}) {
	my $expected = read_file("./$test/expected_controller_config");
	my $controller_rawconfig = "";

	eval {
	    my $config = PVE::Network::SDN::Controllers::generate_controller_config();
	    $controller_rawconfig =
		PVE::Network::SDN::Controllers::generate_controller_rawconfig($config);
	};
	if (my $err = $@) {
	    diag("got unexpected error - $err");
	    fail($name);
	} else {
	    is($controller_rawconfig, $expected, $name);
	}
    }
}

done_testing();

