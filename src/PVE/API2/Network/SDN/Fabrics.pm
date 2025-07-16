package PVE::API2::Network::SDN::Fabrics;

use strict;
use warnings;

use PVE::Tools qw(extract_param);

use PVE::Network::SDN;
use PVE::Network::SDN::Fabrics;

use PVE::API2::Network::SDN::Fabrics::Fabric;

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Fabrics::Fabric",
    path => 'fabric',
});

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    permissions => {
        check => ['perm', '/sdn/fabrics', ['SDN.Audit']],
    },
    description => "SDN Fabrics Index",
    parameters => {
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                subdir => { type => 'string' },
            },
        },
        links => [{ rel => 'child', href => "{subdir}" }],
    },
    code => sub {
        my ($param) = @_;

        my $res = [
            { subdir => 'fabric' }, { subdir => 'all' },
        ];

        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'list_all',
    path => 'all',
    method => 'GET',
    permissions => {
        description =>
            "Only list fabrics where you have 'SDN.Audit' or 'SDN.Allocate' permissions on\n"
            . "'/sdn/fabrics/<fabric>', only list nodes where you have 'Sys.Audit' or 'Sys.Modify' on /nodes/<node_id>",
        user => 'all',
    },
    description => "SDN Fabrics Index",
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
        },
    },
    returns => {
        type => 'object',
        properties => {
            fabrics => {
                type => 'array',
                items => {
                    type => "object",
                    properties => PVE::Network::SDN::Fabrics::fabric_properties(0),
                },
            },
            nodes => {
                type => 'array',
                items => {
                    type => "object",
                    properties => PVE::Network::SDN::Fabrics::node_properties(0),
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $pending = extract_param($param, 'pending');
        my $running = extract_param($param, 'running');

        my $digest;
        my $fabrics;
        my $nodes;

        if ($pending) {
            my $current_config = PVE::Network::SDN::Fabrics::config();
            my $running_config = PVE::Network::SDN::Fabrics::config(1);

            my ($running_fabrics, $running_nodes) = $running_config->list_all();

            my ($current_fabrics, $current_nodes) = $current_config->list_all();

            my $pending_fabrics = PVE::Network::SDN::pending_config(
                { fabrics => { ids => $running_fabrics } },
                { ids => $current_fabrics },
                'fabrics',
            );

            my $pending_nodes = PVE::Network::SDN::pending_config(
                { nodes => { ids => $running_nodes } },
                { ids => $current_nodes },
                'nodes',
            );

            $digest = $current_config->digest();
            $fabrics = $pending_fabrics->{ids};
            $nodes = $pending_nodes->{ids};
        } elsif ($running) {
            ($fabrics, $nodes) = PVE::Network::SDN::Fabrics::config(1)->list_all();
        } else {
            my $current_config = PVE::Network::SDN::Fabrics::config();

            ($fabrics, $nodes) = $current_config->list_all();
            $digest = $current_config->digest();
        }

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $fabric_privs = ['SDN.Audit', 'SDN.Allocate'];
        my $node_privs = ['Sys.Audit', 'Sys.Modify'];

        my @res_fabrics;
        for my $id (keys %$fabrics) {
            next if !$rpcenv->check_any($authuser, "/sdn/fabrics/$id", $fabric_privs, 1);

            $fabrics->{$id}->{digest} = $digest if $digest;
            push @res_fabrics, $fabrics->{$id};
        }

        my @res_nodes;
        for my $node_id (keys %$nodes) {
            my $node = $nodes->{$node_id};
            my $fabric_id = $node->{fabric_id} // $node->{pending}->{fabric_id};

            next if !$rpcenv->check_any($authuser, "/sdn/fabrics/$fabric_id", $fabric_privs, 1);
            next if !$rpcenv->check_any($authuser, "/nodes/$node_id", $node_privs, 1);

            $node->{digest} = $digest if $digest;

            push @res_nodes, $node;
        }

        return {
            fabrics => \@res_fabrics,
            nodes => \@res_nodes,
        };
    },
});

1;
