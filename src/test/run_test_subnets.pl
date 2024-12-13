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

my $locks = {};

my $mocked_cfs_lock_file = sub {
    my ($filename, $timeout, $code, @param) = @_;

    die "$filename already locked\n" if ($locks->{$filename});

    $locks->{$filename} = 1;

    my $res = eval { $code->(@param); };

    delete $locks->{$filename};

    return $res;
};

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

my @plugins = read_dir('./subnets/', prefix => 1);

foreach my $path (@plugins) {

    my (undef, $testid) = split(/\//, $path);

    print "test: $testid\n";
    my $sdn_config = read_sdn_config("$path/sdn_config");

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
    my $subnets = $sdn_config->{subnets}->{ids};
    my $subnetid = (keys %{$subnets})[0];
    my $subnet =
	PVE::Network::SDN::Subnets::sdn_subnets_config($sdn_config->{subnets}, $subnetid, 1);

    my $subnet_cidr = $subnet->{cidr};
    my $iplist = NetAddr::IP->new($subnet_cidr);
    $iplist++ if Net::IP::ip_is_ipv4($iplist->canon()); #skip network address for ipv4
    my $ip = $iplist->canon();
    $iplist++;
    my $ipnextfree = $iplist->canon();
    $iplist++;
    my $ip2 = $iplist->canon();

    my $ip3 = undef;
    my $hostname = "myhostname";
    my $mac = "da:65:8f:18:9b:6f";
    my $vmid = "100";
    my $is_gateway = 1;
    my $ipamdb = {};

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
	    cfs_lock_file => $mocked_cfs_lock_file,
	);
    }

    my $pve_sdn_ipams;
    $pve_sdn_ipams = Test::MockModule->new('PVE::Network::SDN::Ipams');
    $pve_sdn_ipams->mock(
	config => sub {
	    my $ipam_config = read_sdn_config("$path/ipam_config");
	    return $ipam_config;
	},
	add_cache_mac_ip => sub {
	    return;
	},
	del_cache_mac_ip => sub {
	    return;
	},
    );

    ## add_subnet
    my $test = "add_subnet $subnetid";
    my $name = "$testid $test";
    my $result = undef;
    my $expected = '{"zones":{"myzone":{"subnets":{"' . $subnet_cidr . '":{"ips":{}}}}}}';

    eval {
	PVE::Network::SDN::Subnets::add_subnet($zone, $subnetid, $subnet);

    };

    if ($@) {
	fail("$name : $@");
    } elsif ($ipam) {
	$result = $js->encode($plugin->read_db());
	is($result, $expected, $name);
    } else {
	is(undef, undef, $name);
    }

    ## add_ip
    $test = "add_ip $ip";
    $name = "$testid $test";
    $result = undef;
    $expected =
	'{"zones":{"myzone":{"subnets":{"'
	. $subnet_cidr
	. '":{"ips":{"'
	. $ip
	. '":{"gateway":1}}}}}}}';

    eval {
	PVE::Network::SDN::Subnets::add_ip($zone, $subnetid, $subnet, $ip, $hostname, $mac, $vmid,
	    $is_gateway);
    };

    if ($@) {
	fail("$name : $@");
    } elsif ($ipam) {
	$result = $js->encode($plugin->read_db());
	is($result, $expected, $name);
    } else {
	is(undef, undef, $name);
    }

    if ($ipam) {
	## add_already_exist_ip
	$test = "add_already_exist_ip $ip";
	$name = "$testid $test";

	eval {
	    PVE::Network::SDN::Subnets::add_ip($zone, $subnetid, $subnet, $ip, $hostname, $mac,
		$vmid);
	};

	if ($@) {
	    is(undef, undef, $name);
	} else {
	    fail("$name : $@");
	}
    }

    ## add_second_ip
    $test = "add_second_ip $ip2";
    $name = "$testid $test";
    $result = undef;
    $expected =
	'{"zones":{"myzone":{"subnets":{"'
	. $subnet_cidr
	. '":{"ips":{"'
	. $ip
	. '":{"gateway":1},"'
	. $ip2
	. '":{"hostname":"'
	. $hostname
	. '","mac":"'
	. $mac
	. '","vmid":"'
	. $vmid
	. '"}}}}}}}';

    eval {
	PVE::Network::SDN::Subnets::add_ip($zone, $subnetid, $subnet, $ip2, $hostname, $mac, $vmid);
    };

    if ($@) {
	fail("$name : $@");
    } elsif ($ipam) {
	$result = $js->encode($plugin->read_db());
	is($result, $expected, $name);
    } else {
	is(undef, undef, $name);
    }

    ## add_next_free
    $test = "find_next_freeip ($ipnextfree)";
    $name = "$testid $test";
    $result = undef;
    $expected =
	'{"zones":{"myzone":{"subnets":{"'
	. $subnet_cidr
	. '":{"ips":{"'
	. $ip
	. '":{"gateway":1},"'
	. $ipnextfree
	. '":{"hostname":"'
        . $hostname
        . '","mac":"'
	. $mac
	. '","vmid":"'
	. $vmid
        . '"},"'
	. $ip2
	. '":{"hostname":"'
	. $hostname
	. '","mac":"'
	. $mac
	. '","vmid":"'
	. $vmid
	. '"}}}}}}}';

    eval {
	$ip3 = PVE::Network::SDN::Subnets::add_next_free_ip($zone, $subnetid, $subnet, $hostname,
	    $mac, $vmid);
    };

    if ($@) {
	fail("$name : $@");
    } elsif ($ipam) {
	$result = $js->encode($plugin->read_db());
	is($result, $expected, $name);
    }

    ## del_ip
    $test = "del_ip $ip";
    $name = "$testid $test";
    $result = undef;
    $expected =
	'{"zones":{"myzone":{"subnets":{"'
	. $subnet_cidr
	. '":{"ips":{"'
	. $ipnextfree
	. '":{"hostname":"'
        . $hostname
        . '","mac":"'
	. $mac
	. '","vmid":"'
	. $vmid
        . '"},"'
	. $ip2
	. '":{"hostname":"'
	. $hostname
	. '","mac":"'
	. $mac
	. '","vmid":"'
	. $vmid
	. '"}}}}}}}';

    eval { PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $subnet, $ip, $hostname); };

    if ($@) {
	fail("$name : $@");
    } elsif ($ipam) {
	$result = $js->encode($plugin->read_db());
	is($result, $expected, $name);
    } else {
	is(undef, undef, $name);
    }

    if ($ipam) {
	## del_subnet_not_empty
	$test = "del_subnet_not_empty $subnetid";
	$name = "$testid $test";
	$result = undef;
	$expected = undef;

	eval { PVE::Network::SDN::Subnets::del_subnet($zone, $subnetid, $subnet); };

	if ($@) {
	    is($result, $expected, $name);
	} else {
	    fail("$name : $@");
	}
    }

    ## add_ip_rollback_failing_dns
    $test = "add_ip_rollback_failing_dns";

    $pve_sdn_subnets->mock(
	config => sub {
	    return $sdn_config->{subnets};
	},
	verify_dns_zone => sub {
	    return;
	},
	add_dns_record => sub {
	    die "error add dns record";
	    return;
	},
    );

    $name = "$testid $test";
    $result = undef;
    $expected =
	'{"zones":{"myzone":{"subnets":{"'
	. $subnet_cidr
	. '":{"ips":{"'
	. $ipnextfree
	. '":{"hostname":"'
        . $hostname
        . '","mac":"'
	. $mac
	. '","vmid":"'
	. $vmid
        . '"},"'
	. $ip2
	. '":{"hostname":"'
	. $hostname
	. '","mac":"'
	. $mac
	. '","vmid":"'
	. $vmid
	. '"}}}}}}}';

    eval {
	PVE::Network::SDN::Subnets::add_ip($zone, $subnetid, $subnet, $ip, $hostname, $mac, $vmid);
    };

    if ($@) {
	if ($ipam) {
	    $result = $js->encode($plugin->read_db());
	    is($result, $expected, $name);
	} else {
	    is(undef, undef, $name);
	}
    } else {
	fail("$name : $@");
    }

    ## del_empty_subnet
    $test = "del_empty_subnet";
    $name = "$testid $test";
    $result = undef;
    $expected = '{"zones":{"myzone":{"subnets":{}}}}';

    PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $subnet, $ip2, $hostname);
    PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $subnet, $ip3, $hostname);

    eval { PVE::Network::SDN::Subnets::del_subnet($zone, $subnetid, $subnet); };

    if ($@) {
	fail("$name : $@");
    } elsif ($ipam) {
	$result = $js->encode($plugin->read_db());
	is($result, $expected, $name);
    } else {
	is(undef, undef, $name);
    }

}

done_testing();

