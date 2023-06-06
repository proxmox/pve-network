package PVE::Network::SDN;

use strict;
use warnings;

use Data::Dumper;
use JSON;

use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones;
use PVE::Network::SDN::Controllers;
use PVE::Network::SDN::Subnets;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);


my $running_cfg = "sdn/.running-config";

my $parse_running_cfg = sub {
    my ($filename, $raw) = @_;

    my $cfg = {};

    return $cfg if !defined($raw) || $raw eq '';

    eval {
	$cfg = from_json($raw);
    };
    return {} if $@;

    return $cfg;
};

my $write_running_cfg = sub {
    my ($filename, $cfg) = @_;

    my $json = to_json($cfg);

    return $json;
};

PVE::Cluster::cfs_register_file($running_cfg, $parse_running_cfg, $write_running_cfg);


# improve me : move status code inside plugins ?

sub ifquery_check {

    my $cmd = ['ifquery', '-a', '-c', '-o','json'];

    my $result = '';
    my $reader = sub { $result .= shift };

    eval {
	run_command($cmd, outfunc => $reader);
    };

    my $resultjson = decode_json($result);
    my $interfaces = {};

    foreach my $interface (@$resultjson) {
	my $name = $interface->{name};
	$interfaces->{$name} = {
	    status => $interface->{status},
	    config => $interface->{config},
	    config_status => $interface->{config_status},
	};
    }

    return $interfaces;
}

sub status {

    my ($zone_status, $vnet_status) = PVE::Network::SDN::Zones::status();
    return($zone_status, $vnet_status);
}

sub running_config {
    return cfs_read_file($running_cfg);
}

sub pending_config {
    my ($running_cfg, $cfg, $type) = @_;

    my $pending = {};

    my $running_objects = $running_cfg->{$type}->{ids};
    my $config_objects = $cfg->{ids};

    foreach my $id (sort keys %{$running_objects}) {
	my $running_object = $running_objects->{$id};
	my $config_object = $config_objects->{$id};
	foreach my $key (sort keys %{$running_object}) {
	    $pending->{$id}->{$key} = $running_object->{$key};
	    if(!keys %{$config_object}) {
		$pending->{$id}->{state} = "deleted";
	    } elsif (!defined($config_object->{$key})) {
		$pending->{$id}->{"pending"}->{$key} = 'deleted';
		$pending->{$id}->{state} = "changed";
	    } elsif (PVE::Network::SDN::encode_value(undef, $key, $running_object->{$key})
			 ne PVE::Network::SDN::encode_value(undef, $key, $config_object->{$key})) {
		$pending->{$id}->{state} = "changed";
	    }
	}
	$pending->{$id}->{"pending"} = {} if $pending->{$id}->{state} && !defined($pending->{$id}->{"pending"});
    }

   foreach my $id (sort keys %{$config_objects}) {
	my $running_object = $running_objects->{$id};
	my $config_object = $config_objects->{$id};

	foreach my $key (sort keys %{$config_object}) {
	    my $config_value = PVE::Network::SDN::encode_value(undef, $key, $config_object->{$key}) if $config_object->{$key};
	    my $running_value = PVE::Network::SDN::encode_value(undef, $key, $running_object->{$key}) if $running_object->{$key};
	    if($key eq 'type' || $key eq 'vnet') {
		$pending->{$id}->{$key} = $config_value;
	    } else {
		$pending->{$id}->{"pending"}->{$key} = $config_value if !defined($running_value) || ($config_value ne $running_value);
	    }
	    if(!keys %{$running_object}) {
		$pending->{$id}->{state} = "new";
	    } elsif (!defined($running_value) && defined($config_value)) {
		$pending->{$id}->{state} = "changed";
	    }
	}
	$pending->{$id}->{"pending"} = {} if  $pending->{$id}->{state} && !defined($pending->{$id}->{"pending"});
   }

   return {ids => $pending};

}

