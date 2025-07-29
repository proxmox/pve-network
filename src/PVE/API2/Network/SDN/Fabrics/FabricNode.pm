package PVE::API2::Network::SDN::Fabrics::FabricNode;

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(extract_param);

use PVE::Network::SDN;
use PVE::Network::SDN::Fabrics;

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'list_nodes_fabric',
    path => '',
    method => 'GET',
    permissions => {
        description =>
            "Only returns nodes where you have 'Sys.Audit' or 'Sys.Modify' permissions.",
        check => ['perm', '/sdn/fabrics/{fabric_id}', ['SDN.Audit']],
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
            fabric_id => get_standard_option('pve-sdn-fabric-id'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => PVE::Network::SDN::Fabrics::node_properties(0),
        },
        links => [{ rel => 'child', href => "{node_id}" }],
    },
    code => sub {
        my ($param) = @_;

        my $fabric_id = extract_param($param, 'fabric_id');
        my $pending = extract_param($param, 'pending');
        my $running = extract_param($param, 'running');

        my $digest;
        my $nodes;

        if ($pending) {
            my $current_config = PVE::Network::SDN::Fabrics::config();
            my $running_config = PVE::Network::SDN::Fabrics::config(1);

            my $running_nodes = $running_config->list_nodes_fabric($fabric_id);

            my $current_nodes = $current_config->list_nodes_fabric($fabric_id);

            my $pending_nodes = PVE::Network::SDN::pending_config(
                { nodes => { ids => $running_nodes } },
                { ids => $current_nodes },
                'nodes',
            );

            $digest = $current_config->digest();
            $nodes = $pending_nodes->{ids};
        } elsif ($running) {
            $nodes = PVE::Network::SDN::Fabrics::config(1)->list_nodes_fabric($fabric_id);
        } else {
            my $current_config = PVE::Network::SDN::Fabrics::config();

            $digest = $current_config->digest();
            $nodes = $current_config->list_nodes_fabric($fabric_id);
        }

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $node_privs = ['Sys.Audit', 'Sys.Modify'];

        my @res;
        for my $node_id (sort keys %$nodes) {
            next if !$rpcenv->check_any($authuser, "/nodes/$node_id", $node_privs, 1);
            $nodes->{$node_id}->{digest} = $digest if $digest;
            push @res, $nodes->{$node_id};
        }

        return \@res;
    },
});

__PACKAGE__->register_method({
    name => 'get_node',
    path => '{node_id}',
    method => 'GET',
    description => 'Get a node',
    permissions => {
        check => [
            'and',
            ['perm', '/sdn/fabrics/{fabric_id}', ['SDN.Audit', 'SDN.Allocate'], any => 1],
            ['perm', '/nodes/{node_id}', ['Sys.Audit', 'Sys.Modify'], any => 1],
        ],
    },
    parameters => {
        properties => {
            fabric_id => get_standard_option('pve-sdn-fabric-id'),
            node_id => get_standard_option('pve-sdn-fabric-node-id'),
        },
    },
    returns => {
        properties => PVE::Network::SDN::Fabrics::node_properties(0),
    },
    code => sub {
        my ($param) = @_;

        my $fabric_id = extract_param($param, 'fabric_id');
        my $node_id = extract_param($param, 'node_id');

        my $config = PVE::Network::SDN::Fabrics::config();

        my $node = $config->get_node($fabric_id, $node_id);
        $node->{digest} = $config->digest();

        return $node;
    },
});

__PACKAGE__->register_method({
    name => 'add_node',
    path => '',
    method => 'POST',
    description => 'Add a node',
    protected => 1,
    permissions => {
        check => [
            'and',
            ['perm', '/sdn/fabrics/{fabric_id}', ['SDN.Allocate']],
            ['perm', '/nodes/{node_id}', ['Sys.Modify']],
        ],
    },
    parameters => {
        properties => PVE::Network::SDN::Fabrics::node_properties(0),
    },
    returns => {
        type => 'null',
    },
    code => sub {
        my ($param) = @_;

        my $lock_token = extract_param($param, 'lock-token');

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $config = PVE::Network::SDN::Fabrics::config();

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                $config->add_node($param);
                PVE::Network::SDN::Fabrics::write_config($config);
            },
            "adding node failed",
            $lock_token,
        );
    },
});

__PACKAGE__->register_method({
    name => 'update_node',
    path => '{node_id}',
    method => 'PUT',
    description => 'Update a node',
    protected => 1,
    permissions => {
        check => [
            'and',
            ['perm', '/sdn/fabrics/{fabric_id}', ['SDN.Allocate']],
            ['perm', '/nodes/{node_id}', ['Sys.Modify']],
        ],
    },
    parameters => {
        properties => PVE::Network::SDN::Fabrics::node_properties(1),
    },
    returns => {
        type => 'null',
    },
    code => sub {
        my ($param) = @_;

        my $lock_token = extract_param($param, 'lock-token');

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $fabric_id = extract_param($param, 'fabric_id');
                my $node_id = extract_param($param, 'node_id');

                my $config = PVE::Network::SDN::Fabrics::config();

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                $config->update_node($fabric_id, $node_id, $param);
                PVE::Network::SDN::Fabrics::write_config($config);
            },
            "updating node failed",
            $lock_token,
        );
    },
});

__PACKAGE__->register_method({
    name => 'delete_node',
    path => '{node_id}',
    method => 'DELETE',
    description => 'Add a node',
    protected => 1,
    permissions => {
        check => [
            'and',
            ['perm', '/sdn/fabrics/{fabric_id}', ['SDN.Allocate']],
            ['perm', '/nodes/{node_id}', ['Sys.Modify']],
        ],
    },
    parameters => {
        properties => {
            fabric_id => get_standard_option('pve-sdn-fabric-id'),
            node_id => get_standard_option('pve-sdn-fabric-node-id'),
        },
    },
    returns => {
        type => 'null',
    },
    code => sub {
        my ($param) = @_;

        my $lock_token = extract_param($param, 'lock-token');

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $fabric_id = extract_param($param, 'fabric_id');
                my $node_id = extract_param($param, 'node_id');

                my $config = PVE::Network::SDN::Fabrics::config();

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                $config->delete_node($fabric_id, $node_id);
                PVE::Network::SDN::Fabrics::write_config($config);
            },
            "deleting node failed",
            $lock_token,
        );
    },
});

1;
