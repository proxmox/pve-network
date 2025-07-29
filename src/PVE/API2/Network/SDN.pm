package PVE::API2::Network::SDN;

use strict;
use warnings;

use PVE::Cluster qw(cfs_lock_file cfs_read_file cfs_write_file);
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::SafeSyslog;
use PVE::Tools qw(run_command extract_param);
use PVE::Network::SDN;

use PVE::API2::Network::SDN::Controllers;
use PVE::API2::Network::SDN::Vnets;
use PVE::API2::Network::SDN::Zones;
use PVE::API2::Network::SDN::Ipams;
use PVE::API2::Network::SDN::Dns;
use PVE::API2::Network::SDN::Fabrics;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Vnets",
    path => 'vnets',
});

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Zones",
    path => 'zones',
});

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Controllers",
    path => 'controllers',
});

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Ipams",
    path => 'ipams',
});

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Dns",
    path => 'dns',
});

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Fabrics",
    path => 'fabrics',
});

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Directory index.",
    permissions => {
        check => ['perm', '/sdn', ['SDN.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                id => { type => 'string' },
            },
        },
        links => [{ rel => 'child', href => "{id}" }],
    },
    code => sub {
        my ($param) = @_;

        my $res = [
            { id => 'vnets' },
            { id => 'zones' },
            { id => 'controllers' },
            { id => 'ipams' },
            { id => 'dns' },
            { id => 'fabrics' },
        ];

        return $res;
    },
});

my $create_reload_network_worker = sub {
    my ($nodename, $skip_frr) = @_;

    my @command = ('pvesh', 'set', "/nodes/$nodename/network");
    if ($skip_frr) {
        push(@command, '--skip_frr');
    }

    # FIXME: how to proxy to final node ?
    my $upid;
    print "$nodename: reloading network config\n";
    run_command(
        \@command,
        outfunc => sub {
            my $line = shift;
            if ($line =~ /["']?(UPID:[^\s"']+)["']?$/) {
                $upid = $1;
            }
        },
    );
    #my $upid = PVE::API2::Network->reload_network_config(node => $nodename});
    my $res = PVE::Tools::upid_decode($upid);

    return $res->{pid};
};

__PACKAGE__->register_method({
    name => 'lock',
    protected => 1,
    path => 'lock',
    method => 'POST',
    description => "Acquire global lock for SDN configuration",
    permissions => {
        check => ['perm', '/sdn', ['SDN.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            'allow-pending' => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description =>
                    'if true, allow acquiring lock even though there are pending changes',
            },
        },
    },
    returns => {
        type => 'string',
    },
    code => sub {
        my ($param) = @_;

        return PVE::Network::SDN::lock_sdn_config(
            sub {
                die "configuration has pending changes"
                    if !$param->{'allow-pending'} && PVE::Network::SDN::has_pending_changes();

                return PVE::Network::SDN::create_global_lock();
            },
            "could not acquire lock for SDN config",
        );
    },
});

__PACKAGE__->register_method({
    name => 'release_lock',
    protected => 1,
    path => 'lock',
    method => 'DELETE',
    description => "Release global lock for SDN configuration",
    permissions => {
        check => ['perm', '/sdn', ['SDN.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
            'force' => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => 'if true, allow releasing lock without providing the token',
            },
        },
    },
    returns => {
        type => 'null',
    },
    code => sub {
        my ($param) = @_;

        my $code = sub {
            PVE::Network::SDN::delete_global_lock();
        };

        if ($param->{force}) {
            $code->();
        } else {
            PVE::Network::SDN::lock_sdn_config(
                $code,
                "could not release lock",
                $param->{'lock-token'},
            );
        }
    },
});

__PACKAGE__->register_method ({
    name => 'reload',
    protected => 1,
    path => '',
    method => 'PUT',
    description => "Apply sdn controller changes && reload.",
    permissions => {
        check => ['perm', '/sdn', ['SDN.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
            'release-lock' => {
                type => 'boolean',
                optional => 1,
                default => 1,
                description =>
                    'When lock-token has been provided and configuration successfully commited, release the lock automatically afterwards',
            },
        },
    },
    returns => {
        type => 'string',
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $lock_token = extract_param($param, 'lock-token');
        my $release_lock = extract_param($param, 'release-lock');

        my $previous_config_has_frr;
        my $new_config_has_frr;

        PVE::Network::SDN::lock_sdn_config(
            sub {
                $previous_config_has_frr = PVE::Network::SDN::running_config_has_frr();
                PVE::Network::SDN::commit_config();
                $new_config_has_frr = PVE::Network::SDN::running_config_has_frr();

                PVE::Network::SDN::delete_global_lock() if $lock_token && $release_lock;
            },
            "could not commit SDN config",
            $lock_token,
        );

        my $skip_frr = !($previous_config_has_frr || $new_config_has_frr);

        my $code = sub {
            $rpcenv->{type} = 'priv'; # to start tasks in background
            PVE::Cluster::check_cfs_quorum();
            my $nodelist = PVE::Cluster::get_nodelist();
            for my $node (@$nodelist) {
                my $pid = eval { $create_reload_network_worker->($node, $skip_frr) };
                warn $@ if $@;
            }

            # FIXME: use libpve-apiclient (like in cluster join) to create
            # tasks and moitor the tasks.

            return;
        };

        return $rpcenv->fork_worker('reloadnetworkall', undef, $authuser, $code);

    },
});

1;
