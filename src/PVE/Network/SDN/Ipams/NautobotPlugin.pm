package PVE::Network::SDN::Ipams::NautobotPlugin;

use strict;
use warnings;
use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;
use List::Util qw(all);
use NetAddr::IP;

use base('PVE::Network::SDN::Ipams::Plugin');

sub type {
    return 'nautobot';
}

sub properties {
    return {
	namespace => {
	    type => 'string',
	},
    };
}

sub options {
    return {
	url => { optional => 0 },
	token => { optional => 0 },
	namespace => { optional => 0 },
    };
}

sub default_ip_status {
    return 'Active';
}

sub default_headers {
    my ($plugin_config) = @_;
    my $token = $plugin_config->{token};

    return ['Content-Type' => "application/json", 'Authorization' => "token $token", 'Accept' => "application/json"];
}

# implem

sub add_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $gateway = $subnet->{gateway};
    my $url = $plugin_config->{url};
    my $namespace = $plugin_config->{namespace};
    my $headers = default_headers($plugin_config);

    my $internalid = get_prefix_id($url, $cidr, $headers, $noerr);

    #create subnet if it doesn't already exists
    if (!$internalid) {
	my $params = { prefix => $cidr, namespace => $namespace, status => default_ip_status()};

	eval {
		my $result = PVE::Network::SDN::api_request("POST", "$url/ipam/prefixes/", $headers, $params);
	};
	if ($@) {
	    die "error adding subnet to ipam: $@" if !$noerr;
	}
    }
}

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $url = $plugin_config->{url};
    my $headers = default_headers($plugin_config);

    my $internalid = get_prefix_id($url, $cidr, $headers, $noerr);
    return if !$internalid;

    if (!subnet_is_deletable($class, $plugin_config, $subnetid, $subnet, $internalid, $noerr)) {
	die "cannot delete prefix $cidr, not empty!";
    }

    # delete associated IP addresses (normally should only be gateway IPs)
    empty_subnet($class, $plugin_config, $subnetid, $subnet, $internalid, $noerr);

    eval {
	PVE::Network::SDN::api_request("DELETE", "$url/ipam/prefixes/$internalid/", $headers);
    };
    if ($@) {
	die "error deleting subnet in Nautobot: $@" if !$noerr;
    }
}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;

    my $mask = $subnet->{mask};
    my $url = $plugin_config->{url};
    my $namespace = $plugin_config->{namespace};
    my $headers = default_headers($plugin_config);

    my $description = undef;
    if ($is_gateway) {
	$description = 'gateway'
    } elsif ($mac) {
	$description = "mac:$mac";
    }

    my $params = { address => "$ip/$mask", type => "dhcp", dns_name => $hostname, description => $description, namespace => $namespace, status => default_ip_status()};

    eval {
	PVE::Network::SDN::api_request("POST", "$url/ipam/ip-addresses/", $headers, $params);
    };

    if ($@) {
	if($is_gateway) {
	    die "error adding subnet ip to ipam: ip $ip already exists: $@" if !$noerr && !is_ip_gateway($url, $ip, $headers, $noerr);
	} else {
	    die "error adding subnet ip to ipam: ip $ip already exists: $@" if !$noerr;
	}
    }
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $vmid, $noerr) = @_;

    my $cidr = $subnet->{cidr};

    my $url = $plugin_config->{url};
    my $namespace = $plugin_config->{namespace};
    my $headers = default_headers($plugin_config);

    my $internalid = get_prefix_id($url, $cidr, $headers, $noerr);
    die "cannot find prefix $cidr in Nautobot" if !$internalid;

    my $description = "mac:$mac" if $mac;

    my $params = { type => "dhcp", dns_name => $hostname, description => $description, namespace => $namespace, status => default_ip_status() };

    my $ip = eval {
	my $result = PVE::Network::SDN::api_request("POST", "$url/ipam/prefixes/$internalid/available-ips/", $headers, $params);
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

    my $url = $plugin_config->{url};
    my $namespace = $plugin_config->{namespace};
    my $headers = default_headers($plugin_config);
    my $cidr = $subnet->{cidr};

    # ranges are not supported natively in nautobot, hence why we have to get a little hacky.
    my $minimal_size = NetAddr::IP->new($range->{'start-address'}) - NetAddr::IP->new($cidr);
    my $internalid = get_prefix_id($url, $cidr, $headers, $noerr);

    my $ip = eval {
	my $result = PVE::Network::SDN::api_request("GET", "$url/ipam/prefixes/$internalid/available-ips/?limit=$minimal_size", $headers);
	# v important for NetAddr::IP comparison! (otherwise we would be comparing subnets)
	my @ips = map((split(/\//,$_->{address}))[0], @{$result});
	# get 1st result
	my $ip = (get_ips_within_range($range->{'start-address'}, $range->{'end-address'}, @ips))[0];

	if ($ip) {
	    print "found free ip $ip in range $range->{'start-address'}-$range->{'end-address'}\n"
	} else { die "prefix out of space in range"; }

	$class->add_ip($plugin_config, undef,  $subnet, $ip, $data->{hostname}, $data->{mac}, undef, 0, 0);
	return $ip;
    };

    if ($@) {
	die "can't find free ip in range $range->{'start-address'}-$range->{'end-address'}: $@" if !$noerr;
    }
    return $ip;
}


sub update_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;

    my $mask = $subnet->{mask};
    my $url = $plugin_config->{url};
    my $namespace = $plugin_config->{namespace};
    my $headers = default_headers($plugin_config);

    my $description = undef;
    if ($is_gateway) {
	$description = 'gateway'
    } elsif ($mac) {
	$description = "mac:$mac";
    }

    my $params = { address => "$ip/$mask", type => "dhcp", dns_name => $hostname, description => $description, namespace => $namespace, status => default_ip_status()};

    my $ip_id = get_ip_id($url, $ip, $headers, $noerr);
    die "can't find ip $ip in ipam" if !$noerr && !$ip_id;

    eval {
	PVE::Network::SDN::api_request("PATCH", "$url/ipam/ip-addresses/$ip_id/", $headers, $params);
    };
    if ($@) {
	die "error updating ip $ip: $@" if !$noerr;
    }
}


sub del_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $noerr) = @_;

    return if !$ip;

    my $url = $plugin_config->{url};
    my $headers = default_headers($plugin_config);

    my $ip_id = get_ip_id($url, $ip, $headers, $noerr);
    die "can't find ip $ip in ipam" if !$ip_id && !$noerr;

    eval {
	PVE::Network::SDN::api_request("DELETE", "$url/ipam/ip-addresses/$ip_id/", $headers);
    };
    if ($@) {
	die "error deleting ip $ip : $@" if !$noerr;
    }
}

