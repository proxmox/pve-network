package PVE::API2::Network::SDN::RouteMaps;

use strict;
use warnings;

use PVE::API2::Network::SDN::RouteMaps::RouteMap;
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN::RouteMaps;
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::RouteMaps::RouteMap",
    path => '{route-map-id}',
});

__PACKAGE__->register_method({
    name => 'list_route_maps',
    path => '',
    method => 'GET',
    permissions => {
        description =>
            "Only returns route map entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions.",
        user => 'all',
    },
    description => "List Route Maps",
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
            properties => PVE::Network::SDN::RouteMaps::route_map_properties(0),
        },
        links => [{ rel => 'child', href => "{route-map-id}" }],
    },
    code => sub {
        my ($param) = @_;

        my $pending = extract_param($param, 'pending');
        my $running = extract_param($param, 'running');

        my $digest;
        my $route_maps;

        if ($pending) {
            my $current_config = PVE::Network::SDN::RouteMaps::config();
            my $running_config = PVE::Network::SDN::RouteMaps::config(1);

            my $pending_route_maps = PVE::Network::SDN::pending_config(
                { 'route-maps' => { ids => $running_config->list() } },
                { ids => $current_config->list() },
                'route-maps',
            );

            $digest = $current_config->digest();
            $route_maps = $pending_route_maps->{ids};
        } elsif ($running) {
            $route_maps = PVE::Network::SDN::RouteMaps::config(1)->list();
        } else {
            my $current_config = PVE::Network::SDN::RouteMaps::config();

            $digest = $current_config->digest();
            $route_maps = $current_config->list();
        }

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $route_map_privs = ['SDN.Audit', 'SDN.Allocate'];

        my @res;
        for my $route_map_id (sort keys $route_maps->%*) {
            next
                if !$rpcenv->check_any($authuser, "/sdn/route-maps/$route_map_id",
                    $route_map_privs, 1);
            $route_maps->{$route_map_id}->{digest} = $digest if $digest;
            push @res, $route_maps->{$route_map_id};
        }

        return \@res;
    },
});

__PACKAGE__->register_method({
    name => 'create_route_map_entry',
    path => '',
    method => 'POST',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/route-maps', ['SDN.Allocate']],
    },
    description => "Create Route Map entry",
    parameters => {
        properties => {
            digest => get_standard_option('pve-config-digest'),
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
            PVE::Network::SDN::RouteMaps::route_map_properties(0)->%*,
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

                $config->create($param);
                PVE::Network::SDN::RouteMaps::write_config($config);
            },
            "creating route map entry failed",
            $lock_token,
        );

        return;
    },
});

1;
