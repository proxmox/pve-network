package PVE::Network::SDN::Ipams::NetboxPlugin;

use strict;
use warnings;
use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;

use base('PVE::Network::SDN::Ipams::Plugin');

sub type {
    return 'netbox';
}

sub properties {
    return {
    };
}

sub options {
    return {
        url => { optional => 0},
        token => { optional => 0 },
        fingerprint => { optional => 1 },
    };
}

sub netbox_api_request {
    my ($config, $method, $path, $params) = @_;

    return PVE::Network::SDN::api_request(
	$method,
	"$config->{url}${path}",
	[
	    'Content-Type' => 'application/json; charset=UTF-8',
	    'Authorization' => "token $config->{token}"
	],
	$params,
	$config->{fingerprint},
    );
}

sub add_dhcp_range {
    my ($config, $dhcp_range, $noerr) = @_;

    my $result = eval {
	netbox_api_request($config, "POST", "/ipam/ip-ranges/", {
	    start_address => $dhcp_range->{'start-address'},
	    end_address => $dhcp_range->{'end-address'},
	});
    };
    if ($@) {
	return if $noerr;
	die "could not create ip range $dhcp_range->{'start-address'}:$dhcp_range->{'end-address'}: $@";
    }

    return $result->{id};
}

sub del_dhcp_range {
    my ($config, $id, $noerr) = @_;

    eval {
	netbox_api_request($config, "DELETE", "/ipam/ip-ranges/$id/");
    };

    die "could not create dhcp range: $@" if $@ && !$noerr;
}

# Plugin implementation

sub add_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $gateway = $subnet->{gateway};

    if (get_prefix_id($plugin_config, $cidr, $noerr)) {
	return if $noerr;
	die "prefix $cidr already exists in netbox";
    }

    eval {
	netbox_api_request($plugin_config, "POST", "/ipam/prefixes/", {
	    prefix => $cidr
	});
    };
    if ($@) {
	return if $noerr;
	die "error adding subnet to ipam: $@";
    }

    my $dhcp_ranges = PVE::Network::SDN::Subnets::get_dhcp_ranges($subnet);
    for my $dhcp_range (@$dhcp_ranges) {
	add_dhcp_range($plugin_config, $dhcp_range, $noerr);
    }
}

