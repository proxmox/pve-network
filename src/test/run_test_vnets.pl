#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);
use File::Slurp;
use NetAddr::IP qw(:lower);

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

my @plugins = read_dir('./vnets/', prefix => 1);

foreach my $path (@plugins) {

    my (undef, $testid) = split(/\//, $path);

    print "test: $testid\n";
    my $sdn_config = read_sdn_config("$path/sdn_config");

    my $pve_sdn_zones;
    $pve_sdn_zones = Test::MockModule->new('PVE::Network::SDN::Zones');
    $pve_sdn_zones->mock(
	config => sub {
	    return $sdn_config->{zones};
	},
    );

    my $pve_sdn_vnets;
    $pve_sdn_vnets = Test::MockModule->new('PVE::Network::SDN::Vnets');
    $pve_sdn_vnets->mock(
	config => sub {
	    return $sdn_config->{vnets};
	},
    );

    my $pve_sdn_subnets;
    $pve_sdn_subnets = Test::MockModule->new('PVE::Network::SDN::Subnets');
    $pve_sdn_subnets->mock(
	config => sub {
	    return $sdn_config->{subnets};
	},
	verify_dns_zone => sub {
	    return;
	},
	add_dns_record => sub {
	    return;
	},
    );

    my $js = JSON->new;
    $js->canonical(1);

    #test params;
    #test params;
    my $subnets = $sdn_config->{subnets}->{ids};

    my $subnetid = (sort keys %{$subnets})[0];
    my $subnet =
	PVE::Network::SDN::Subnets::sdn_subnets_config($sdn_config->{subnets}, $subnetid, 1);
    my $subnet_cidr = $subnet->{cidr};
    my $iplist = NetAddr::IP->new($subnet_cidr);
    my $mask = $iplist->masklen();
    my $ipversion = undef;

    if (Net::IP::ip_is_ipv4($iplist->canon())) {
	$iplist++; #skip network address for ipv4
	$ipversion = 4;
    } else {
	$ipversion = 6;
    }

    my $cidr1 = $iplist->canon() . "/$mask";
    $iplist++;
    my $cidr2 = $iplist->canon() . "/$mask";
    my $cidr_outofrange = '8.8.8.8/8';

    my $subnetid2 = (sort keys %{$subnets})[1];
    my $subnet2 =
	PVE::Network::SDN::Subnets::sdn_subnets_config($sdn_config->{subnets}, $subnetid2, 1);
    my $subnet2_cidr = $subnet2->{cidr};
    my $iplist2 = NetAddr::IP->new($subnet2_cidr);
    $iplist2++;
    my $cidr3 = $iplist2->canon() . "/$mask";
    $iplist2++;
    my $cidr4 = $iplist2->canon() . "/$mask";

    my $hostname = "myhostname";
    my $mac = "da:65:8f:18:9b:6f";
    my $description = "mydescription";
    my $ipamdb = read_sdn_config("$path/ipam.db");

    my $zone = $sdn_config->{zones}->{ids}->{"myzone"};
    my $ipam = $zone->{ipam};

    my $plugin;
    my $sdn_ipam_plugin;
    if ($ipam) {
	$plugin = PVE::Network::SDN::Ipams::Plugin->lookup($ipam);
	$sdn_ipam_plugin = Test::MockModule->new($plugin);
	$sdn_ipam_plugin->mock(
	    read_db => sub {
		return $ipamdb;
	    },
	    write_db => sub {
		my ($cfg) = @_;
		$ipamdb = $cfg;
	    },
	);
    }

    my $pve_sdn_ipams;
    $pve_sdn_ipams = Test::MockModule->new('PVE::Network::SDN::Ipams');
    $pve_sdn_ipams->mock(
	config => sub {
	    my $ipam_config = read_sdn_config("$path/ipam_config");
	    return $ipam_config;
	},
    );

    my $vnetid = "myvnet";

    ## add_ip
    my $test = "add_cidr $cidr1";
    my $name = "$testid $test";
    my $result = undef;
    my $expected = '';

    eval { PVE::Network::SDN::Vnets::add_cidr($vnetid, $cidr1, $hostname, $mac, $description); };

    if ($@) {
	fail("$name : $@");
    } else {
	is(undef, undef, $name);
    }

    ## add_ip
    $test = "add_already_exist_cidr $cidr1";
    $name = "$testid $test";
    $result = undef;
    $expected = '';

    eval { PVE::Network::SDN::Vnets::add_cidr($vnetid, $cidr1, $hostname, $mac, $description); };

    if ($@) {
	is(undef, undef, $name);
    } elsif ($ipam) {
	fail("$name : $@");
    } else {
	is(undef, undef, $name);
    }

    ## add_ip
    $test = "add_cidr $cidr2";
    $name = "$testid $test";
    $result = undef;
    $expected = '';

    eval { PVE::Network::SDN::Vnets::add_cidr($vnetid, $cidr2, $hostname, $mac, $description); };

    if ($@) {
	fail("$name : $@");
    } else {
	is(undef, undef, $name);
    }

    ## add_ip
    $test = "add_ip_out_of_range_subnets $cidr_outofrange";
    $name = "$testid $test";
    $result = undef;
    $expected = '';

    eval {
	PVE::Network::SDN::Vnets::add_cidr($vnetid, $cidr_outofrange, $hostname, $mac,
	    $description);
    };

    if ($@) {
	is(undef, undef, $name);
    } else {
	fail("$name : $@");
    }

    ## add_ip
    $test = "add_cidr $cidr4";
    $name = "$testid $test";
    $result = undef;
    $expected = '';

    eval { PVE::Network::SDN::Vnets::add_cidr($vnetid, $cidr4, $hostname, $mac, $description); };

    if ($@) {
	fail("$name : $@");
    } else {
	is(undef, undef, $name);
    }

    $test = "find_next_free_cidr_in_second_subnet ($cidr3)";
    $name = "$testid $test";
    $result = undef;
    $expected = $ipam ? $cidr3 : undef;

    eval {
	$result =
	    PVE::Network::SDN::Vnets::add_next_free_cidr($vnetid, $hostname, $mac, $description);
    };

    if ($@) {
	fail("$name : $@");
    } else {
	is($result, $expected, $name);
    }

    $test = "del_cidr $cidr1";
    $name = "$testid $test";
    $result = undef;
    $expected = undef;

    eval { $result = PVE::Network::SDN::Vnets::del_cidr($vnetid, $cidr1, $hostname); };

    if ($@) {
	fail("$name : $@");
    } else {
	is(undef, undef, $name);
    }

    $test = "del_cidr $cidr3";
    $name = "$testid $test";
    $result = undef;
    $expected = undef;

    eval { $result = PVE::Network::SDN::Vnets::del_cidr($vnetid, $cidr3, $hostname); };

    if ($@) {
	fail("$name : $@");
    } else {
	is(undef, undef, $name);
    }

    $test = "del_cidr not exist $cidr1";
    $name = "$testid $test";
    $result = undef;
    $expected = undef;

    eval { $result = PVE::Network::SDN::Vnets::del_cidr($vnetid, $cidr1, $hostname); };

    if ($@) {
	is(undef, undef, $name);
    } elsif ($ipam) {
	fail("$name : $@");
    } else {
	is(undef, undef, $name);
    }

    $test = "del_cidr outofrange $cidr_outofrange";
    $name = "$testid $test";
    $result = undef;
    $expected = undef;

    eval { $result = PVE::Network::SDN::Vnets::del_cidr($vnetid, $cidr_outofrange, $hostname); };

    if ($@) {
	is(undef, undef, $name);
    } else {
	fail("$name : $@");
    }

    $test = "find_next_free_cidr_in_first_subnet ($cidr1)";
    $name = "$testid $test";
    $result = undef;
    $expected = $ipam ? $cidr1 : undef;

    eval {
	$result =
	    PVE::Network::SDN::Vnets::add_next_free_cidr($vnetid, $hostname, $mac, $description);
    };

    if ($@) {
	fail("$name : $@");
    } else {
	is($result, $expected, $name);
    }

    $test = "update_cidr $cidr1";
    $name = "$testid $test";
    $result = undef;
    $expected = undef;

    eval {
	$result = PVE::Network::SDN::Vnets::update_cidr($vnetid, $cidr1, $hostname, $hostname, $mac,
	    $description);
    };

    if ($@) {
	fail("$name : $@");
    } else {
	is(undef, undef, $name);
    }

    $test = "update_cidr deleted $cidr3";
    $name = "$testid $test";
    $result = undef;
    $expected = undef;

    eval {
	$result = PVE::Network::SDN::Vnets::update_cidr($vnetid, $cidr1, $hostname, $hostname, $mac,
	    $description);
    };

    if ($@) {
	fail("$name : $@");
    } else {
	is(undef, undef, $name);
    }

}

done_testing();

