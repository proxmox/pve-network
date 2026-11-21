package PVE::API2::Network::SDN::Fabrics::Fabric;

use strict;
use warnings;

use PVE::Network::SDN;
use PVE::Network::SDN::Controllers;
use PVE::Network::SDN::Fabrics;
use PVE::Network::SDN::Zones;

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

sub validate_fabric_zone {
    my ($fabric, $config) = @_;

    my $protocol = $fabric->{protocol} // '';
    if ($protocol eq 'bgp' && !$fabric->{zone}) {
        my $controller_cfg = PVE::Network::SDN::Controllers::config();
        for my $controller_id (keys %{ $controller_cfg->{ids} // {} }) {
            my $controller = $controller_cfg->{ids}->{$controller_id};
            if ($controller->{type} eq 'bgp') {
                die "cannot configure a BGP fabric while BGP controller '$controller_id' exists:"
                    . " both target the default-VRF BGP router\n";
            }
        }
    }

    my $zone_id = $fabric->{zone};
    return if !$zone_id;

    raise_param_exc({ zone => 'VRF zones are only supported for BGP and OSPF fabrics' })
        if $protocol !~ /^(?:bgp|ospf)$/;

    my $zone = PVE::Network::SDN::Zones::get_zone($zone_id);

    raise_param_exc({ zone => "zone '$zone_id' does not exist" }) if !$zone;
    raise_param_exc({ zone => "zone '$zone_id' is not a simple zone" })
        if $zone->{type} ne 'simple';
    raise_param_exc({ zone => "zone '$zone_id' is configured to use the default VRF" })
        if !$zone->{'dedicated-vrf'};

    if ($config) {
        PVE::Network::SDN::Fabrics::assert_fabric_nodes_in_zone(
            $config, $fabric->{id}, $zone_id, $zone,
        );
    }
}

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    permissions => {
        description =>
            "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/sdn/fabrics/<fabric>'",
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
            type => 'object',
            properties => PVE::Network::SDN::Fabrics::fabric_list_properties(),
        },
        links => [{ rel => 'child', href => "{id}" }],
    },
    code => sub {
        my ($param) = @_;

        my $pending = extract_param($param, 'pending');
        my $running = extract_param($param, 'running');

        my $digest;
        my $fabrics;

        if ($pending) {
            my $current_config = PVE::Network::SDN::Fabrics::config();
            my $running_config = PVE::Network::SDN::Fabrics::config(1);

            my $pending_fabrics = PVE::Network::SDN::pending_config(
                { fabrics => { ids => $running_config->list_fabrics() } },
                { ids => $current_config->list_fabrics() },
                'fabrics',
            );

            $digest = $current_config->digest();
            $fabrics = $pending_fabrics->{ids};
        } elsif ($running) {
            $fabrics = PVE::Network::SDN::Fabrics::config(1)->list_fabrics();
        } else {
            my $current_config = PVE::Network::SDN::Fabrics::config();

            $digest = $current_config->digest();
            $fabrics = $current_config->list_fabrics();
        }

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $privs = ['SDN.Audit', 'SDN.Allocate'];

        my @res;
        for my $id (keys %$fabrics) {
            next if !$rpcenv->check_any($authuser, "/sdn/fabrics/$id", $privs, 1);
            $fabrics->{$id}->{digest} = $digest if $digest;
            push @res, $fabrics->{$id};
        }

        return \@res;
    },
});

__PACKAGE__->register_method({
    name => 'get_fabric',
    path => '{id}',
    method => 'GET',
    description => 'Update a fabric',
    permissions => {
        check => ['perm', '/sdn/fabrics/{id}', ['SDN.Audit', 'SDN.Allocate'], any => 1],
    },
    parameters => {
        properties => {
            id => get_standard_option('pve-sdn-fabric-id'),
        },
    },
    returns => {
        type => 'object',
        properties => PVE::Network::SDN::Fabrics::fabric_properties(0),
    },
    code => sub {
        my ($param) = @_;

        my $id = extract_param($param, 'id');

        my $config = PVE::Network::SDN::Fabrics::config();

        my $fabric = $config->get_fabric($id);
        $fabric->{digest} = $config->digest();

        return $fabric;
    },
});

