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
use JSON;

use Data::Dumper qw(Dumper);
$Data::Dumper::Sortkeys = 1;

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

#my @plugins = <./ipams/*>;
my @plugins = read_dir('./ipams/', prefix => 1);

foreach my $path (@plugins) {

    my (undef, $ipamid) = split(/\//, $path);
    my $sdn_config = read_sdn_config("$path/sdn_config");

    my $pve_sdn_subnets;
    $pve_sdn_subnets = Test::MockModule->new('PVE::Network::SDN::Subnets');
    $pve_sdn_subnets->mock(
	config => sub {
	    return $sdn_config->{subnets};
	},
    );

    my $pve_sdn_ipam;
    $pve_sdn_subnets = Test::MockModule->new('PVE::Network::SDN::Ipams');
    $pve_sdn_subnets->mock(
	config => sub {
	    my $ipam_config = read_sdn_config("$path/ipam_config");
	    return $ipam_config;
	},
    );

    my $sdn_module = Test::MockModule->new("PVE::Network::SDN");
    $sdn_module->mock(
	config => sub {
	    return $sdn_config;
	},
	api_request => sub {
	    my ($method, $url, $headers, $data) = @_;

	    my $js = JSON->new;
	    $js->canonical(1);

	    my $encoded_data = $js->encode($data) if $data;
	    my $req = HTTP::Request->new($method, $url, $headers, $encoded_data);
	    die Dumper($req);
	},
    );

    #test params;
    my $subnetid = "myzone-10.0.0.0-24";
    my $ip = "10.0.0.1";
    my $hostname = "myhostname";
    my $mac = "da:65:8f:18:9b:6f";
    my $description = "mydescription";
    my $is_gateway = 1;

    my $subnet =
	PVE::Network::SDN::Subnets::sdn_subnets_config($sdn_config->{subnets}, $subnetid, 1);

    my $ipam_cfg = PVE::Network::SDN::Ipams::config();
    my $plugin_config = $ipam_cfg->{ids}->{$ipamid};
    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
    my $sdn_ipam_plugin = Test::MockModule->new($plugin);
    $sdn_ipam_plugin->mock(
	get_prefix_id => sub {
	    return 1;
	},
	get_ip_id => sub {
	    return 1;
	},
	is_ip_gateway => sub {
	    return 1;
	},
    );

    ## add_ip
    my $test = "add_ip";
    my $expected = Dumper read_sdn_config("$path/expected.$test");
    my $name = "$ipamid $test";

    $plugin->add_ip($plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description,
	$is_gateway, 1);

    if ($@) {
	is($@, $expected, $name);
    } else {
	fail($name);
    }

    ## add_next_freeip
    $test = "add_next_freeip";
    $expected = Dumper read_sdn_config("$path/expected.$test");
    $name = "$ipamid $test";

    $plugin->add_next_freeip($plugin_config, $subnetid, $subnet, $hostname, $mac, $description, 1);

    if ($@) {
	is($@, $expected, $name);
    } else {
	fail($name);
    }

    ## del_ip
    $test = "del_ip";
    $expected = Dumper read_sdn_config("$path/expected.$test");
    $name = "$ipamid $test";

    $plugin->del_ip($plugin_config, $subnetid, $subnet, $ip, 1);

    if ($@) {
	is($@, $expected, $name);
    } else {
	fail($name);
    }

    ## update_ip
    $test = "update_ip";
    $expected = Dumper read_sdn_config("$path/expected.$test");
    $name = "$ipamid $test";
    $plugin->update_ip($plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description,
	$is_gateway, 1);

    if ($@) {
	is($@, $expected, $name);
    } else {
	fail($name);
    }

    ## add_ip_notgateway
    $is_gateway = undef;
    $test = "add_ip_notgateway";
    $expected = Dumper read_sdn_config("$path/expected.$test");
    $name = "$ipamid $test";

    $plugin->add_ip($plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description,
	$is_gateway, 1);

    if ($@) {
	is($@, $expected, $name);
    } else {
	fail($name);
    }

    $sdn_ipam_plugin->mock(
	get_prefix_id => sub {
	    return undef;
	},
    );

    ## add_subnet
    $test = "add_subnet";
    $expected = Dumper read_sdn_config("$path/expected.$test");
    $name = "$ipamid $test";

    $plugin->add_subnet($plugin_config, $subnetid, $subnet, 1);

    if ($@) {
	is($@, $expected, $name);
    } else {
	fail($name);
    }

}

done_testing();