sub empty_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $subnetuuid, $noerr) = @_;

    my $url = $plugin_config->{url};
    my $namespace = $plugin_config->{namespace};
    my $headers = default_headers($plugin_config);

    my $response = eval {
	return PVE::Network::SDN::api_request("GET", "$url/ipam/ip-addresses/?namespace=$namespace&parent=$subnetuuid", $headers)
    };
    if ($@) {
	die "error querying prefix $subnet: $@" if !$noerr;
    }

    for my $ip (@{$response->{results}}) {
	del_ip($class, $plugin_config, $subnetid, $subnet, $ip->{host}, $noerr);
    }
}

sub subnet_is_deletable {
    my ($class, $plugin_config, $subnetid, $subnet, $subnetuuid, $noerr) = @_;

    my $url = $plugin_config->{url};
    my $namespace = $plugin_config->{namespace};
    my $headers = default_headers($plugin_config);


    my $response = eval {
	return PVE::Network::SDN::api_request("GET", "$url/ipam/ip-addresses/?namespace=$namespace&parent=$subnetuuid", $headers)
    };
    if ($@) {
	die "error querying prefix $subnet: $@" if !$noerr;
    }
    my $n_ips = scalar $response->{results}->@*;

    # least costly check operation 1st
    if ($n_ips == 0) {
	# completely empty, delete ok
	return 1;
    } elsif (
	!(all {$_ == 1} (
	    map {
		is_ip_gateway($url, $_->{host}, $headers, $noerr)
	    } $response->{results}->@*
	))) {
	# some remaining IPs are not gateway, nok
	return 0;
    } else {
	# remaining IPs are all gateway, delete ok
	return 1;
    }
}