__PACKAGE__->register_method({
    name => 'add_fabric',
    path => '',
    method => 'POST',
    description => 'Add a fabric',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/fabrics', ['SDN.Allocate']],
        description => "Assigning a VRF zone additionally requires 'SDN.Use' or 'SDN.Allocate'"
            . " on '/sdn/zones/<zone>'.",
    },
    parameters => {
        properties => PVE::Network::SDN::Fabrics::fabric_properties(0),
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

                my $privs = ['SDN.Use', 'SDN.Allocate'];
                PVE::Network::SDN::Fabrics::api_validate_property_references($param, $privs);

                validate_fabric_zone($param);

                $config->add_fabric($param);
                PVE::Network::SDN::Fabrics::write_config($config);
            },
            "adding fabric failed",
            $lock_token,
        );
    },
});

__PACKAGE__->register_method({
    name => 'update_fabric',
    path => '{id}',
    method => 'PUT',
    description => 'Update a fabric',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/fabrics/{id}', ['SDN.Allocate']],
    },
    parameters => {
        properties => PVE::Network::SDN::Fabrics::fabric_properties(1),
    },
    returns => {
        type => 'null',
    },
    code => sub {
        my ($param) = @_;
        my $lock_token = extract_param($param, 'lock-token');

        PVE::Network::SDN::lock_sdn_config(
            sub {
                my $id = extract_param($param, 'id');

                my $config = PVE::Network::SDN::Fabrics::config();

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                my $privs = ['SDN.Use', 'SDN.Allocate'];
                PVE::Network::SDN::Fabrics::api_validate_property_references($param, $privs);

                my $old_zone = $config->get_fabric($id)->{zone} // '';
                raise_param_exc({ zone => "cannot change the VRF zone of an existing fabric" })
                    if defined($param->{zone}) && $param->{zone} ne $old_zone;

                $config->update_fabric($id, $param);
                validate_fabric_zone($config->get_fabric($id), $config);
                PVE::Network::SDN::Fabrics::write_config($config);
            },
            "updating fabric failed",
            $lock_token,
        );
    },
});

__PACKAGE__->register_method({
    name => 'delete_fabric',
    path => '{id}',
    method => 'DELETE',
    description => 'Add a fabric',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/fabrics/{id}', ['SDN.Allocate']],
    },
    parameters => {
        properties => {
            id => get_standard_option('pve-sdn-fabric-id'),
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
                my $id = extract_param($param, 'id');

                my $rpcenv = PVE::RPCEnvironment::get();
                my $authuser = $rpcenv->get_user();

                my $config = PVE::Network::SDN::Fabrics::config();

                my $nodes = $config->list_nodes_fabric($id);

                for my $node_id (keys %$nodes) {
                    if (!$rpcenv->check_any($authuser, "/nodes/$node_id", ['Sys.Modify'], 1)) {
                        die "permission check failed: missing 'Sys.Modify' on node $node_id";
                    }
                }

                # check if this fabric is used in the evpn controller
                my $controller_cfg = PVE::Network::SDN::Controllers::config();
                for my $key (keys %{ $controller_cfg->{ids} }) {
                    my $controller = $controller_cfg->{ids}->{$key};
                    if (
                        $controller->{type} eq "evpn"
                        && $controller->{fabric} eq $id
                    ) {
                        die "this fabric is still used in the EVPN controller \"$key\"";
                    }
                }

                # check if this fabric is used in a vxlan zone
                my $zone_cfg = PVE::Network::SDN::Zones::config();
                for my $key (keys %{ $zone_cfg->{ids} }) {
                    my $zone = $zone_cfg->{ids}->{$key};
                    if ($zone->{type} eq "vxlan" && $zone->{fabric} eq $id) {
                        die "this fabric is still used in the VXLAN zone \"$key\"";
                    }
                }

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                $config->delete_fabric($id);
                PVE::Network::SDN::Fabrics::write_config($config);
            },
            "deleting fabric failed",
            $lock_token,
        );
    },
});

1;
