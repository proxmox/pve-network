package PVE::Network::SDN::Dns::PowerdnsPlugin;

use strict;
use warnings;

use JSON;
use Net::IP;
use NetAddr::IP qw(:lower);

use PVE::Cluster;
use PVE::INotify;
use PVE::Tools;

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
	reversemaskv6 => {
	    type => 'integer'
	},
    };
}

sub options {
    return {
	url => { optional => 0},
	key => { optional => 0 },
	ttl => { optional => 1 },
	reversemaskv6 => {
	    optional => 1,
	    description => "force a different netmask for the ipv6 reverse zone name.",
	},
	fingerprint => { optional => 1 },
    };
}

my sub powerdns_api_request {
    my ($config, $method, $path, $params) = @_;

    return PVE::Network::SDN::api_request(
	$method,
	"$config->{url}${path}",
	['Content-Type' => 'application/json; charset=UTF-8', 'X-API-Key' => $config->{key}],
	$params,
	$config->{fingerprint},
    );
}

# Plugin implementation

sub add_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;

    my $ttl = $plugin_config->{ttl} ? $plugin_config->{ttl} : 14400;
    my $type = Net::IP::ip_is_ipv6($ip) ? "AAAA" : "A";
    my $fqdn = $hostname.".".$zone.".";

    my $zonecontent = get_zone_content($plugin_config, $zone);
    my $existing_rrset = get_zone_rrset($zonecontent, $fqdn, $type);

    my $final_records = [];
    for my $record (@{$existing_rrset->{records}}) {
	if ($record->{content} eq $ip) {
	    return; # the record already exist so return early
	}
	push @$final_records, $record;
    }

    my $record = {
	content => $ip,
	disabled => JSON::false,
	name => $fqdn,
	type => $type,
    };
    push @$final_records, $record;

    my $params = {
	rrsets => [{
	    name => $fqdn,
	    type => $type,
	    ttl =>  $ttl,
	    changetype => "REPLACE",
	    records => $final_records,
	}],
    };

    eval { powerdns_api_request($plugin_config, 'PATCH', "/zones/$zone", $params) };
    die "error add $fqdn to zone $zone: $@" if $@ && !$noerr;
}

sub add_ptr_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;

    my $ttl = $plugin_config->{ttl} ? $plugin_config->{ttl} : 14400;
    $hostname .= ".";

    my $reverseip = Net::IP->new($ip)->reverse_ip();

    my $type = "PTR";

    my $record = {
	content => $hostname,
	disabled => JSON::false,
	name => $reverseip,
	type => $type,
    };

    my $params = {
	rrsets => [{
	    name => $reverseip,
	    type => $type,
	    ttl =>  $ttl,
	    changetype => "REPLACE",
	    records => [ $record ],
	}],
    };

    eval { powerdns_api_request($plugin_config, 'PATCH', "/zones/$zone", $params) };
    die "error add $reverseip to zone $zone: $@" if $@ && !$noerr;
}

sub del_a_record {
    my ($class, $plugin_config, $zone, $hostname, $ip, $noerr) = @_;

    my $fqdn = $hostname.".".$zone.".";
    my $type = Net::IP::ip_is_ipv6($ip) ? "AAAA" : "A";

    my $zonecontent = get_zone_content($plugin_config, $zone);
    my $existing_rrset = get_zone_rrset($zonecontent, $fqdn, $type);

    my $final_records = [ grep { $_->{content} ne $ip } $existing_rrset->{records}->@* ];
    my $final_records_size = scalar($final_records->@*);
    # early return if we didn't find our record (i.e., un/filtered record sets have the same size)
    return if scalar($existing_rrset->{records}->@*) == $final_records_size;

    my $rrset = {
	name => $fqdn,
	type => $type,
    };

    if ($final_records_size > 0) {
	# if we still have other records, we rewrite them with the $ip removed
	$rrset->{ttl} = $existing_rrset->{ttl};
	$rrset->{changetype} = "REPLACE";
	$rrset->{records} = $final_records;
    } else {
	$rrset->{changetype} = "DELETE";
	$rrset->{records} = [];
    }

    my $params = { rrsets => [ $rrset ] };

    eval { powerdns_api_request($plugin_config, 'PATCH', "/zones/$zone", $params) };
    die "error delete $fqdn from zone $zone: $@" if $@ && !$noerr;
}

