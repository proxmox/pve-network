package PVE::Network::SDN;

use strict;
use warnings;

use HTTP::Request;
use IO::Socket::SSL; # important for SSL_verify_callback
use JSON qw(decode_json from_json to_json);
use LWP::UserAgent;
use Net::SSLeay;
use UUID;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::INotify;
use PVE::RESTEnvironment qw(log_warn);
use PVE::RPCEnvironment;
use PVE::Tools qw(file_get_contents file_set_contents extract_param dir_glob_regex run_command);

use PVE::RS::SDN::Fabrics;

use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones;
use PVE::Network::SDN::Controllers;
use PVE::Network::SDN::Subnets;
use PVE::Network::SDN::Dhcp;
use PVE::Network::SDN::Frr;
use PVE::Network::SDN::Fabrics;

my $running_cfg = "sdn/.running-config";

my $parse_running_cfg = sub {
    my ($filename, $raw) = @_;

    my $cfg = {};

    return $cfg if !defined($raw) || $raw eq '';

    eval { $cfg = from_json($raw); };
    return {} if $@;

    return $cfg;
};

my $write_running_cfg = sub {
    my ($filename, $cfg) = @_;

    my $json = to_json($cfg);

    return $json;
};

PVE::Cluster::cfs_register_file($running_cfg, $parse_running_cfg, $write_running_cfg);

my $LOCK_TOKEN_FILE = "/etc/pve/sdn/.lock";

PVE::JSONSchema::register_standard_option(
    'pve-sdn-lock-token',
    {
        type => 'string',
        description => "the token for unlocking the global SDN configuration",
        optional => 1,
    },
);

PVE::JSONSchema::register_standard_option(
    'pve-sdn-config-state',
    {
        type => 'string',
        enum => ['new', 'changed', 'deleted'],
        description => 'State of the SDN configuration object.',
        optional => 1,
    },
);

# improve me : move status code inside plugins ?

sub ifquery_check {

    my $cmd = ['ifquery', '-a', '-c', '-o', 'json'];

    my $result = '';
    my $reader = sub { $result .= shift };

    eval { run_command($cmd, outfunc => $reader); };

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
    my $fabric_status = PVE::RS::SDN::Fabrics::status();
    return ($zone_status, $vnet_status, $fabric_status);
}

sub running_config {
    return cfs_read_file($running_cfg);
}

=head3 running_config_has_frr(\%running_config)

Determines whether C<\%running_config> contains any entities that generate an
FRR configuration. This is used by pve-manager to determine whether a rewrite of
the FRR configuration is required or not.

If C<\%running_config> is not provided, it will query the current running
configuration and then evaluate it.

=cut

sub running_config_has_frr {
    my $running_config = PVE::Network::SDN::running_config();

    # both can be empty if the SDN configuration was never applied
    my $controllers = $running_config->{controllers}->{ids} // {};
    my $fabrics = $running_config->{fabrics}->{ids} // {};

    return %$controllers || %$fabrics;
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
            if (!keys %{$config_object}) {
                $pending->{$id}->{state} = "deleted";
            } elsif (!defined($config_object->{$key})) {
                $pending->{$id}->{"pending"}->{$key} = 'deleted';
                $pending->{$id}->{state} = "changed";
            } elsif (PVE::Network::SDN::encode_value(undef, $key, $running_object->{$key}) ne
                PVE::Network::SDN::encode_value(undef, $key, $config_object->{$key})
            ) {
                $pending->{$id}->{state} = "changed";
            }
        }
        $pending->{$id}->{"pending"} = {}
            if $pending->{$id}->{state} && !defined($pending->{$id}->{"pending"});
    }

    foreach my $id (sort keys %{$config_objects}) {
        my $running_object = $running_objects->{$id};
        my $config_object = $config_objects->{$id};

        foreach my $key (sort keys %{$config_object}) {
            my $config_value = PVE::Network::SDN::encode_value(undef, $key, $config_object->{$key});
            my $running_value =
                PVE::Network::SDN::encode_value(undef, $key, $running_object->{$key});
            if ($key eq 'type' || $key eq 'vnet') {
                $pending->{$id}->{$key} = $config_value;
            } else {
                $pending->{$id}->{"pending"}->{$key} = $config_object->{$key}
                    if !defined($running_value)
                    || ($config_value ne $running_value);
            }
            if (!keys %{$running_object}) {
                $pending->{$id}->{state} = "new";
            } elsif (!defined($running_value) && defined($config_value)) {
                $pending->{$id}->{state} = "changed";
            }
        }
        $pending->{$id}->{"pending"} = {}
            if $pending->{$id}->{state} && !defined($pending->{$id}->{"pending"});
    }

    return { ids => $pending };

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
    my $fabrics_cfg = PVE::Network::SDN::Fabrics::config();

    my $vnets = { ids => $vnets_cfg->{ids} };
    my $zones = { ids => $zones_cfg->{ids} };
    my $controllers = { ids => $controllers_cfg->{ids} };
    my $subnets = { ids => $subnets_cfg->{ids} };
    my $fabrics = { ids => $fabrics_cfg->to_sections() };

    $cfg = {
        version => $version,
        vnets => $vnets,
        zones => $zones,
        controllers => $controllers,
        subnets => $subnets,
        fabrics => $fabrics,
    };

    cfs_write_file($running_cfg, $cfg);
}