sub update_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $old_subnet, $noerr) = @_;

    # old subnet in SubnetPlugin hook has already parsed dhcp-ranges
    # new subnet doesn't
    my $old_dhcp_ranges = $old_subnet->{'dhcp-range'};
    my $new_dhcp_ranges = PVE::Network::SDN::Subnets::get_dhcp_ranges($subnet);

    my $hash_range = sub {
	my ($dhcp_range) = @_;
	"$dhcp_range->{'start-address'} - $dhcp_range->{'end-address'}"
    };

    my $old_lookup = {};
    for my $dhcp_range (@$old_dhcp_ranges) {
	my $hash = $hash_range->($dhcp_range);
	$old_lookup->{$hash} = undef;
    }

    my $new_lookup = {};
    for my $dhcp_range (@$new_dhcp_ranges) {
	my $hash = $hash_range->($dhcp_range);
	$new_lookup->{$hash} = undef;
    }

    my $to_delete_ids = ();

    # delete first so we don't get errors with overlapping ranges
    for my $dhcp_range (@$old_dhcp_ranges) {
	my $hash = $hash_range->($dhcp_range);

	if (exists($new_lookup->{$hash})) {
	    next;
	}

	my $internalid = get_iprange_id($plugin_config, $dhcp_range, $noerr);

	# definedness check, because ID could be 0
	if (!defined($internalid)) {
	    warn "could not find id for ip range $dhcp_range->{'start-address'}:$dhcp_range->{'end-address'}";
	    next;
	}

	del_dhcp_range($plugin_config, $internalid, $noerr);
    }

    for my $dhcp_range (@$new_dhcp_ranges) {
	my $hash = $hash_range->($dhcp_range);

	add_dhcp_range($plugin_config, $dhcp_range, $noerr)
	    if !exists($old_lookup->{$hash});
    }
}

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};

    my $internalid = get_prefix_id($plugin_config, $cidr, $noerr);

    # definedness check, because ID could be 0
    if (!defined($internalid)) {
	warn "could not find id for ip prefix $cidr";
	return;
    }

    if (!is_prefix_empty($plugin_config, $cidr, $noerr)) {
	return if $noerr;
	die "not deleting prefix $cidr because it still contains entries";
    }

    # last IP is assumed to be the gateway, delete it
    if (!$class->del_ip($plugin_config, $subnetid, $subnet, $subnet->{gateway}, $noerr)) {
	return if $noerr;
	die "could not delete gateway ip from subnet $subnetid";
    }

    my $dhcp_ranges = PVE::Network::SDN::Subnets::get_dhcp_ranges($subnet);
    for my $dhcp_range (@$dhcp_ranges) {
	my $internalid = get_iprange_id($plugin_config, $dhcp_range, $noerr);

	# definedness check, because ID could be 0
	if (!defined($internalid)) {
	    warn "could not find id for ip range $dhcp_range->{'start-address'}:$dhcp_range->{'end-address'}";
	    next;
	}

	del_dhcp_range($plugin_config, $internalid, $noerr);
    }

    eval {
	netbox_api_request($plugin_config, "DELETE", "/ipam/prefixes/$internalid/");
    };
    die "error deleting subnet from ipam: $@" if $@ && !$noerr;
}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;

    my $mask = $subnet->{mask};

    my $description = undef;
    if ($is_gateway) {
	$description = 'gateway'
    } elsif ($mac) {
	$description = "mac:$mac";
    }

    eval {
	my $params = {
	    address => "$ip/$mask",
	    description => $description,
	};

	$params->{dns_name} = $hostname if $hostname;

	netbox_api_request($plugin_config, "POST", "/ipam/ip-addresses/", $params);
    };

    if ($@) {
	if ($is_gateway) {
	    die "error add subnet ip to ipam: ip $ip already exist: $@"
		if !is_ip_gateway($plugin_config, $ip, $noerr);
	} elsif (!$noerr) {
	    die "error add subnet ip to ipam: ip already exist: $@";
	}
    }
}

sub update_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;

    my $mask = $subnet->{mask};

    my $description = undef;
    if ($is_gateway) {
	$description = 'gateway'
    } elsif ($mac) {
	$description = "mac:$mac";
    }

    my $ip_id = get_ip_id($plugin_config, $ip, $noerr);

    # definedness check, because ID could be 0
    if (!defined($ip_id)) {
	return if $noerr;
	die "could not find id for ip address $ip";
    }

    eval {
	my $params = {
	    address => "$ip/$mask",
	    description => $description,
	};

	$params->{dns_name} = $hostname if $hostname;

	netbox_api_request($plugin_config, "PATCH", "/ipam/ip-addresses/$ip_id/", $params);
    };
    if ($@) {
	die "error update ip $ip : $@" if !$noerr;
    }
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $vmid, $noerr) = @_;

    my $cidr = $subnet->{cidr};

    my $internalid = get_prefix_id($plugin_config, $cidr, $noerr);

    # definedness check, because ID could be 0
    if (!defined($internalid)) {
	return if $noerr;
	die "could not find id for prefix $cidr";
    }

    my $description = undef;
    $description = "mac:$mac" if $mac;

    my $ip = eval {
	my $params = {
	    description => $description,
	};

	$params->{dns_name} = $hostname if $hostname;

	my $result = netbox_api_request($plugin_config, "POST", "/ipam/prefixes/$internalid/available-ips/", $params);

	my ($ip, undef) = split(/\//, $result->{address});
	return $ip;
    };

    if ($@) {
	die "can't find free ip in subnet $cidr: $@" if !$noerr;
    }

    return $ip;
}

