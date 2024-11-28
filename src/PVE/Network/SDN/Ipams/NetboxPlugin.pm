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
    };
}

# Plugin implementation

sub add_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $gateway = $subnet->{gateway};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $internalid = get_prefix_id($url, $cidr, $headers);

    #create subnet
    if (!$internalid) {

	my $params = { prefix => $cidr };

	eval {
		my $result = PVE::Network::SDN::api_request("POST", "$url/ipam/prefixes/", $headers, $params);
	};
	if ($@) {
	    die "error add subnet to ipam: $@" if !$noerr;
	}
    }
   
}

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $gateway = $subnet->{gateway};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $internalid = get_prefix_id($url, $cidr, $headers);
    return if !$internalid;

    return; #fixme: check that prefix is empty exluding gateway, before delete

    eval {
	PVE::Network::SDN::api_request("DELETE", "$url/ipam/prefixes/$internalid/", $headers);
    };
    if ($@) {
	die "error deleting subnet from ipam: $@" if !$noerr;
    }

}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;

    my $mask = $subnet->{mask};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $section = $plugin_config->{section};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $description = undef;
    if ($is_gateway) {
	$description = 'gateway'
    } elsif ($mac) {
	$description = "mac:$mac";
    }

    my $params = { address => "$ip/$mask", dns_name => $hostname, description => $description };

    eval {
	PVE::Network::SDN::api_request("POST", "$url/ipam/ip-addresses/", $headers, $params);
    };

    if ($@) {
        if($is_gateway) {
           die "error add subnet ip to ipam: ip $ip already exist: $@" if !is_ip_gateway($url, $ip, $headers) && !$noerr;
        } else {
	    die "error add subnet ip to ipam: ip already exist: $@" if !$noerr;
	}
    }
}

sub update_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;

    my $mask = $subnet->{mask};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $section = $plugin_config->{section};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $description = undef;
    if ($is_gateway) {
	$description = 'gateway'
    } elsif ($mac) {
	$description = "mac:$mac";
    }

    my $params = { address => "$ip/$mask", dns_name => $hostname, description => $description };

    my $ip_id = get_ip_id($url, $ip, $headers);
    die "can't find ip $ip in ipam" if !$ip_id;

    eval {
	PVE::Network::SDN::api_request("PATCH", "$url/ipam/ip-addresses/$ip_id/", $headers, $params);
    };
    if ($@) {
	die "error update ip $ip : $@" if !$noerr;
    }
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $vmid, $noerr) = @_;

    my $cidr = $subnet->{cidr};

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $internalid = get_prefix_id($url, $cidr, $headers);

    my $description = "mac:$mac" if $mac;

    my $params = { dns_name => $hostname, description => $description };

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
    my $token = $plugin_config->{token};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $internalid = get_iprange_id($url, $range, $headers);
    my $description = "mac:$data->{mac}" if $data->{mac};

    my $params = { dns_name => $data->{hostname}, description => $description };

    my $ip = eval {
	my $result = PVE::Network::SDN::api_request("POST", "$url/ipam/ip-ranges/$internalid/available-ips/", $headers, $params);
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

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $ip_id = get_ip_id($url, $ip, $headers);
    die "can't find ip $ip in ipam" if !$ip_id;

    eval {
	PVE::Network::SDN::api_request("DELETE", "$url/ipam/ip-addresses/$ip_id/", $headers);
    };
    if ($@) {
	die "error delete ip $ip : $@" if !$noerr;
    }
}

sub get_ips_from_mac {
    my ($class, $plugin_config, $mac, $zoneid) = @_;

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $ip4 = undef;
    my $ip6 = undef;

    my $data = PVE::Network::SDN::api_request("GET", "$url/ipam/ip-addresses/?description__ic=$mac", $headers);
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

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];


    eval {
	PVE::Network::SDN::api_request("GET", "$url/ipam/aggregates/", $headers);
    };
    if ($@) {
	die "Can't connect to netbox api: $@";
    }
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;

    PVE::Network::SDN::Ipams::NetboxPlugin::verify_api($class, $plugin_config);
}

#helpers

sub get_prefix_id {
    my ($url, $cidr, $headers) = @_;

    my $result = PVE::Network::SDN::api_request("GET", "$url/ipam/prefixes/?q=$cidr", $headers);
    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

sub get_iprange_id {
    my ($url, $range, $headers) = @_;

    my $result = PVE::Network::SDN::api_request("GET", "$url/ipam/ip-ranges/?start_address=$range->{'start-address'}&end_address=$range->{'end-address'}", $headers);
    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

sub get_ip_id {
    my ($url, $ip, $headers) = @_;
    my $result = PVE::Network::SDN::api_request("GET", "$url/ipam/ip-addresses/?q=$ip", $headers);
    my $data = @{$result->{results}}[0];
    my $ip_id = $data->{id};
    return $ip_id;
}

sub is_ip_gateway {
    my ($url, $ip, $headers) = @_;
    my $result = PVE::Network::SDN::api_request("GET", "$url/ipam/ip-addresses/?q=$ip", $headers);
    my $data = @{$result->{data}}[0];
    my $description = $data->{description};
    my $is_gateway = 1 if $description eq 'gateway';
    return $is_gateway;
}

1;