sub has_pending_changes {
    my $running_cfg = PVE::Network::SDN::running_config();

    # only use configuration files which get written by commit_config here
    my $config_files = {
        zones => PVE::Network::SDN::Zones::config(),
        vnets => PVE::Network::SDN::Vnets::config(),
        subnets => PVE::Network::SDN::Subnets::config(),
        controllers => PVE::Network::SDN::Controllers::config(),
    };

    for my $config_file (keys %$config_files) {
        my $config = $config_files->{$config_file};
        my $pending_config = PVE::Network::SDN::pending_config($running_cfg, $config, $config_file);

        for my $id (keys %{ $pending_config->{ids} }) {
            return 1 if $pending_config->{ids}->{$id}->{pending};
        }
    }

    return 0;
}

sub generate_lock_token {
    my $str;
    my $uuid;

    UUID::generate_v7($uuid);
    UUID::unparse($uuid, $str);

    return $str;
}

sub create_global_lock {
    my $token = generate_lock_token();
    PVE::Tools::file_set_contents($LOCK_TOKEN_FILE, $token);
    return $token;
}

sub delete_global_lock {
    unlink $LOCK_TOKEN_FILE if -e $LOCK_TOKEN_FILE;
}

sub lock_sdn_config {
    my ($code, $errmsg, $lock_token_user) = @_;

    my $lock_wrapper = sub {
        my $lock_token = undef;
        if (-e $LOCK_TOKEN_FILE) {
            $lock_token = PVE::Tools::file_get_contents($LOCK_TOKEN_FILE);
        }

        if (
            defined($lock_token)
            && (!defined($lock_token_user) || $lock_token ne $lock_token_user)
        ) {
            die "invalid lock token provided!";
        }

        return $code->();
    };

    return lock_sdn_domain($lock_wrapper, $errmsg);
}

sub lock_sdn_domain {
    my ($code, $errmsg) = @_;

    my $res = PVE::Cluster::cfs_lock_domain("sdn", undef, $code);
    my $err = $@;
    if ($err) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
    return $res;
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

        my $privs = ['SDN.Audit', 'SDN.Use'];

        next if !$zoneid;
        next if !$rpcenv->check_sdn_bridge($authuser, $zoneid, $vnetid, $privs, 1);

        my $zone_config = PVE::Network::SDN::Zones::sdn_zones_config($zones_cfg, $zoneid);

        next if defined($zone_config->{nodes}) && !$zone_config->{nodes}->{$nodename};
        my $ipam = $zone_config->{ipam} ? 1 : 0;
        my $vlanaware = $vnet->{vlanaware} ? 1 : 0;
        $vnets->{$vnetid} = {
            type => 'vnet',
            active => '1',
            ipam => $ipam,
            vlanaware => $vlanaware,
            comments => $comments,
        };
    }

    return $vnets;
}

=head3 generate_raw_etc_network_config()

Generate the /etc/network/interfaces.d/sdn config file from the Zones
and Fabrics configuration and return it as a String.

=cut

sub generate_raw_etc_network_config {
    my $raw_config = "";

    my $zone_config = PVE::Network::SDN::Zones::generate_etc_network_config();
    $raw_config .= $zone_config if $zone_config;

    my $fabric_config = PVE::Network::SDN::Fabrics::generate_etc_network_config();
    $raw_config .= $fabric_config if $fabric_config;

    return $raw_config;
}

=head3 ⋅write_raw_etc_network_config($raw_config)

Writes a network configuration as generated by C<generate_raw_etc_network_config>
to /etc/network/interfaces.d/sdn.

=cut

sub write_raw_etc_network_config {
    my ($raw_config) = @_;
    my $local_network_sdn_file = "/etc/network/interfaces.d/sdn";

    die "no network config supplied" if !defined $raw_config;

    eval {
        my $net_cfg = PVE::INotify::read_file('interfaces', 1);
        my $opts = $net_cfg->{data}->{options};
        log_warn("missing 'source /etc/network/interfaces.d/sdn' directive for SDN support!\n")
            if !grep { $_->[1] =~ m!^source /etc/network/interfaces.d/(:?sdn|\*)! } @$opts;
    };

    log_warn("Failed to read network interfaces definition - $@") if $@;

    my $writefh = IO::File->new($local_network_sdn_file, ">");
    print $writefh $raw_config;
    $writefh->close();
}

=head3 ⋅generate_etc_network_config()

Generates the network configuration for all SDN plugins and writes it to the SDN
interfaces files (/etc/network/interfaces.d/sdn).

