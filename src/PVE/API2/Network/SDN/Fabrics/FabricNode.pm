package PVE::API2::Network::SDN::Fabrics::FabricNode;

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option parse_property_string);
use PVE::Tools qw(extract_param run_command);

use PVE::Network::SDN;
use PVE::Network::SDN::Fabrics;
use PVE::Network::SDN::WireGuard;
use PVE::RS::SDN::Fabrics;

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

my sub is_internal_wireguard_node {
    my ($node) = @_;
    return $node->{protocol} eq 'wireguard' && $node->{role} eq 'internal';
}

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

                if (is_internal_wireguard_node($param) && $param->{interfaces}) {
                    my $private_keys = PVE::Network::SDN::WireGuard::private_keys();

                    my @parsed_interfaces = map {
                        PVE::RS::SDN::Fabrics::parse_wireguard_create_interface($_)
                    } $param->{interfaces}->@*;

                    my @interfaces;
                    for my $interface (@parsed_interfaces) {
                        $interface->{public_key} =
                            $private_keys->upsert($param->{node_id}, $interface->{name});
                        push @interfaces,
                            PVE::RS::SDN::Fabrics::print_wireguard_interface($interface);
                    }

                    $param->{interfaces} = \@interfaces;
                    $config->add_node($param);

                    eval { PVE::Network::SDN::WireGuard::write_private_keys($private_keys); };
                    die "could not save private key config: $@\n" if $@;

                    eval { PVE::Network::SDN::Fabrics::write_config($config); };
                    if (my $err = $@) {
                        for my $interface (@parsed_interfaces) {
                            $private_keys->delete($param->{node_id}, $interface->{name});
                        }

                        eval { PVE::Network::SDN::WireGuard::write_private_keys($private_keys) };
                        warn "could not roll back private key config: $@\n" if $@;

                        die $err;
                    }
                } else {
                    $config->add_node($param);
                    PVE::Network::SDN::Fabrics::write_config($config);
                }
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

                my $old_node = $config->get_node($fabric_id, $node_id);

                if ($old_node->{protocol} eq 'wireguard') {
                    if (defined($param->{role}) && $param->{role} ne $old_node->{role}) {
                        die "cannot change role of existing WireGuard node\n";
                    }
                    # required so rust can parse the proper wireguard node
                    # variant
                    $param->{role} = $old_node->{role};
                }

                if (is_internal_wireguard_node($param)) {
                    my $private_keys = PVE::Network::SDN::WireGuard::private_keys();

                    my %new_interfaces = map {
                        my $interface =
                            PVE::RS::SDN::Fabrics::parse_wireguard_create_interface($_);
                        $interface->{name} => $interface
                    } $param->{interfaces}->@*;

                    my %old_interfaces = map {
                        my $interface = PVE::RS::SDN::Fabrics::parse_wireguard_interface($_);
                        $interface->{name} => $interface
                    } $old_node->{interfaces}->@*;

                    my @interfaces;
                    for my $interface_name (keys %new_interfaces) {
                        my $interface = $new_interfaces{$interface_name};
                        # always derive the public key from the stored private
                        # key, never trust a user-supplied value, otherwise an
                        # update could let the public key in fabrics.cfg drift
                        # away from the matching private key in wg-keys.cfg
                        $interface->{public_key} =
                            $private_keys->upsert($node_id, $interface_name);
                        push @interfaces,
                            PVE::RS::SDN::Fabrics::print_wireguard_interface($interface);
                    }
                    $param->{interfaces} = \@interfaces;

                    $config->update_node($fabric_id, $node_id, $param);

                    eval { PVE::Network::SDN::WireGuard::write_private_keys($private_keys); };
                    die "could not save private key config: $@\n" if $@;

                    eval { PVE::Network::SDN::Fabrics::write_config($config); };

                    if (my $err = $@) {
                        for my $interface (values %new_interfaces) {
                            $private_keys->delete($node_id, $interface->{name})
                                if !exists($old_interfaces{ $interface->{name} });
                        }

                        eval { PVE::Network::SDN::WireGuard::write_private_keys($private_keys) };
                        warn "could not roll back private key config: $@\n" if $@;

                        die $err;
                    }

                    # purge keys for interfaces the update removed; the entries
                    # would otherwise linger in cluster-replicated wg-keys.cfg
                    # until the next SDN apply runs cleanup_private_keys
                    my @removed_interfaces =
                        grep { !exists($new_interfaces{$_}) } keys %old_interfaces;
                    if (@removed_interfaces) {
                        for my $interface_name (@removed_interfaces) {
                            $private_keys->delete($node_id, $interface_name);
                        }
                        eval { PVE::Network::SDN::WireGuard::write_private_keys($private_keys) };
                        warn "could not purge orphan private keys: $@\n" if $@;
                    }
                } else {
                    $config->update_node($fabric_id, $node_id, $param);
                    PVE::Network::SDN::Fabrics::write_config($config);
                }
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

                my $old_node = $config->get_node($fabric_id, $node_id);

                $config->delete_node($fabric_id, $node_id);
                PVE::Network::SDN::Fabrics::write_config($config);

                # purge private keys this node owned so they don't linger in
                # the cluster-replicated wg-keys.cfg until the next SDN apply
                if (is_internal_wireguard_node($old_node) && $old_node->{interfaces}) {
                    my $private_keys = PVE::Network::SDN::WireGuard::private_keys();
                    for my $iface_propstr ($old_node->{interfaces}->@*) {
                        my $iface =
                            PVE::RS::SDN::Fabrics::parse_wireguard_interface($iface_propstr);
                        $private_keys->delete($node_id, $iface->{name});
                    }
                    eval { PVE::Network::SDN::WireGuard::write_private_keys($private_keys) };
                    warn "could not purge private keys after node delete: $@\n" if $@;
                }
            },
            "deleting node failed",
            $lock_token,
        );
    },
});

1;
