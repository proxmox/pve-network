#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);
use File::Slurp;
use List::Util qw(first all);
use NetAddr::IP qw(:lower);

use Test::More;
use Test::MockModule;

use PVE::Tools qw(extract_param file_set_contents);

use PVE::Network::SDN;
use PVE::Network::SDN::Zones;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Network::SDN::Controllers;
use PVE::Network::SDN::Dns;
use PVE::Network::SDN::Vnets;

use PVE::RESTEnvironment;

use PVE::API2::Network::SDN::Zones;
use PVE::API2::Network::SDN::Subnets;
use PVE::API2::Network::SDN::Vnets;
use PVE::API2::Network::SDN::Ipams;

my $TMP_ETHERS_FILE = "/tmp/ethers";

my $test_state = undef;
sub clear_test_state {
    $test_state = {
	locks => {},
	datacenter_config => {},
	subnets_config => {},
	controller_config => {},
	dns_config => {},
	zones_config => {},
	vnets_config => {},
	macdb => {},
	ipamdb => {},
	ipam_config => {
	    'ids' => {
		'pve' => {
		    'type' => 'pve'
		},
	    }
	},
    };
    PVE::Tools::file_set_contents($TMP_ETHERS_FILE, "\n");
}
clear_test_state();

my $mocked_cfs_lock_file = sub {
    my ($filename, $timeout, $code, @param) = @_;

    die "$filename already locked\n" if ($test_state->{locks}->{$filename});

    $test_state->{locks}->{$filename} = 1;

    my $res = eval { $code->(@param); };

    delete $test_state->{locks}->{$filename};

    return $res;
};

sub read_sdn_config {
    my ($file) = @_;
    # Read structure back in again
    open my $in, '<', $file or die $!;
    my $sdn_config;
    {
	local $/;    # slurp mode
	$sdn_config = eval <$in>;
    }
    close $in;
    return $sdn_config;
}

my $mocked_pve_sdn;
$mocked_pve_sdn = Test::MockModule->new('PVE::Network::SDN');
$mocked_pve_sdn->mock(
    cfs_lock_file => $mocked_cfs_lock_file,
);

my $mocked_pve_tools = Test::MockModule->new('PVE::Tools');
$mocked_pve_tools->mock(
    lock_file => $mocked_cfs_lock_file,
);

my $mocked_sdn_zones;
$mocked_sdn_zones = Test::MockModule->new('PVE::Network::SDN::Zones');
$mocked_sdn_zones->mock(
    config => sub {
	return $test_state->{zones_config};
    },
    write_config => sub {
	my ($cfg) = @_;
	$test_state->{zones_config} = $cfg;
    },
);

my $mocked_sdn_zones_super_plugin;
$mocked_sdn_zones_super_plugin = Test::MockModule->new('PVE::Network::SDN::Zones::Plugin');
$mocked_sdn_zones_super_plugin->mock(
    datacenter_config => sub {
	return $test_state->{datacenter_config};
    },
);

my $mocked_sdn_vnets;
$mocked_sdn_vnets = Test::MockModule->new('PVE::Network::SDN::Vnets');
$mocked_sdn_vnets->mock(
    config => sub {
	return $test_state->{vnets_config};
    },
    write_config => sub {
	my ($cfg) = @_;
	$test_state->{vnets_config} = $cfg;
    },
    cfs_lock_file => $mocked_cfs_lock_file,
);

my $mocked_sdn_subnets;
$mocked_sdn_subnets = Test::MockModule->new('PVE::Network::SDN::Subnets');
$mocked_sdn_subnets->mock(
    config => sub {
	return $test_state->{subnets_config};
    },
    write_config => sub {
	my ($cfg) = @_;
	$test_state->{subnets_config} = $cfg;
    },
    cfs_lock_file => $mocked_cfs_lock_file,
);

my $mocked_sdn_controller;
$mocked_sdn_controller = Test::MockModule->new('PVE::Network::SDN::Controllers');
$mocked_sdn_controller->mock(
    config => sub {
	return $test_state->{controller_config};
    },
    write_config => sub {
	my ($cfg) = @_;
	$test_state->{controller_config} = $cfg;
    },
    cfs_lock_file => $mocked_cfs_lock_file,
);


my $mocked_sdn_dns;
$mocked_sdn_dns = Test::MockModule->new('PVE::Network::SDN::Dns');
$mocked_sdn_dns->mock(
    config => sub {
	return $test_state->{dns_config};
    },
    write_config => sub {
	my ($cfg) = @_;
	$test_state->{dns_config} = $cfg;
    },
    cfs_lock_file => $mocked_cfs_lock_file,
);