sub commit_config {

    my $cfg = cfs_read_file($running_cfg);
    my $version = $cfg->{version};

    if ($version) {
	$version++;
    } else {
	$version = 1;
    }

    my $vnets_cfg = PVE::Network::SDN::Vnets::config();
    my $zones_cfg = PVE::Network::SDN::Zones::config();
    my $controllers_cfg = PVE::Network::SDN::Controllers::config();
    my $subnets_cfg = PVE::Network::SDN::Subnets::config();

    my $vnets = { ids => $vnets_cfg->{ids} };
    my $zones = { ids => $zones_cfg->{ids} };
    my $controllers = { ids => $controllers_cfg->{ids} };
    my $subnets = { ids => $subnets_cfg->{ids} };

     $cfg = { version => $version, vnets => $vnets, zones => $zones, controllers => $controllers, subnets => $subnets };

    cfs_write_file($running_cfg, $cfg);
}

sub lock_sdn_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file($running_cfg, undef, $code);

    if (my $err = $@) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub get_local_vnets {

    my $rpcenv = PVE::RPCEnvironment::get();

    my $authuser = $rpcenv->get_user();

    my $nodename = PVE::INotify::nodename();

    my $cfg = PVE::Network::SDN::running_config();
    my $vnets_cfg = $cfg->{vnets};
    my $zones_cfg = $cfg->{zones};

    my @vnetids = PVE::Network::SDN::Vnets::sdn_vnets_ids($vnets_cfg);

    my $vnets = {};

    foreach my $vnetid (@vnetids) {

	my $vnet = PVE::Network::SDN::Vnets::sdn_vnets_config($vnets_cfg, $vnetid);
	my $zoneid = $vnet->{zone};
	my $comments = $vnet->{alias};

	my $privs = [ 'SDN.Audit', 'SDN.Use' ];

	next if !$zoneid;
	next if !$rpcenv->check_sdn_bridge($authuser, $zoneid, $vnetid, $privs, 1);

	my $zone_config = PVE::Network::SDN::Zones::sdn_zones_config($zones_cfg, $zoneid);

	next if defined($zone_config->{nodes}) && !$zone_config->{nodes}->{$nodename};
	my $ipam = $zone_config->{ipam} ? 1 : 0;
	my $vlanaware = $vnet->{vlanaware} ? 1 : 0;
	$vnets->{$vnetid} = { type => 'vnet', active => '1', ipam => $ipam, vlanaware => $vlanaware, comments => $comments };
    }

    return $vnets;
}

sub generate_zone_config {
    my $raw_config = PVE::Network::SDN::Zones::generate_etc_network_config();
    PVE::Network::SDN::Zones::write_etc_network_config($raw_config);
}

sub generate_controller_config {
    my ($reload) = @_;

    my $raw_config = PVE::Network::SDN::Controllers::generate_controller_config();
    PVE::Network::SDN::Controllers::write_controller_config($raw_config);

    PVE::Network::SDN::Controllers::reload_controller() if $reload;
}

sub encode_value {
    my ($type, $key, $value) = @_;

    if ($key eq 'nodes' || $key eq 'exitnodes') {
        if(ref($value) eq 'HASH') {
            return join(',', sort keys(%$value));
        } else {
            return $value;
        }
    }

    return $value;
}


#helpers
sub api_request {
    my ($method, $url, $headers, $data) = @_;

    my $encoded_data = to_json($data) if $data;

    my $req = HTTP::Request->new($method,$url, $headers, $encoded_data);

    my $ua = LWP::UserAgent->new(protocols_allowed => ['http', 'https'], timeout => 30);
    my $proxy = undef;

    if ($proxy) {
        $ua->proxy(['http', 'https'], $proxy);
    } else {
        $ua->env_proxy;
    }

    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0x00);

    my $response = $ua->request($req);
    my $code = $response->code;

    if ($code !~ /^2(\d+)$/) {
        my $msg = $response->message || 'unknown';
        die "Invalid response from server: $code $msg\n";
    }

    my $raw = '';
    if (defined($response->decoded_content)) {
	$raw = $response->decoded_content;
    } else {
	$raw = $response->content;
    }

    return if $raw eq '';

    my $json = '';
    eval {
	$json = from_json($raw);
    };
    die "api response is not a json" if $@;

    return $json;
}

1;
