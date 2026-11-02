package PVE::API2::Network::SDN::Subnets;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Exception qw(raise raise_param_exc);
use PVE::Network::SDN;
use PVE::Network::SDN::Subnets;
use PVE::Network::SDN::SubnetPlugin;
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones;
use PVE::Network::SDN::Ipams;
use PVE::Network::SDN::Ipams::Plugin;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

# Returns the subnet and vnet configuration of the state requested via the pending and running
# parameters, so that permissions are checked on the vnets of the returned configuration.
my $get_subnet_and_vnet_config = sub {
    my ($param) = @_;

    if ($param->{pending}) {
        my $running_cfg = PVE::Network::SDN::running_config();
        my $subnet_cfg = PVE::Network::SDN::Subnets::config();
        my $vnet_cfg = PVE::Network::SDN::Vnets::config();
        return (
            PVE::Network::SDN::pending_config($running_cfg, $subnet_cfg, 'subnets'),
            PVE::Network::SDN::pending_config($running_cfg, $vnet_cfg, 'vnets'),
        );
    } elsif ($param->{running}) {
        my $running_cfg = PVE::Network::SDN::running_config();
        return ($running_cfg->{subnets}, $running_cfg->{vnets});
    }

    return (PVE::Network::SDN::Subnets::config(), PVE::Network::SDN::Vnets::config());
};

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SDN subnets index.",
    permissions => {
        description =>
            "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            vnet => get_standard_option('pve-sdn-vnet-id'),
            running => {
                type => 'boolean',
                optional => 1,
                description => "Display running config.",
            },
            pending => {
                type => 'boolean',
                optional => 1,
                description => "Display pending config.",
            },
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {},
        },
        links => [{ rel => 'child', href => "{subnet}" }],
    },
    code => sub {
        my ($param) = @_;

        my $vnetid = $param->{vnet};
        my $privs = ['SDN.Audit', 'SDN.Allocate'];

        my ($cfg, $vnet_cfg) = $get_subnet_and_vnet_config->($param);
        my $_vnet = PVE::Network::SDN::Vnets::api_get_vnet_checked($vnetid, $privs, $vnet_cfg);

        my @sids = PVE::Network::SDN::Subnets::sdn_subnets_ids($cfg);
        my $res = [];
        foreach my $id (@sids) {
            my $scfg = eval {
                PVE::Network::SDN::Subnets::api_get_subnet_in_vnet_checked(
                    $vnetid, $id, $privs, $cfg, $vnet_cfg,
                );
            };
            next if $@;

            push @$res, $scfg;
        }

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'read',
    path => '{subnet}',
    method => 'GET',
    description => "Read sdn subnet configuration.",
    permissions => {
        description =>
            "Require 'SDN.Audit' or 'SDN.Allocate' permissions on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            vnet => get_standard_option('pve-sdn-vnet-id'),
            subnet => get_standard_option(
                'pve-sdn-subnet-id',
                {
                    completion => \&PVE::Network::SDN::Subnets::complete_sdn_subnets,
                },
            ),
            running => {
                type => 'boolean',
                optional => 1,
                description => "Display running config.",
            },
            pending => {
                type => 'boolean',
                optional => 1,
                description => "Display pending config.",
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        my $vnet = extract_param($param, 'vnet');
        my $privs = ['SDN.Audit', 'SDN.Allocate'];

        my ($cfg, $vnet_cfg) = $get_subnet_and_vnet_config->($param);
        my $_vnet = PVE::Network::SDN::Vnets::api_get_vnet_checked($vnet, $privs, $vnet_cfg);

        return PVE::Network::SDN::Subnets::api_get_subnet_in_vnet_checked(
            $vnet, $param->{subnet}, $privs, $cfg, $vnet_cfg,
        );
    },
});