my $mocked_sdn_ipams;
$mocked_sdn_ipams = Test::MockModule->new('PVE::Network::SDN::Ipams');
$mocked_sdn_ipams->mock(
    config => sub {
	return $test_state->{ipam_config};
    },
    write_config => sub {
	my ($cfg) = @_;
	$test_state->{ipam_config} = $cfg;
    },
    read_macdb => sub {
	return $test_state->{macdb};
    },
    write_macdb => sub {
	my ($cfg) = @_;
	$test_state->{macdb} = $cfg;
    },
    cfs_lock_file => $mocked_cfs_lock_file,
);

my $ipam_plugin = PVE::Network::SDN::Ipams::Plugin->lookup("pve"); # NOTE this is hard-coded to pve
my $mocked_ipam_plugin = Test::MockModule->new($ipam_plugin);
$mocked_ipam_plugin->mock(
    read_db => sub {
	return $test_state->{ipamdb};
    },
    write_db => sub {
	my ($cfg) = @_;
	$test_state->{ipamdb} = $cfg;
    },
    cfs_lock_file => $mocked_cfs_lock_file,
);

my $mocked_sdn_dhcp_dnsmasq = Test::MockModule->new('PVE::Network::SDN::Dhcp::Dnsmasq');
$mocked_sdn_dhcp_dnsmasq->mock(
    assert_dnsmasq_installed => sub { return 1; },
    before_configure => sub {},
    ethers_file => sub { return "/tmp/ethers"; },
    systemctl_service => sub {},
    update_lease => sub {},
);

my $mocked_api_zones = Test::MockModule->new('PVE::API2::Network::SDN::Zones');
$mocked_api_zones->mock(
    create_etc_interfaces_sdn_dir => sub {},
);

my $rpcenv = PVE::RESTEnvironment->init('priv');
$rpcenv->init_request();
$rpcenv->set_language("en_US.UTF-8");
$rpcenv->set_user('root@pam');

my $mocked_rpc_env_obj = Test::MockModule->new('PVE::RESTEnvironment');
$mocked_rpc_env_obj->mock(
    check_any => sub { return 1; },
);

my $mocked_pve_cluster_obj = Test::MockModule->new('PVE::Cluster');
$mocked_pve_cluster_obj->mock(
    check_cfs_quorum => sub { return 1; },
);

# ------- TEST FUNCTIONS --------------

sub nic_join {
    my ($vnetid, $mac, $hostname, $vmid) = @_;
    return PVE::Network::SDN::Vnets::add_next_free_cidr($vnetid, $hostname, $mac, "$vmid", undef, 1);
}

sub nic_leave {
    my ($vnetid, $mac, $hostname) = @_;
    return PVE::Network::SDN::Vnets::del_ips_from_mac($vnetid, $mac, $hostname);
}

sub nic_start {
    my ($vnetid, $mac, $vmid, $hostname) = @_;
    return PVE::Network::SDN::Vnets::add_dhcp_mapping($vnetid, $mac, $vmid, $hostname);
}


# ---- API HELPER FUNCTIONS FOR THE TESTS -----

my $t_invalid;
sub get_zone {
    my ($id) = @_;
    return eval { PVE::API2::Network::SDN::Zones->read({zone => $id}); };
}
# verify get_zone actually fails if invalid
$t_invalid = get_zone("invalid");
die("getting an invalid zone must fail") if (!$@);
fail("getting an invalid zone must fail") if (defined $t_invalid);

sub create_zone {
    my ($params) = @_;
    my $zoneid = $params->{zone};
    # die if failed!
    eval { PVE::API2::Network::SDN::Zones->create($params); };
    die("creating zone failed: $@") if ($@);

    my $zone = get_zone($zoneid);
    die ("test setup: zone ($zoneid) not defined") if (!defined $zone);
    return $zone;
}

sub get_vnet {
    my ($id) = @_;
    return eval { PVE::API2::Network::SDN::Vnets->read({vnet => $id}); };
}
# verify get_vnet
$t_invalid = get_vnet("invalid");
die("getting an invalid vnet must fail") if (!$@);
fail("getting an invalid vnet must fail") if (defined $t_invalid);

sub create_vnet {
    my ($params) = @_;
    my $vnetid = $params->{vnet};
    PVE::API2::Network::SDN::Vnets->create($params);

    my $vnet = get_vnet($vnetid);
    die ("test setup: vnet ($vnetid) not defined") if (!defined $vnet);
    return $vnet;
}