=cut

sub generate_etc_network_config {
    my $raw_config = PVE::Network::SDN::generate_raw_etc_network_config();
    PVE::Network::SDN::write_raw_etc_network_config($raw_config);
}

=head3 generate_frr_raw_config(\%running_config, \%fabric_config)

Generates the raw frr config (as documented in the C<PVE::Network::SDN::Frr>
module) for all SDN plugins combined.

If provided, uses the passed C<\%running_config> und C<\%fabric_config> to avoid
re-parsing and re-reading both configurations. If not provided, this function
will obtain them via the SDN and SDN::Fabrics modules and then generate the FRR
configuration.

=cut

sub generate_frr_raw_config {
    my ($running_config, $fabric_config) = @_;

    $running_config = PVE::Network::SDN::running_config() if !$running_config;
    $fabric_config = PVE::Network::SDN::Fabrics::config(1) if !$fabric_config;

    my $frr_config = {};
    PVE::Network::SDN::Controllers::generate_frr_config($frr_config, $running_config);
    PVE::Network::SDN::Frr::append_local_config($frr_config);

    my $raw_config = PVE::Network::SDN::Frr::to_raw_config($frr_config);

    my $fabrics_config = PVE::Network::SDN::Fabrics::generate_frr_raw_config($fabric_config);
    push @$raw_config, @$fabrics_config;

    return $raw_config;
}

=head3 get_frr_daemon_status(\%fabric_config)

Returns a hash that indicates which FRR daemons, that are managed by SDN, should
be enabled / disabled.

=cut

sub get_frr_daemon_status {
    my ($fabric_config) = @_;

    return PVE::Network::SDN::Fabrics::get_frr_daemon_status($fabric_config);
}

sub generate_frr_config {
    my ($apply) = @_;

    if (!-d '/etc/frr') {
        print "frr is not installed, not generating any frr configuration\n";
        return;
    }

    my $running_config = PVE::Network::SDN::running_config();
    my $fabric_config = PVE::Network::SDN::Fabrics::config(1);

    my $daemon_status = PVE::Network::SDN::get_frr_daemon_status($fabric_config);
    my $needs_restart = PVE::Network::SDN::Frr::set_daemon_status($daemon_status, 1);

    my $raw_config = PVE::Network::SDN::generate_frr_raw_config($running_config, $fabric_config);
    PVE::Network::SDN::Frr::write_raw_config($raw_config);

    PVE::Network::SDN::Frr::apply($needs_restart) if $apply;
}

sub generate_dhcp_config {
    my ($reload) = @_;

    PVE::Network::SDN::Dhcp::regenerate_config($reload);
}

sub encode_value {
    my ($type, $key, $value) = @_;

    if ($key eq 'nodes' || $key eq 'exitnodes' || $key eq 'dhcp-range' || $key eq 'interfaces') {
        if (ref($value) eq 'HASH') {
            return join(',', sort keys(%$value));
        } elsif (ref($value) eq 'ARRAY') {
            return join(',', sort @$value);
        } else {
            return $value;
        }
    }

    return $value;
}

#helpers
sub api_request {
    my ($method, $url, $headers, $data, $expected_fingerprint) = @_;

    my $encoded_data = $data ? to_json($data) : undef;

    my $req = HTTP::Request->new($method, $url, $headers, $encoded_data);

    my $ua = LWP::UserAgent->new(protocols_allowed => ['http', 'https'], timeout => 30);
    my $datacenter_cfg = PVE::Cluster::cfs_read_file('datacenter.cfg');
    if (my $proxy = $datacenter_cfg->{http_proxy}) {
        $ua->proxy(['http', 'https'], $proxy);
    } else {
        $ua->env_proxy;
    }

    if (defined($expected_fingerprint)) {
        my $ssl_verify_callback = sub {
            my (undef, undef, undef, undef, $cert, $depth) = @_;

            # we don't care about intermediate or root certificates, always return as valid as the
            # callback will be executed for all levels and all must be valid.
            return 1 if $depth != 0;

            my $fingerprint = Net::SSLeay::X509_get_fingerprint($cert, 'sha256');

            return $fingerprint eq $expected_fingerprint ? 1 : 0;
        };
        $ua->ssl_opts(
            verify_hostname => 0,
            SSL_verify_mode => SSL_VERIFY_PEER,
            SSL_verify_callback => $ssl_verify_callback,
        );
    }

    my $response = $ua->request($req);

    if (!$response->is_success) {
        my $msg = $response->message || 'unknown';
        my $code = $response->code;
        die "Invalid response from server: $code $msg\n";
    }

    my $raw = '';
    if (defined($response->decoded_content)) {
        $raw = $response->decoded_content;
    } else {
        $raw = $response->content;
    }
    return if $raw eq '';

    my $res = eval { from_json($raw) };
    die "api response is not a json" if $@;

    return $res;
}

1;