sub add_range_next_freeip {
    my ($class, $plugin_config, $subnet, $range, $data, $noerr) = @_;

    my $internalid = get_iprange_id($plugin_config, $range, $noerr);

    # definedness check, because ID could be 0
    if (!defined($internalid)) {
	return if $noerr;
	die "could not find id for ip range $range->{'start-address'}:$range->{'end-address'}";
    }

    my $description = undef;
    $description = "mac:$data->{mac}" if $data->{mac};

    my $ip = eval {
	my $params = {
	    description => $description,
	};

	$params->{dns_name} = $data->{hostname} if $data->{hostname};

	my $result = netbox_api_request($plugin_config, "POST", "/ipam/ip-ranges/$internalid/available-ips/", $params);

	my ($ip, undef) = split(/\//, $result->{address});
	print "found ip free $ip in range $range->{'start-address'}-$range->{'end-address'}\n" if $ip;
	return $ip;
    };

    if ($@) {
	die "can't find free ip in range $range->{'start-address'}-$range->{'end-address'}: $@" if !$noerr;
    }

    return $ip;
}

sub del_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $noerr) = @_;

    return if !$ip;

    my $ip_id = get_ip_id($plugin_config, $ip, $noerr);
    if (!defined($ip_id)) {
	warn "could not find id for ip $ip";
	return;
    }

    eval {
	netbox_api_request($plugin_config, "DELETE", "/ipam/ip-addresses/$ip_id/");
    };
    if ($@) {
	die "error delete ip $ip : $@" if !$noerr;
    }

    return 1;
}

sub get_ips_from_mac {
    my ($class, $plugin_config, $mac, $zoneid, $noerr) = @_;

    my $ip4 = undef;
    my $ip6 = undef;

    my $data = eval {
	netbox_api_request($plugin_config, "GET", "/ipam/ip-addresses/?description__ic=$mac");
    };
    if ($@) {
	return if $noerr;
	die "could not query ip address entry for mac $mac: $@";
    }

    for my $ip (@{$data->{results}}) {
	if ($ip->{family}->{value} == 4 && !$ip4) {
	    ($ip4, undef) = split(/\//, $ip->{address});
	}

	if ($ip->{family}->{value} == 6 && !$ip6) {
	    ($ip6, undef) = split(/\//, $ip->{address});
	}
    }

    return ($ip4, $ip6);
}

sub verify_api {
    my ($class, $plugin_config) = @_;

    eval { netbox_api_request($plugin_config, "GET", "/ipam/aggregates/"); };
    if ($@) {
	die "Can't connect to netbox api: $@";
    }
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;
    verify_api($class, $plugin_config);
}

# helpers
sub get_prefix_id {
    my ($config, $cidr, $noerr) = @_;

    # we need to supply any IP inside the prefix, without supplying the mask, so
    # just take the one from the cidr
    my ($ip, undef) = split(/\//, $cidr);

    my $result = eval { netbox_api_request($config, "GET", "/ipam/prefixes/?q=$ip") };
    if ($@) {
	return if $noerr;
	die "could not obtain ID for prefix $cidr: $@";
    }

    my $data = @{$result->{results}}[0];
    return $data->{id};
}

sub get_iprange_id {
    my ($config, $range, $noerr) = @_;

    my $result = eval {
	netbox_api_request(
	    $config,
	    "GET",
	    "/ipam/ip-ranges/?start_address=$range->{'start-address'}&end_address=$range->{'end-address'}",
	);
    };
    if ($@) {
	return if $noerr;
	die "could not obtain ID for IP range $range->{'start-address'}:$range->{'end-address'}: $@";
    }

    my $data = @{$result->{results}}[0];
    return $data->{id};
}

sub get_ip_id {
    my ($config, $ip, $noerr) = @_;

    my $result = eval { netbox_api_request($config, "GET", "/ipam/ip-addresses/?q=$ip") };
    if ($@) {
	return if $noerr;
	die "could not obtain ID for IP $ip: $@";
    }

    my $data = @{$result->{results}}[0];
    return $data->{id};
}

sub is_ip_gateway {
    my ($config, $ip, $noerr) = @_;

    my $result = eval { netbox_api_request($config, "GET", "/ipam/ip-addresses/?q=$ip") };
    if ($@) {
	return if $noerr;
	die "could not obtain ipam entry for address $ip: $@";
    }

    my $data = @{$result->{data}}[0];
    return $data->{description} eq 'gateway';
}

sub is_prefix_empty {
    my ($config, $cidr, $noerr) = @_;

    my $result = eval { netbox_api_request($config, "GET", "/ipam/ip-addresses/?parent=$cidr") };
    if ($@) {
	return if $noerr;
	die "could not query children for prefix $cidr: $@";
    }

    # checking against 1, because we do not count the gateway
    return scalar(@{$result->{results}}) <= 1;
}

1;