sub get_subnet {
    my ($id) = @_;
    return eval { PVE::API2::Network::SDN::Subnets->read({subnet => $id}); };
}
# verify get_subnet
$t_invalid = get_subnet("invalid");
die("getting an invalid subnet must fail") if (!$@);
fail("getting an invalid subnet must fail") if (defined $t_invalid);

sub create_subnet {
    my ($params) = @_;
    PVE::API2::Network::SDN::Subnets->create($params);
}

sub get_ipam_entries {
    return PVE::API2::Network::SDN::Ipams->ipamindex({ipam => "pve"});
}

sub create_ip {
    my ($param) = @_;
    return PVE::API2::Network::SDN::Ips->ipcreate($param);
}

sub run_test {
    my $test = shift;
    clear_test_state();
    $test->(@_);
}

sub get_ips_from_mac {
    my ($mac) = @_;
    my $ipam_entries = get_ipam_entries();
    return grep { $_->{mac} eq $mac if defined $_->{mac} } $ipam_entries->@* if $ipam_entries;
}

sub get_ip4 {
    my $ip4 = first { Net::IP::ip_is_ipv4($_->{ip}) } @_;
    return $ip4->{ip} if defined $ip4;
}

sub get_ip6 {
    my $ip6 = first { Net::IP::ip_is_ipv6($_->{ip}) } @_;
    return $ip6->{ip} if defined $ip6;
}


# -------------- ACTUAL TESTS  -----------------------

sub test_create_vnet_with_gateway {
    my $test_name = (split(/::/,(caller(0))[3]))[-1];
    my $zoneid = "TESTZONE";
    my $vnetid = "testvnet";

    my $zone = create_zone({
	type => "simple",
	dhcp => "dnsmasq",
	ipam => "pve",
	zone => $zoneid,
    });

    my $vnet = create_vnet({
	type => "vnet",
	zone => $zoneid,
	vnet => $vnetid,
    });

    create_subnet({
	type => "subnet",
	vnet => $vnetid,
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    });

    my ($p) = first { $_->{gateway} == 1 } get_ipam_entries()->@*;
    ok ($p, "$test_name: Gateway IP was created in IPAM");
}
run_test(\&test_create_vnet_with_gateway);


sub test_without_subnet {
    my $test_name = (split(/::/,(caller(0))[3]))[-1];

    my $zoneid = "TESTZONE";
    my $vnetid = "testvnet";

    my $zone = create_zone({
	type => "simple",
	dhcp => "dnsmasq",
	ipam => "pve",
	zone => $zoneid,
    });

    my $vnet = create_vnet({
	type => "vnet",
	zone => $zoneid,
	vnet => $vnetid,
    });

    my $hostname = "testhostname";
    my $mac = "da:65:8f:18:9b:6f";
    my $vmid = "999";

    eval {
	nic_join($vnetid, $mac, $hostname, $vmid);
    };

    if ($@) {
	fail("$test_name: $@");
	return;
    }

    my @ips = get_ips_from_mac($mac);
    my $num_ips = scalar @ips;
    is ($num_ips, 0, "$test_name: No IP allocated in IPAM");
}
run_test(\&test_without_subnet);


sub test_nic_join {
    my ($test_name, $subnets) = @_;

    die "$test_name: we're expecting an array of subnets" if !$subnets;
    my $num_subnets = scalar $subnets->@*;
    die "$test_name: we're expecting an array of subnets. $num_subnets elements found" if ($num_subnets < 1);

    my $zoneid = "TESTZONE";
    my $vnetid = "testvnet";

    my $zone = create_zone({
	type => "simple",
	dhcp => "dnsmasq",
	ipam => "pve",
	zone => $zoneid,
    });

    my $vnet = create_vnet({
	type => "vnet",
	zone => $zoneid,
	vnet => $vnetid,
    });

    foreach my $subnet ($subnets->@*) {
	$subnet->{type} = "subnet";
	$subnet->{vnet} = $vnetid;
	create_subnet($subnet);
    };

    my $hostname = "testhostname";
    my $mac = "da:65:8f:18:9b:6f";
    my $vmid = "999";

    eval {
	nic_join($vnetid, $mac, $hostname, $vmid);
    };

    if ($@) {
	fail("$test_name: $@");
	return;
    }

    my @ips = get_ips_from_mac($mac);
    my $num_ips = scalar @ips;
    is ($num_ips, $num_subnets, "$test_name: Expecting $num_subnets IPs, found $num_ips");
    ok ((all { ($_->{vnet} eq $vnetid && $_->{zone} eq $zoneid) } @ips),
	"$test_name: all IPs in correct vnet and zone"
    );
}

