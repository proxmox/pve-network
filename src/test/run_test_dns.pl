#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);
use File::Slurp;
use Net::IP;

use Test::More;
use Test::MockModule;

use PVE::Network::SDN;
use PVE::Network::SDN::Zones;
use PVE::Network::SDN::Controllers;
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

my @plugins = read_dir('./dns/', prefix => 1);

foreach my $path (@plugins) {

    my (undef, $dnsid) = split(/\//, $path);
    my $sdn_config = read_sdn_config("$path/sdn_config");

    my $pve_sdn_dns;
    $pve_sdn_dns = Test::MockModule->new('PVE::Network::SDN::Dns');
    $pve_sdn_dns->mock(
	config => sub {
	    my $dns_config = read_sdn_config("$path/dns_config");
	    return $dns_config;
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

    my $dns_cfg = PVE::Network::SDN::Dns::config();
    my $plugin_config = $dns_cfg->{ids}->{$dnsid};
    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});

    #test params;
    my @ips = ("10.0.0.1", "2001:4860:4860::8888");
    my $zone = "domain.com";
    my $hostname = "myhostname";

    foreach my $ip (@ips) {

	my $ipversion = Net::IP::ip_is_ipv6($ip) ? "ipv6" : "ipv4";
	my $type = Net::IP::ip_is_ipv6($ip) ? "AAAA" : "A";
	my $ip2 = $type eq 'AAAA' ? '2001:4860:4860::8844' : '127.0.0.1';
	my $fqdn = $hostname . "." . $zone . ".";

	my $sdn_dns_plugin = Test::MockModule->new($plugin);
	$sdn_dns_plugin->mock(

	    get_zone_content => sub {
		return undef;
	    },
	    get_zone_rrset => sub {
		return undef;
	    },
	);

	## add_a_record
	my $test = "add_a_record";
	my $expected = Dumper read_sdn_config("$path/expected.$test.$ipversion");
	my $name = "$dnsid $test";

	$plugin->add_a_record($plugin_config, $zone, $hostname, $ip, 1);

	if ($@) {
	    is($@, $expected, $name);
	} else {
	    fail($name);
	}

	## add_ptr_record
	$test = "add_ptr_record";
	$expected = Dumper read_sdn_config("$path/expected.$test.$ipversion");
	$name = "$dnsid $test";

	$plugin->add_ptr_record($plugin_config, $zone, $hostname, $ip, 1);

	if ($@) {
	    is($@, $expected, $name);
	} else {
	    fail($name);
	}

	## del_ptr_record
	$test = "del_ptr_record";
	$expected = Dumper read_sdn_config("$path/expected.$test.$ipversion");
	$name = "$dnsid $test";

	$plugin->del_ptr_record($plugin_config, $zone, $ip, 1);

	if ($@) {
	    is($@, $expected, $name);
	} else {
	    fail($name);
	}

	## del_a_record

	$sdn_dns_plugin->mock(

	    get_zone_content => sub {
		return undef;
	    },
	    get_zone_rrset => sub {

		my $type = Net::IP::ip_is_ipv6($ip) ? "AAAA" : "A";
		my $fqdn = $hostname . "." . $zone . ".";
		my $record = {
		    content => $ip,
		    disabled => JSON::false,
		    name => $fqdn,
		    type => $type,
		};

		my $rrset = {
		    name => $fqdn,
		    type => $type,
		    ttl => '3600',
		    records => [$record],
		};
		return $rrset;
	    },
	);

	$test = "del_a_record";
	$expected = Dumper read_sdn_config("$path/expected.$test.$ipversion");
	$name = "$dnsid $test";

	$plugin->del_a_record($plugin_config, $zone, $hostname, $ip, 1);

	if ($@) {
	    is($@, $expected, $name);
	} else {
	    fail($name);
	}

	## del_a_multiple_record

	$sdn_dns_plugin->mock(

	    get_zone_content => sub {
		return undef;
	    },
	    get_zone_rrset => sub {

		my $record = {
		    content => $ip,
		    disabled => JSON::false,
		    name => $fqdn,
		    type => $type,
		};

		my $record2 = {
		    content => $ip2,
		    disabled => JSON::false,
		    name => $fqdn,
		    type => $type,
		};

		my $rrset = {
		    name => $fqdn,
		    type => $type,
		    ttl => '3600',
		    records => [$record, $record2],
		};
		return $rrset;
	    },
	);

	$test = "del_a_multiple_record";
	$expected = Dumper read_sdn_config("$path/expected.$test.$ipversion");
	$name = "$dnsid $test";

	$plugin->del_a_record($plugin_config, $zone, $hostname, $ip, 1);

	if ($@) {
	    is($@, $expected, $name);
	} else {
	    fail($name);
	}

	## add_a_multiple_record

	$sdn_dns_plugin->mock(

	    get_zone_content => sub {
		return undef;
	    },
	    get_zone_rrset => sub {

		my $record2 = {
		    content => $ip2,
		    disabled => JSON::false,
		    name => $fqdn,
		    type => $type,
		};

		my $rrset = {
		    name => $fqdn,
		    type => $type,
		    ttl => '3600',
		    records => [$record2],
		};
		return $rrset;
	    },
	);

	$test = "add_a_multiple_record";
	$expected = Dumper read_sdn_config("$path/expected.$test.$ipversion");
	$name = "$dnsid $test";

	$plugin->add_a_record($plugin_config, $zone, $hostname, $ip, 1);

	if ($@) {
	    is($@, $expected, $name);
	} else {
	    fail($name);
	}
    }

    ## verify_zone
    my $test = "verify_zone";
    my $expected = Dumper read_sdn_config("$path/expected.$test");
    my $name = "$dnsid $test";

    $plugin->verify_zone($plugin_config, $zone, 1);

    if ($@) {
	is($@, $expected, $name);
    } else {
	fail($name);
    }

}

done_testing();