sub del_ptr_record {
    my ($class, $plugin_config, $zone, $ip, $noerr) = @_;

    my $reverseip = Net::IP->new($ip)->reverse_ip();

    my $type = "PTR";

    my $params = {
	rrsets => [{
	    name => $reverseip,
	    type => $type,
	    changetype => "DELETE",
	    records => [],
	}],
    };

    eval { powerdns_api_request($plugin_config, 'PATCH', "/zones/$zone", $params) };
    die "error delete $reverseip from zone $zone: $@" if $@ && !$noerr;
}

sub verify_zone {
    my ($class, $plugin_config, $zone, $noerr) = @_;

    # verify that zone exists
    eval { powerdns_api_request($plugin_config, 'GET', "/zones/$zone?rrsets=false") };
    die "can't read zone $zone: $@" if $@ && !$noerr;
}

sub get_reversedns_zone {
    my ($class, $plugin_config, $subnetid, $subnet, $ip) = @_;

    my $cidr = $subnet->{cidr};
    my $mask = $subnet->{mask};

    my $zone = "";

    if (Net::IP::ip_is_ipv4($ip)) {
	my ($ipblock1, $ipblock2, $ipblock3, $ipblock4) = split(/\./, $ip);

        my $ipv4 = NetAddr::IP->new($cidr);
	#private addresse #powerdns built-in private zone : serve-rfc1918
	if($ipv4->is_rfc1918()) {
	    if ($ipblock1 == 192) {
		$zone = "168.192.in-addr.arpa.";
	    } elsif ($ipblock1 == 172) {
		$zone = "16-31.172.in-addr.arpa.";
	    } elsif ($ipblock1 == 10) {
		$zone = "10.in-addr.arpa.";
	    }

	} else {
	    # public ipv4 : RIPE,ARIN,AFRNIC
	    # Delegations can be managed in IPv4 on bit boundaries (/8, /16 or /24s), and IPv6
	    # networks can be managed on nibble boundaries (every 4 bits of the IPv6 address)
	    # One or more /24 type zones need to be created if your address space has a prefix
	    # length between /17 and /24.
	    # If your prefix length is between /16 and /9 you will have to request one or more
	    # delegations for /16 type zones.

	    if ($mask <= 24) {
		$zone = "$ipblock3.$ipblock2.$ipblock1.in-addr.arpa.";
	    } elsif ($mask <= 16) {
		$zone = "$ipblock2.$ipblock1.in-addr.arpa.";
	    } elsif ($mask <= 8) {
		$zone = "$ipblock1.in-addr.arpa.";
	    }
	}
    } else {
	$mask = $plugin_config->{reversemaskv6} if $plugin_config->{reversemaskv6};
	die "reverse dns zone mask need to be a multiple of 4" if ($mask % 4);
	my $networkv6 = NetAddr::IP->new($cidr)->network();
	$zone = Net::IP->new($networkv6)->reverse_ip();
    }

    return $zone;
}


sub on_update_hook {
    my ($class, $plugin_config) = @_;

    # verify that api is working
    eval { powerdns_api_request($plugin_config, 'GET', '') };
    die "dns api error: $@" if $@;
}


sub get_zone_content {
    my ($plugin_config, $zone) = @_;

    # verify that api is working
    my $result = eval { powerdns_api_request($plugin_config, 'GET', "/zones/$zone") };
    die "can't read zone $zone: $@" if $@;

    return $result;
}

sub get_zone_rrset {
    my ($zonecontent, $name, $type) = @_;

    for my $rrset (@{$zonecontent->{rrsets}}) {
	return $rrset if $rrset->{name} eq $name and ($rrset->{type} eq $type);
    }
    return; # not found
}

1;