run_test(
    \&test_nic_join,
    "nic_join IPv4 no dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
    },
]);

run_test(
    \&test_nic_join,
    "nic_join IPv6 no dhcp",
    [{
	subnet => "8888::/64",
	gateway => "8888::1",
    },
]);

run_test(
    \&test_nic_join,
    "nic_join IPv4+6 no dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
    },
]);

run_test(
    \&test_nic_join,
    "nic_join IPv4 with dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    },
]);

run_test(
    \&test_nic_join,
    "nic_join IPv6 with dhcp",
    [{
	subnet => "8888::/64",
	gateway => "8888::1",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::200"],
    },
]);

run_test(
    \&test_nic_join,
    "nic_join IPv4+6 with dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::200"],
    },
]);

run_test(
    \&test_nic_join,
    "nic_join IPv4 no DHCP, IPv6 with DHCP",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::200"],
    },
]);

run_test(
    \&test_nic_join,
    "nic_join IPv4 with DHCP, IPv6 no DHCP",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
    },
]);


sub test_nic_join_full_dhcp_range {
    my ($test_name, $subnets, $expected_ip4, $expected_ip6) = @_;

    die "$test_name: we're expecting an array of subnets" if !$subnets;
    my $num_subnets = scalar $subnets->@*;
    die "$test_name: we're expecting an array of subnets. $num_subnets elements found" if ($num_subnets < 1);

    my $zoneid = "TESTZONE";
    my $vnetid = "testvnet";

    my $zone = create_zone({
	type => "simple",
	dhcp => "dnsmasq",
	ipam => "pve",
	zone => $zoneid,
    });

    my $vnet = create_vnet({
	type => "vnet",
	zone => $zoneid,
	vnet => $vnetid,
    });

    foreach my $subnet ($subnets->@*) {
	$subnet->{type} = "subnet";
	$subnet->{vnet} = $vnetid;
	create_subnet($subnet);
    };

    my $hostname = "testhostname";
    my $mac = "da:65:8f:18:9b:6f";
    my $vmid = "999";

    eval {
	nic_join($vnetid, $mac, $hostname, $vmid);
    };

    if (! $@) {
	fail ("$test_name: nic_join() is expected to fail because we cannot allocate all IPs");
    }

    my @ips = get_ips_from_mac($mac);
    my $num_ips = scalar @ips;
    is ($num_ips, 0, "$test_name: No IP allocated in IPAM");
}

run_test(
    \&test_nic_join_full_dhcp_range,
    "nic_join IPv4 with DHCP, dhcp-range full",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.100", # the gateway uses the only available IP in the dhcp-range
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.100"],
    }
]);

run_test(
    \&test_nic_join_full_dhcp_range,
    "nic_join IPv6 with DHCP, dhcp-range full",
    [{
	subnet => "8888::/64",
	gateway => "8888::100", # the gateway uses the only available IP in the dhcp-range
	'dhcp-range' => ["start-address=8888::100,end-address=8888::100"],
    },
]);

run_test(
    \&test_nic_join_full_dhcp_range,
    "nic_join IPv4+6 with DHCP, dhcp-range full for both",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.100",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.100"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::100",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::100"],
    }
]);

run_test(
    \&test_nic_join_full_dhcp_range,
    "nic_join IPv4+6 with DHCP, dhcp-range full for IPv4",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.100", # the gateway uses the only available IP in the dhcp-range
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.100"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::100"],
    }],
);

run_test(
    \&test_nic_join_full_dhcp_range,
    "nic_join IPv4+6 with DHCP, dhcp-range full for IPv6",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.100"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::100",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::100"],
    }],
);

run_test(
    \&test_nic_join_full_dhcp_range,
    "nic_join IPv4 no DHCP, dhcp-range full for IPv6",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
    }, {
	subnet => "8888::/64",
	gateway => "8888::100",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::100"],
    }],
);


