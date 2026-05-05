package PVE::API2::Network::SDN::RouteMaps::RouteMap;

use strict;
use warnings;

use PVE::API2::Network::SDN::RouteMaps::RouteMapEntry;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Exception qw(raise_param_exc);
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::RouteMaps::RouteMapEntry",
    path => '{order}',
});

__PACKAGE__->register_method({
    name => 'list_route_map_entries',
    path => '',
    method => 'GET',
    permissions => {
        check =>
            ['perm', '/sdn/route-maps/{route-map-id}', ['SDN.Audit', 'SDN.Allocate'], any => 1],
    },
    description => "List all entries for a given Route Map",
    parameters => {
        properties => {
            'route-map-id' => get_standard_option('pve-sdn-route-map-id'),
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
        links => [{ rel => 'child', href => "{order}" }],
    },
    code => sub {
        my ($param) = @_;

        my $pending = extract_param($param, 'pending');
        my $running = extract_param($param, 'running');
        my $route_map_id = extract_param($param, 'route-map-id');

        my $digest;
        my $route_map_entries;

        if ($pending) {
            my $current_config = PVE::Network::SDN::RouteMaps::config();
            my $running_config = PVE::Network::SDN::RouteMaps::config(1);

            my $pending_route_maps = PVE::Network::SDN::pending_config(
                { 'route-maps' => { ids => $running_config->list_route_map($route_map_id) } },
                { ids => $current_config->list_route_map($route_map_id) },
                'route-maps',
            );

            $digest = $current_config->digest();
            $route_map_entries = $pending_route_maps->{ids};
        } elsif ($running) {
            $route_map_entries =
                PVE::Network::SDN::RouteMaps::config(1)->list_route_map($route_map_id);
        } else {
            my $current_config = PVE::Network::SDN::RouteMaps::config();

            $digest = $current_config->digest();
            $route_map_entries = $current_config->list_route_map($route_map_id);
        }

        my @res;
        for my $entry_id (sort keys $route_map_entries->%*) {
            $route_map_entries->{$entry_id}->{digest} = $digest if $digest;
            push @res, $route_map_entries->{$entry_id};
        }

        return \@res;
    },
});

1;
