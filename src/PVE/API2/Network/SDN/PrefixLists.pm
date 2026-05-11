package PVE::API2::Network::SDN::PrefixLists;

use strict;
use warnings;

use PVE::API2::Network::SDN::PrefixLists::PrefixList;
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN::PrefixLists;
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::PrefixLists::PrefixList",
    path => '{id}',
});

__PACKAGE__->register_method({
    name => 'list_prefix_lists',
    path => '',
    method => 'GET',
    permissions => {
        description =>
            "Only returns prefix list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions.",
        user => 'all',
    },
    description => "List Prefix Lists",
    parameters => {
        properties => {
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
            verbose => {
                type => 'boolean',
                optional => 1,
                description => "If 0, only returns id - otherwise returns all properties.",
            },
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {},
        },
        links => [{ rel => 'child', href => "{id}" }],
    },
    code => sub {
        my ($param) = @_;

        my $pending = extract_param($param, 'pending');
        my $running = extract_param($param, 'running');
        my $verbose = extract_param($param, 'verbose');

        my $digest;
        my $prefix_lists;

        if ($pending) {
            my $current_config = PVE::Network::SDN::PrefixLists::config();
            my $running_config = PVE::Network::SDN::PrefixLists::config(1);

            my $pending_prefix_lists = PVE::Network::SDN::pending_config(
                { 'prefix-lists' => { ids => $running_config->list() } },
                { ids => $current_config->list() },
                'prefix-lists',
            );

            $digest = $current_config->digest();
            $prefix_lists = $pending_prefix_lists->{ids};
        } elsif ($running) {
            $prefix_lists = PVE::Network::SDN::PrefixLists::config(1)->list();
        } else {
            my $current_config = PVE::Network::SDN::PrefixLists::config();

            $digest = $current_config->digest();
            $prefix_lists = $current_config->list();
        }

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $prefix_list_privs = ['SDN.Audit', 'SDN.Allocate'];

        my @res;
        for my $prefix_list_id (sort keys $prefix_lists->%*) {
            next
                if !$rpcenv->check_any(
                    $authuser,
                    "/sdn/prefix-lists/$prefix_list_id",
                    $prefix_list_privs,
                    1,
                );

            if ($verbose) {
                $prefix_lists->{$prefix_list_id}->{digest} = $digest if $digest;
                push @res, $prefix_lists->{$prefix_list_id};
            } else {
                my $data = {
                    id => $prefix_list_id,
                };

                $data->{state} = $prefix_lists->{$prefix_list_id}->{state}
                    if $pending && $prefix_lists->{$prefix_list_id}->{state};

                push @res, $data;
            }
        }

        return \@res;
    },
});

__PACKAGE__->register_method({
    name => 'create_prefix_list_entry',
    path => '',
    method => 'POST',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/prefix-lists', ['SDN.Allocate']],
    },
    description => "Create Prefix List",
    parameters => {
        properties => {
            digest => get_standard_option('pve-config-digest'),
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
            PVE::Network::SDN::PrefixLists::prefix_list_properties(0)->%*,
        },
    },
    returns => {
        type => "null",
    },
    code => sub {
        my ($param) = @_;

        my $lock_token = extract_param($param, 'lock-token');

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $config = PVE::Network::SDN::PrefixLists::config();

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                $config->create($param);
                PVE::Network::SDN::PrefixLists::write_config($config);
            },
            "creating prefix list failed",
            $lock_token,
        );

        return;
    },
});

1;
