package PVE::Network::SDN::Ipams::NautobotPlugin;

use strict;
use warnings;
use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;
use NetAddr::IP;

use base('PVE::Network::SDN::Ipams::NetboxPlugin');

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

    my $internalid = PVE::Network::SDN::Ipams::NetboxPlugin::get_prefix_id($url, $cidr, $headers);

    #create subnet
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
	    die "error adding subnet ip to ipam: ip $ip already exists: $@" if !PVE::Network::SDN::Ipams::NetboxPlugin::is_ip_gateway($url, $ip, $headers) && !$noerr;
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

    my $internalid = PVE::Network::SDN::Ipams::NetboxPlugin::get_prefix_id($url, $cidr, $headers);

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
    my $internalid = PVE::Network::SDN::Ipams::NetboxPlugin::get_prefix_id($url, $cidr, $headers);

    my $ip = eval {
	my $result = PVE::Network::SDN::api_request("GET", "$url/ipam/prefixes/$internalid/available-ips/?limit=$minimal_size", $headers);
	# v important for NetAddr::IP comparison!
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

    my $ip_id = PVE::Network::SDN::Ipams::NetboxPlugin::get_ip_id($url, $ip, $headers);
    die "can't find ip $ip in ipam" if !$ip_id;

    eval {
	PVE::Network::SDN::api_request("PATCH", "$url/ipam/ip-addresses/$ip_id/", $headers, $params);
    };
    if ($@) {
	die "error updating ip $ip: $@" if !$noerr;
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
	get_namespace_id($url, $namespace, $headers) // die "namespace $namespace does not exist";
	get_status_id($url, default_ip_status(), $headers) // die "default IP status ". default_ip_status() . " not found";
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

sub get_namespace_id {
    my ($url, $namespace, $headers) = @_;

    my $result = PVE::Network::SDN::api_request("GET", "$url/ipam/namespaces/?q=$namespace", $headers);
    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

sub get_status_id {
    my ($url, $status, $headers) = @_;

    my $result = PVE::Network::SDN::api_request("GET", "$url/extras/statuses/?q=$status", $headers);
    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

1;