# -------------- nic_start
sub test_nic_start {
    my ($test_name, $subnets, $current_ip4, $current_ip6, $num_expected_ips) = @_;

    die "$test_name: we're expecting an array of subnets" if !$subnets;
    my $num_subnets = scalar $subnets->@*;
    die "$test_name: we're expecting an array of subnets. $num_subnets elements found" if ($num_subnets < 1);
    $num_expected_ips = $num_subnets if !defined $num_expected_ips;

    my $zoneid = "TESTZONE";
    my $vnetid = "testvnet";

    my $zone = create_zone({
	type => "simple",
	dhcp => "dnsmasq",
	ipam => "pve",
	zone => $zoneid,
    });

    my $vnet = create_vnet({
	type => "vnet",
	zone => $zoneid,
	vnet => $vnetid,
    });

    foreach my $subnet ($subnets->@*) {
	$subnet->{type} = "subnet";
	$subnet->{vnet} = $vnetid;
	create_subnet($subnet);
    };

    my $hostname = "testhostname";
    my $mac = "da:65:8f:18:9b:6f";
    my $vmid = "999";

    if ($current_ip4) {
	create_ip({
	    zone => $zoneid,
	    vnet => $vnetid,
	    mac => $mac,
	    ip => $current_ip4,
	});
    }

    if ($current_ip6) {
	create_ip({
	    zone => $zoneid,
	    vnet => $vnetid,
	    mac => $mac,
	    ip => $current_ip6,
	});
    }
    my @current_ips = get_ips_from_mac($mac);
    is ( get_ip4(@current_ips), $current_ip4, "$test_name: setup current IPv4: $current_ip4" ) if defined $current_ip4;
    is ( get_ip6(@current_ips), $current_ip6, "$test_name: setup current IPv6: $current_ip6" ) if defined $current_ip6;

    eval {
	nic_start($vnetid, $mac, $hostname, $vmid);
    };

    if ($@) {
	fail("$test_name: $@");
	return;
    }

    my @ips = get_ips_from_mac($mac);
    my $num_ips = scalar @ips;
    is ($num_ips, $num_expected_ips, "$test_name: Expecting $num_expected_ips IPs, found $num_ips");
    ok ((all { ($_->{vnet} eq $vnetid && $_->{zone} eq $zoneid) } @ips),
	"$test_name: all IPs in correct vnet and zone"
    );

    is ( get_ip4(@ips), $current_ip4, "$test_name: still current IPv4: $current_ip4" ) if $current_ip4;
    is ( get_ip6(@ips), $current_ip6, "$test_name: still current IPv6: $current_ip6" ) if $current_ip6;
}

run_test(
    \&test_nic_start,
    "nic_start no IP, IPv4 without dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
    },
]);

run_test(
    \&test_nic_start,
    "nic_start already IP, IPv4 without dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
    }],
    "10.0.0.99",
    undef,
    1
);

run_test(
    \&test_nic_start,
    "nic_start already IPv6, IPv6 without dhcp",
    [{
	subnet => "8888::/64",
	gateway => "8888::1",
    }],
    undef,
    "8888::99",
    1
);

run_test(
    \&test_nic_start,
    "nic_start no IP, IPv4 subnet with dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    },
]);

run_test(
    \&test_nic_start,
    "nic_start already IP, IPv4 subnet with dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    }],
    "10.0.0.99"
);

run_test(
    \&test_nic_start,
    "nic_start already IP, IPv6 subnet with dhcp",
    [{
	subnet => "8888::/64",
	gateway => "8888::1",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::200"],
    }],
    undef,
    "8888::99"
);

run_test(
    \&test_nic_start,
    "nic_start IP, IPv4+6 subnet with dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::200"],
    },
]);

run_test(
    \&test_nic_start,
    "nic_start already IPv4, IPv4+6 subnet with dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::200"],
    }],
    "10.0.0.99"
);

run_test(
    \&test_nic_start,
    "nic_start already IPv6, IPv4+6 subnet with dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::200"],
    }],
    undef,
    "8888::99"
);

run_test(
    \&test_nic_start,
    "nic_start already IPv4+6, IPv4+6 subnets with dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
	'dhcp-range' => ["start-address=8888::100,end-address=8888::200"],
    }],
    "10.0.0.99",
    "8888::99"
);

run_test(
    \&test_nic_start,
    "nic_start already IPv4+6, only IPv4 subnet with dhcp",
    [{
	subnet => "10.0.0.0/24",
	gateway => "10.0.0.1",
	'dhcp-range' => ["start-address=10.0.0.100,end-address=10.0.0.200"],
    }, {
	subnet => "8888::/64",
	gateway => "8888::1",
    }],
    "10.0.0.99",
    "8888::99",
    2
);

done_testing();
