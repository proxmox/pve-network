package PVE::API2::Network::SDN::Fabrics::Node;

use strict;
use warnings;

use PVE::Tools qw(extract_param);

use PVE::Network::SDN;
use PVE::Network::SDN::Fabrics;
use PVE::API2::Network::SDN::Fabrics::FabricNode;

use PVE::JSONSchema qw(get_standard_option);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Fabrics::FabricNode",
    path => '{fabric_id}',
});

__PACKAGE__->register_method({
    name => 'list_nodes',
    path => '',
    method => 'GET',
    permissions => {
        description =>
            "Only list nodes where you have 'SDN.Audit' or 'SDN.Allocate' permissions on\n"
            . "'/sdn/fabrics/<fabric>' and 'Sys.Audit' or 'Sys.Modify' on /nodes/<node_id>",
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
        type => 'array',
        items => {
            type => "object",
            properties => PVE::Network::SDN::Fabrics::node_properties(0),
        },
        links => [{ rel => 'child', href => "{fabric_id}" }],
    },
    code => sub {
        my ($param) = @_;

        my $pending = extract_param($param, 'pending');
        my $running = extract_param($param, 'running');

        my $digest;
        my $nodes;

        if ($pending) {
            my $current_config = PVE::Network::SDN::Fabrics::config();
            my $running_config = PVE::Network::SDN::Fabrics::config(1);

            my $running_nodes = $running_config->list_nodes();

            my $current_nodes = $current_config->list_nodes();

            my $pending_nodes = PVE::Network::SDN::pending_config(
                { nodes => { ids => $running_nodes } },
                { ids => $current_nodes },
                'nodes',
            );

            $digest = $current_config->digest();
            $nodes = $pending_nodes->{ids};
        } elsif ($running) {
            $nodes = PVE::Network::SDN::Fabrics::config(1)->list_nodes();
        } else {
            my $current_config = PVE::Network::SDN::Fabrics::config();

            $digest = $current_config->digest();
            $nodes = $current_config->list_nodes();
        }

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $fabric_privs = ['SDN.Audit', 'SDN.Allocate'];
        my $node_privs = ['Sys.Audit', 'Sys.Modify'];

        my @res;

        for my $node_id (keys %$nodes) {
            my $node = $nodes->{$node_id};
            my $fabric_id = $node->{fabric_id};

            next if !$rpcenv->check_any($authuser, "/sdn/fabrics/$fabric_id", $fabric_privs, 1);
            next if !$rpcenv->check_any($authuser, "/nodes/$node_id", $node_privs, 1);

            $node->{digest} = $digest if $digest;

            push @res, $node;
        }

        return \@res;
    },
});

1;
