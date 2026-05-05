package PVE::API2::Network::SDN::RouteMaps::RouteMapEntry;

use strict;
use warnings;

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN::RouteMaps;
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'get_route_map_entry',
    path => '',
    method => 'GET',
    permissions => {
        check =>
            ['perm', '/sdn/route-maps/{route-map-id}', ['SDN.Audit', 'SDN.Allocate'], any => 1],
    },
    description => "Get Route Map Entry",
    parameters => {
        properties => {
            'route-map-id' => get_standard_option('pve-sdn-route-map-id'),
            'order' => get_standard_option('pve-sdn-route-map-order'),
        },
    },
    returns => {
        type => "object",
        properties => PVE::Network::SDN::RouteMaps::route_map_properties(0),
    },
    code => sub {
        my ($param) = @_;

        my $route_map_id = extract_param($param, 'route-map-id');
        my $order = extract_param($param, 'order');

        my $route_map_entry =
            PVE::Network::SDN::RouteMaps::config()->get($route_map_id, $order);

        raise_param_exc({ 'route-map-id' => "${route_map_id}_${order} doesn't exist" })
            if !$route_map_entry;

        return $route_map_entry;
    },
});

__PACKAGE__->register_method({
    name => 'update_route_map_entry',
    path => '',
    method => 'PUT',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/route-maps/{route-map-id}', ['SDN.Allocate']],
    },
    description => "Update Route Map Entry",
    parameters => {
        properties => {
            digest => get_standard_option('pve-config-digest'),
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
            PVE::Network::SDN::RouteMaps::route_map_properties(1)->%*,
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
                my $config = PVE::Network::SDN::RouteMaps::config();

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                my $route_map_id = extract_param($param, 'route-map-id');
                my $order = extract_param($param, 'order');
                my $delete = extract_param($param, 'delete');

                $config->update($route_map_id, $order, $param, $delete);
                PVE::Network::SDN::RouteMaps::write_config($config);
            },
            "updating route map entry failed",
            $lock_token,
        );

        return;
    },
});

__PACKAGE__->register_method({
    name => 'delete_route_map_entry',
    path => '',
    method => 'DELETE',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/route-maps/{route-map-id}', ['SDN.Allocate']],
    },
    description => "Delete Route Map Entry",
    parameters => {
        properties => {
            'route-map-id' => get_standard_option('pve-sdn-route-map-id'),
            'order' => get_standard_option('pve-sdn-route-map-order'),
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
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
                my $config = PVE::Network::SDN::RouteMaps::config();

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                my $route_map_id = extract_param($param, 'route-map-id');
                my $order = extract_param($param, 'order');

                $config->delete($route_map_id, $order);

                my $remaining_entries = $config->list_route_map($route_map_id);
                PVE::Network::SDN::RouteMaps::check_references($route_map_id)
                    if !$remaining_entries->%*;

                PVE::Network::SDN::RouteMaps::write_config($config);
            },
            "deleting route map entry failed",
            $lock_token,
        );

        return;
    },
});

1;
