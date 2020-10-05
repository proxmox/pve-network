package PVE::Network::SDN::Dns::PowerdnsPlugin;

use strict;
use warnings;
use PVE::INotify;
use PVE::Cluster;
use PVE::Tools;
use JSON;
use Net::IP;

use base('PVE::Network::SDN::Dns::Plugin');

sub type {
    return 'powerdns';
}

sub properties {
    return {
	url => {
	    type => 'string',
	},
	key => {
	    type => 'string',
	},
    };
}

sub options {

    return {
        url => { optional => 0},
        key => { optional => 0 },
        ttl => { optional => 1 },
    };
}

# Plugin implementation

sub add_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip) = @_;

    my $url = $plugin_config->{url};
    my $key = $plugin_config->{key};
    my $ttl = $plugin_config->{ttl} ? $plugin_config->{ttl} : 14400;
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'X-API-Key' => $key];

    my $type = Net::IP::ip_is_ipv6($ip) ? "AAAA" : "A";
    my $fqdn = $hostname.".".$zone.".";


    my $record = { content => $ip, 
                   disabled => JSON::false, 
		   name => $fqdn, 
                   type => $type, 
                   priority => 0 };

    my $rrset = { name => $fqdn, 
		  type => $type, 
                   ttl =>  $ttl, 
		  changetype => "REPLACE",
		  records => [ $record ] };


    my $params = { rrsets => [ $rrset ] };

    eval {
	PVE::Network::SDN::Dns::Plugin::api_request("PATCH", "$url/zones/$zone", $headers, $params);
    };

    if ($@) {
	die "error add $fqdn to zone $zone: $@";
    }
}

sub add_ptr_record {
    my ($class, $plugin_config, $zone, $hostname, $ip) = @_;

    my $url = $plugin_config->{url};
    my $key = $plugin_config->{key};
    my $ttl = $plugin_config->{ttl} ? $plugin_config->{ttl} : 14400;
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'X-API-Key' => $key];
    $hostname .= ".";

    my $reverseip = join(".", reverse(split(/\./, $ip))).".in-addr.arpa.";
    my $type = "PTR";

    my $record = { content => $hostname, 
                   disabled => JSON::false, 
		   name => $reverseip, 
                   type => $type, 
                   priority => 0 };

    my $rrset = { name => $reverseip, 
		  type => $type, 
                   ttl =>  $ttl, 
		  changetype => "REPLACE",
		  records => [ $record ] };


    my $params = { rrsets => [ $rrset ] };

    eval {
	PVE::Network::SDN::Dns::Plugin::api_request("PATCH", "$url/zones/$zone", $headers, $params);
    };

    if ($@) {
	die "error add $reverseip to zone $zone: $@";
    }
}

sub del_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip) = @_;

    my $url = $plugin_config->{url};
    my $key = $plugin_config->{key};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'X-API-Key' => $key];
    my $fqdn = $hostname.".".$zone.".";
    my $type = Net::IP::ip_is_ipv6($ip) ? "AAAA" : "A";

    my $rrset = { name => $fqdn, 
		  type => $type, 
		  changetype => "DELETE",
		  records => [] };

    my $params = { rrsets => [ $rrset ] };

    eval {
	PVE::Network::SDN::Dns::Plugin::api_request("PATCH", "$url/zones/$zone", $headers, $params);
    };

    if ($@) {
	die "error delete $fqdn from zone $zone: $@";
    }
}

sub del_ptr_record {
    my ($class, $plugin_config, $zone, $ip) = @_;

    my $url = $plugin_config->{url};
    my $key = $plugin_config->{key};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'X-API-Key' => $key];

    my $reverseip = join(".", reverse(split(/\./, $ip))).".in-addr.arpa.";
    my $type = "PTR";

    my $rrset = { name => $reverseip, 
		  type => $type, 
		  changetype => "DELETE",
		  records => [] };

    my $params = { rrsets => [ $rrset ] };

    eval {
	PVE::Network::SDN::Dns::Plugin::api_request("PATCH", "$url/zones/$zone", $headers, $params);
    };

    if ($@) {
	die "error delete $reverseip from zone $zone: $@";
    }
}

sub verify_zone {
    my ($class, $plugin_config, $zone) = @_;

    #verify that api is working              

    my $url = $plugin_config->{url};
    my $key = $plugin_config->{key};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'X-API-Key' => $key];

    eval {
        PVE::Network::SDN::Dns::Plugin::api_request("GET", "$url/zones/$zone", $headers);
    };

    if ($@) {
        die "can't read zone $zone: $@";
    }
}


sub on_update_hook {
    my ($class, $plugin_config) = @_;

    #verify that api is working

    my $url = $plugin_config->{url};
    my $key = $plugin_config->{key};
    my $headers = ['Content-Type' => 'application/json; charset=UTF-8', 'X-API-Key' => $key];

    eval {
	PVE::Network::SDN::Dns::Plugin::api_request("GET", "$url", $headers);
    };

    if ($@) {
	die "dns api error: $@";
    }
}

1;


