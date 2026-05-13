package PVE::API2::Network::SDN::RouteMaps;

use strict;
use warnings;

use PVE::API2::Network::SDN::RouteMaps::RouteMapEntries;
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN::RouteMaps;
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::RouteMaps::RouteMapEntries",
    path => 'entries',
});

__PACKAGE__->register_method({
    name => 'list_route_maps',
    path => '',
    method => 'GET',
    permissions => {
        description =>
            "Only returns route maps where you have 'SDN.Audit' or 'SDN.Allocate' permissions.",
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
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                id => get_standard_option('pve-sdn-route-map-id'),
            },
        },
        links => [{ rel => 'child', href => "entries/{id}" }],
    },
    code => sub {
        my ($param) = @_;

        my $running = extract_param($param, 'running');
        my $route_maps = PVE::Network::SDN::RouteMaps::config($running)->list_route_maps();

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $route_map_privs = ['SDN.Audit', 'SDN.Allocate'];

        my @res;
        for my $route_map ($route_maps->@*) {
            next
                if !$rpcenv->check_any(
                    $authuser,
                    "/sdn/route-maps/$route_map->{id}",
                    $route_map_privs,
                    1,
                );

            push @res, $route_map;
        }

        return \@res;
    },
});

1;
