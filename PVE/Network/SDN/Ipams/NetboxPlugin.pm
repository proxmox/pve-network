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
    my ($class, $plugin_config, $subnetid, $subnet) = @_;

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
		my $result = PVE::Network::SDN::Ipams::Plugin::api_request("POST", "$url/ipam/prefixes/", $headers, $params);
	};
	if ($@) {
	    die "error add subnet to ipam: $@";
	}
    }
   
}

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet) = @_;

    my $cidr = $subnet->{cidr};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $gateway = $subnet->{gateway};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $internalid = get_prefix_id($url, $cidr, $headers);
    return if !$internalid;

    return; #fixme: check that prefix is empty exluding gateway, before delete

    eval {
	PVE::Network::SDN::Ipams::Plugin::api_request("DELETE", "$url/ipam/prefixes/$internalid/", $headers);
    };
    if ($@) {
	die "error deleting subnet from ipam: $@";
    }

}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description, $is_gateway) = @_;

    my $mask = $subnet->{mask};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $section = $plugin_config->{section};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];
    $description .= " mac:$mac" if $mac && $description;

    my $params = { address => "$ip/$mask", dns_name => $hostname, description => $description };

    eval {
	PVE::Network::SDN::Ipams::Plugin::api_request("POST", "$url/ipam/ip-addresses/", $headers, $params);
    };

    if ($@) {
	die "error add subnet ip to ipam: ip already exist: $@";
    }
}

sub update_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description, $is_gateway) = @_;

    my $mask = $subnet->{mask};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $section = $plugin_config->{section};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];
    $description .= " mac:$mac" if $mac && $description;

    my $params = { address => "$ip/$mask", dns_name => $hostname, description => $description };

    my $ip_id = get_ip_id($url, $ip, $headers);
    die "can't find ip $ip in ipam" if !$ip_id;

    eval {
	PVE::Network::SDN::Ipams::Plugin::api_request("PATCH", "$url/ipam/ip-addresses/$ip_id/", $headers, $params);
    };
    if ($@) {
	die "error update ip $ip : $@";
    }
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $description) = @_;

    my $cidr = $subnet->{cidr};

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $internalid = get_prefix_id($url, $cidr, $headers);
    $description .= " mac:$mac" if $mac && $description;

    my $params = { dns_name => $hostname, description => $description };

    my $ip = undef;
    eval {
	my $result = PVE::Network::SDN::Ipams::Plugin::api_request("POST", "$url/ipam/prefixes/$internalid/available-ips/", $headers, $params);
	$ip = $result->{address};
    };

    if ($@) {
	die "can't find free ip in subnet $cidr: $@";
    }

    return $ip;
}

sub del_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip) = @_;

    return if !$ip;

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];

    my $ip_id = get_ip_id($url, $ip, $headers);
    die "can't find ip $ip in ipam" if !$ip_id;

    eval {
	PVE::Network::SDN::Ipams::Plugin::api_request("DELETE", "$url/ipam/ip-addresses/$ip_id/", $headers);
    };
    if ($@) {
	die "error delete ip $ip : $@";
    }
}

sub verify_api {
    my ($class, $plugin_config) = @_;

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Authorization' => "token $token"];


    eval {
	PVE::Network::SDN::Ipams::Plugin::api_request("GET", "$url/ipam/aggregates/", $headers);
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

    my $result = PVE::Network::SDN::Ipams::Plugin::api_request("GET", "$url/ipam/prefixes/?q=$cidr", $headers);
    my $data = @{$result->{results}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

sub get_ip_id {
    my ($url, $ip, $headers) = @_;
    my $result = PVE::Network::SDN::Ipams::Plugin::api_request("GET", "$url/ipam/ip-addresses/?q=$ip", $headers);
    my $data = @{$result->{results}}[0];
    my $ip_id = $data->{id};
    return $ip_id;
}


1;