sub verify_api {
    my ($class, $plugin_config) = @_;

    my $url = $plugin_config->{url};
    my $namespace = $plugin_config->{namespace};
    my $headers = default_headers($plugin_config);

    # check that the namespace exists AND that default IP active status
    # exists AND that we have indeed API access
    eval {
	get_namespace_id($url, $namespace, $headers, 0) // die "namespace $namespace does not exist";
	get_status_id($url, default_ip_status(), $headers, 0) // die "default IP status ". default_ip_status() . " not found";
    };
    if ($@) {
	die "Can't use nautobot api: $@";
    }
}

sub get_ips_from_mac {
    my ($class, $plugin_config, $mac, $zoneid) = @_;

    my $url = $plugin_config->{url};
    my $namespace = $plugin_config->{namespace};
    my $headers = default_headers($plugin_config);

    my $ip4 = undef;
    my $ip6 = undef;

    my $data = PVE::Network::SDN::api_request("GET", "$url/ipam/ip-addresses/?q=$mac", $headers);
    for my $ip (@{$data->{results}}) {
	if ($ip->{ip_version} == 4 && !$ip4) {
	    ($ip4, undef) = split(/\//, $ip->{address});
	}

	if ($ip->{ip_version} == 6 && !$ip6) {
	    ($ip6, undef) = split(/\//, $ip->{address});
	}
    }

    return ($ip4, $ip6);
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;

    PVE::Network::SDN::Ipams::NautobotPlugin::verify_api($class, $plugin_config);
}

# helpers
sub get_ips_within_range {
    my ($start_address, $end_address, @list) = @_;
    $start_address = NetAddr::IP->new($start_address);
    $end_address = NetAddr::IP->new($end_address);
    return grep($start_address <= NetAddr::IP->new($_) <= $end_address, @list);
}

sub get_ip_id {
    my ($url, $ip, $headers, $noerr) = @_;

    my $result = eval {
	return PVE::Network::SDN::api_request("GET", "$url/ipam/ip-addresses/?q=$ip", $headers);
    };
    if ($@) {
	die "error while querying for ip $ip id: $@" if !$noerr;
    }

    my $data = @{$result->{results}}[0];
    my $ip_id = $data->{id};
    return $ip_id;
}

sub get_prefix_id {
    my ($url, $cidr, $headers, $noerr) = @_;

    my $result = eval {
	return PVE::Network::SDN::api_request("GET", "$url/ipam/prefixes/?q=$cidr", $headers);
    };
    if ($@) {
	die "error while querying for cidr $cidr prefix id: $@" if !$noerr;
    }

    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

sub get_namespace_id {
    my ($url, $namespace, $headers, $noerr) = @_;

    my $result = eval {
	return PVE::Network::SDN::api_request("GET", "$url/ipam/namespaces/?q=$namespace", $headers);
    };
    if ($@) {
	die "error while querying for namespace $namespace id: $@" if !$noerr;
    }

    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

sub get_status_id {
    my ($url, $status, $headers, $noerr) = @_;

    my $result = eval {
	return PVE::Network::SDN::api_request("GET", "$url/extras/statuses/?q=$status", $headers);
    };
    if ($@) {
	die "error while querying for status $status id: $@" if !$noerr;
    }

    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

sub is_ip_gateway {
    my ($url, $ip, $headers, $noerr) = @_;

    my $result = eval {
	return PVE::Network::SDN::api_request("GET", "$url/ipam/ip-addresses/?q=$ip", $headers);
    };
    if ($@) {
	die "error while checking if $ip is a gateway" if !$noerr;
    }

    my $data = @{$result->{results}}[0];
    my $description = $data->{description};
    my $is_gateway = 1 if $description eq 'gateway';
    return $is_gateway;
}

1;