__PACKAGE__->register_method({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new sdn subnet object.",
    permissions => {
        description => "Require 'SDN.Allocate' permission on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => PVE::Network::SDN::SubnetPlugin->createSchema(
        undef,
        {
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
        },
    ),
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $type = extract_param($param, 'type');
        my $cidr = extract_param($param, 'subnet');
        my $lock_token = extract_param($param, 'lock-token');

        my $vnet = $param->{vnet};
        my $privs = ['SDN.Allocate'];
        my $_vnet = PVE::Network::SDN::Vnets::api_get_vnet_checked($vnet, $privs);

        # create /etc/pve/sdn directory
        PVE::Cluster::check_cfs_quorum();
        mkdir("/etc/pve/sdn") if !-d '/etc/pve/sdn';

        PVE::Network::SDN::lock_sdn_config(
            sub {

                my $cfg = PVE::Network::SDN::Subnets::config();
                my $zone_cfg = PVE::Network::SDN::Zones::config();
                my $vnet_cfg = PVE::Network::SDN::Vnets::config();
                my $vnet = $param->{vnet};
                my $zoneid = $vnet_cfg->{ids}->{$vnet}->{zone};
                my $zone = $zone_cfg->{ids}->{$zoneid};
                my $id = $cidr =~ s/\//-/r;
                $id = "$zoneid-$id";

                my $opts = PVE::Network::SDN::SubnetPlugin->check_config($id, $param, 1, 1);

                my $scfg = undef;
                if ($scfg = PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $id, 1)) {
                    die "sdn subnet object ID '$id' already defined\n";
                }

                $cfg->{ids}->{$id} = $opts;

                my $subnet = PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $id);
                PVE::Network::SDN::SubnetPlugin->on_update_hook($zone, $id, $subnet);

                PVE::Network::SDN::Subnets::write_config($cfg);

            },
            "create sdn subnet object failed",
            $lock_token,
        );

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'update',
    protected => 1,
    path => '{subnet}',
    method => 'PUT',
    description => "Update sdn subnet object configuration.",
    permissions => {
        description => "Require 'SDN.Allocate' permission on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => PVE::Network::SDN::SubnetPlugin->updateSchema(
        undef,
        {
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
        },
    ),
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $id = extract_param($param, 'subnet');
        my $digest = extract_param($param, 'digest');
        my $delete = extract_param($param, 'delete');
        my $lock_token = extract_param($param, 'lock-token');

        my $vnet = $param->{vnet};
        my $privs = ['SDN.Allocate'];
        my $_vnet = PVE::Network::SDN::Vnets::api_get_vnet_checked($vnet, $privs);

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $cfg = PVE::Network::SDN::Subnets::config();

                my $privs = ['SDN.Allocate'];
                my $scfg = PVE::Network::SDN::Subnets::api_get_subnet_in_vnet_checked(
                    $vnet, $id, $privs, $cfg,
                );

                my $zone_cfg = PVE::Network::SDN::Zones::config();
                my $vnet_cfg = PVE::Network::SDN::Vnets::config();
                my $zoneid = $vnet_cfg->{ids}->{$vnet}->{zone};
                my $zone = $zone_cfg->{ids}->{$zoneid};

                PVE::SectionConfig::assert_if_modified($cfg, $digest);

                my $opts = PVE::Network::SDN::SubnetPlugin->check_config($id, $param, 0, 1);

                my $data = $cfg->{ids}->{$id};
                if ($delete) {
                    $delete = [PVE::Tools::split_list($delete)];
                    my $options =
                        PVE::Network::SDN::SubnetPlugin->private()->{options}->{ $data->{type} };
                    PVE::SectionConfig::delete_from_config($data, $options, $opts, $delete);
                }
                $data->{$_} = $opts->{$_} for keys $opts->%*;

                my $subnet = PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $id);
                PVE::Network::SDN::SubnetPlugin->on_update_hook($zone, $id, $subnet, $scfg);

                PVE::Network::SDN::Subnets::write_config($cfg);

            },
            "update sdn subnet object failed",
            $lock_token,
        );

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'delete',
    protected => 1,
    path => '{subnet}',
    method => 'DELETE',
    description => "Delete sdn subnet object configuration.",
    permissions => {
        description => "Require 'SDN.Allocate' permission on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            vnet => get_standard_option('pve-sdn-vnet-id'),
            subnet => get_standard_option(
                'pve-sdn-subnet-id',
                {
                    completion => \&PVE::Network::SDN::Subnets::complete_sdn_subnets,
                },
            ),
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $id = extract_param($param, 'subnet');
        my $vnet = extract_param($param, 'vnet');
        my $lock_token = extract_param($param, 'lock-token');

        my $privs = ['SDN.Allocate'];
        my $_vnet = PVE::Network::SDN::Vnets::api_get_vnet_checked($vnet, $privs);

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $cfg = PVE::Network::SDN::Subnets::config();

                my $scfg = PVE::Network::SDN::Subnets::api_get_subnet_in_vnet_checked(
                    $vnet, $id, $privs, $cfg,
                );

                my $vnets_cfg = PVE::Network::SDN::Vnets::config();

                PVE::Network::SDN::SubnetPlugin->on_delete_hook($id, $cfg, $vnets_cfg);

                my $zone_cfg = PVE::Network::SDN::Zones::config();
                my $zoneid = $vnets_cfg->{ids}->{$vnet}->{zone};
                my $zone = $zone_cfg->{ids}->{$zoneid};

                PVE::Network::SDN::Subnets::del_subnet($zone, $id, $scfg);

                delete $cfg->{ids}->{$id};

                PVE::Network::SDN::Subnets::write_config($cfg);

            },
            "delete sdn subnet object failed",
            $lock_token,
        );

        return undef;
    },
});

1;
