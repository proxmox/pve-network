package PVE::Network::SDN::Ipams::PhpIpamPlugin;

use strict;
use warnings;
use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;

use base('PVE::Network::SDN::Ipams::Plugin');

sub type {
    return 'phpipam';
}

sub properties {
    return {
	url => {
	    type => 'string',
	},
	token => {
	    type => 'string',
	},
	section => {
	    type => 'integer',
	},
    };
}

sub options {

    return {
        url => { optional => 0},
        token => { optional => 0 },
        section => { optional => 0 },
        fingerprint => { optional => 1 },
    };
}

# Plugin implementation

sub add_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $network = $subnet->{network};
    my $mask = $subnet->{mask};

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $section = $plugin_config->{section};
    my $fingerprint = $plugin_config->{fingerprint};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Token' => $token];

    #search subnet
    my $internalid = eval { get_prefix_id($url, $cidr, $headers) };

    #create subnet
    if (!$internalid) {
	my $params = {
	    subnet => $network,
	    mask => $mask,
	    sectionId => $section,
	};

	eval { PVE::Network::SDN::api_request("POST", "$url/subnets/", $headers, $params, $fingerprint) };
	die "error add subnet to ipam: $@" if $@ && !$noerr;
    }
}

sub update_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $old_subnet, $noerr) = @_;
    # we don't need to do anything on update
}

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $fingerprint = $plugin_config->{fingerprint};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Token' => $token];

    my $internalid = get_prefix_id($url, $cidr, $headers);
    return if !$internalid;

    return; #fixme: check that prefix is empty exluding gateway, before delete

    eval { PVE::Network::SDN::api_request("DELETE", "$url/subnets/$internalid", $headers, undef, $fingerprint) };
    die "error deleting subnet from ipam: $@" if $@ && !$noerr;
}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description, $is_gateway, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $fingerprint = $plugin_config->{fingerprint};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Token' => $token];

    my $internalid = get_prefix_id($url, $cidr, $headers);

    my $params = {
	ip => $ip,
	subnetId => $internalid,
	hostname => $hostname,
	description => $description,
    };
    $params->{is_gateway} = 1 if $is_gateway;
    $params->{mac} = $mac if $mac;

    eval {
	PVE::Network::SDN::api_request("POST", "$url/addresses/", $headers, $params, $fingerprint);
    };

    if ($@) {
	if($is_gateway) {
	    die "error add subnet ip to ipam: ip $ip already exist: $@" if !is_ip_gateway($url, $ip, $headers) && !$noerr;
	} else {
	    die "error add subnet ip to ipam: ip $ip already exist: $@" if !$noerr;
	}
    }
}

sub update_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description, $is_gateway, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $fingerprint = $plugin_config->{fingerprint};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Token' => $token];

    my $ip_id = get_ip_id($url, $ip, $headers);
    die "can't find ip addresse in ipam" if !$ip_id;

    my $params = {
	hostname => $hostname,
	description => $description,
    };
    $params->{is_gateway} = 1 if $is_gateway;
    $params->{mac} = $mac if $mac;

    eval {
	PVE::Network::SDN::api_request("PATCH", "$url/addresses/$ip_id", $headers, $params,$fingerprint);
    };

    if ($@) {
	die "ipam: error update subnet ip $ip: $@" if !$noerr;
    }
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $description, $noerr) = @_;

    my $cidr = $subnet->{cidr};
    my $mask = $subnet->{mask};
    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $fingerprint = $plugin_config->{fingerprint};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Token' => $token];

    my $internalid = get_prefix_id($url, $cidr, $headers);

    my $params = {
	hostname => $hostname,
	description => $description,
    };

    $params->{mac} = $mac if $mac;

    my $ip = undef;
    eval {
	my $result = PVE::Network::SDN::api_request("POST", "$url/addresses/first_free/$internalid/", $headers, $params, $fingerprint);
	$ip = $result->{data};
    };

    if ($@) {
        die "can't find free ip in subnet $cidr: $@" if !$noerr;
    }

    return $ip;
}

sub add_range_next_freeip {
    my ($class, $plugin_config, $subnet, $range, $data, $noerr) = @_;

    #not implemented in phpipam, we search in the full subnet

    my $vmid = $data->{vmid};
    my $mac = $data->{mac};
    my $hostname = $data->{hostname};

    return $class->add_next_freeip($plugin_config, undef, $subnet, $hostname, $mac, $vmid);
}

sub del_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $noerr) = @_;

    return if !$ip;

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $fingerprint = $plugin_config->{fingerprint};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Token' => $token];

    my $ip_id = get_ip_id($url, $ip, $headers);
    return if !$ip_id;

    eval {
	PVE::Network::SDN::api_request("DELETE", "$url/addresses/$ip_id", $headers, undef, $fingerprint);
    };
    if ($@) {
	die "error delete ip $ip: $@" if !$noerr;
    }
}

sub get_ips_from_mac {
    my ($class, $plugin_config, $mac, $zoneid) = @_;


    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $fingerprint = $plugin_config->{fingerprint};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Token' => $token];

    my $ip4 = undef;
    my $ip6 = undef;

    my $ips = eval { PVE::Network::SDN::api_request("GET", "$url/addresses/search_mac/$mac", $headers, undef, $fingerprint) };
    return if $@;

    #fixme
    die "parsing of result not yet implemented";

    for my $ip (@$ips) {
#        if ($ip->{family}->{value} == 4 && !$ip4) {
#            ($ip4, undef) = split(/\//, $ip->{address});
#        }
#
#        if ($ip->{family}->{value} == 6 && !$ip6) {
#            ($ip6, undef) = split(/\//, $ip->{address});
#        }
    }

    return ($ip4, $ip6);
}

sub verify_api {
    my ($class, $plugin_config) = @_;

    my $url = $plugin_config->{url};
    my $token = $plugin_config->{token};
    my $sectionid = $plugin_config->{section};
    my $fingerprint = $plugin_config->{fingerprint};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'Token' => $token];

    eval {
	PVE::Network::SDN::api_request("GET", "$url/sections/$sectionid", $headers, undef, $fingerprint);
    };
    if ($@) {
	die "Can't connect to phpipam api: $@";
    }
}

sub on_update_hook {
    my ($class, $plugin_config) = @_;

    PVE::Network::SDN::Ipams::PhpIpamPlugin::verify_api($class, $plugin_config);
}


#helpers

sub get_prefix_id {
    my ($url, $cidr, $headers) = @_;

    my $result = PVE::Network::SDN::api_request("GET", "$url/subnets/cidr/$cidr", $headers);
    my $data = @{$result->{data}}[0];
    my $internalid = $data->{id};
    return $internalid;
}

sub get_ip_id {
    my ($url, $ip, $headers) = @_;
    my $result = PVE::Network::SDN::api_request("GET", "$url/addresses/search/$ip", $headers);
    my $data = @{$result->{data}}[0];
    my $ip_id = $data->{id};
    return $ip_id;
}

sub is_ip_gateway {
    my ($url, $ip, $headers) = @_;
    my $result = PVE::Network::SDN::api_request("GET", "$url/addresses/search/$ip", $headers);
    my $data = @{$result->{data}}[0];
    my $is_gateway = $data->{is_gateway};
    return $is_gateway;
}

1;


