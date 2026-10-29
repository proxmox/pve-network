package PVE::Network::SDN::RouteMaps;

use strict;
use warnings;

use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file cfs_write_file);
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::INotify;
use PVE::Network::SDN;
use PVE::RS::SDN::RouteMaps;

PVE::JSONSchema::register_format(
    'pve-sdn-route-map-id',
    sub {
        my ($id, $noerr) = @_;

        if ($id =~ m/^(pve_.*|MAP_VTEP_IN|MAP_VTEP_OUT|correct_src)\z/) {
            return undef if $noerr;
            die "route map ID '$id' is currently reserved and cannot be used\n";
        }

        if ($id !~ m/^[a-zA-Z0-9][a-zA-Z0-9-_]{0,30}[a-zA-Z0-9]?\z/i) {
            return undef if $noerr;
            die "route map ID '$id' contains illegal characters\n";
        }

        return $id;
    },
);

our $ROUTE_MAP_MATCH_FORMAT = {
    key => {
        type => 'string',
        enum => [
            'route-type',
            'vni',
            'ip-address-prefix-list',
            'ip6-address-prefix-list',
            'ip-next-hop-prefix-list',
            'ip6-next-hop-prefix-list',
            'ip-next-hop-address',
            'ip6-next-hop-address',
            'metric',
            'local-preference',
            'peer',
            'tag',
        ],
    },
    value => {
        type => 'string',
        optional => 1,
        description => 'Value that the field <key> should be matched on.',
        format_description => '<key-dependent>',
        pattern => '\S+',
    },
};

PVE::JSONSchema::register_standard_option(
    'pve-sdn-route-map-id',
    {
        description => "The SDN route map identifier",
        type => 'string',
        format => 'pve-sdn-route-map-id',
    },
);

PVE::JSONSchema::register_standard_option(
    'pve-sdn-route-map-order',
    {
        description => 'The index of this route map entry',
        type => 'integer',
        minimum => 0,
        maximum => 65535,
    },
);

cfs_register_file(
    'sdn/route-maps.cfg', \&parse_route_maps_config, \&write_route_maps_config,
);

sub parse_route_maps_config {
    my ($filename, $raw) = @_;
    return $raw // '';
}

sub write_route_maps_config {
    my ($filename, $config) = @_;
    return $config // '';
}

sub config {
    my ($running) = @_;

    if ($running) {
        my $running_config = PVE::Network::SDN::running_config();

        # if the config hasn't yet been applied after the introduction of
        # route maps then the key does not exist in the running config so we
        # default to an empty hash
        my $route_maps_config = $running_config->{'route-maps'}->{ids} // {};
        return PVE::RS::SDN::RouteMaps->running_config($route_maps_config);
    }

    my $route_map_config = cfs_read_file("sdn/route-maps.cfg");
    return PVE::RS::SDN::RouteMaps->config($route_map_config);
}

sub write_config {
    my ($config) = @_;
    cfs_write_file("sdn/route-maps.cfg", $config->to_raw(), 1);
}

sub check_references {
    my ($route_map_id) = @_;

    my $controller_config = PVE::Network::SDN::Controllers::config();

    for my $controller_id (keys $controller_config->{ids}->%*) {
        my $controller = $controller_config->{ids}->{$controller_id};

        if ($controller->{'route-map-in'}) {
            die "route map $route_map_id still referenced by controller $controller_id"
                if $controller->{'route-map-in'} eq $route_map_id;
        }

        if ($controller->{'route-map-out'}) {
            die "route map $route_map_id still referenced by controller $controller_id"
                if $controller->{'route-map-out'} eq $route_map_id;
        }
    }

    my $fabrics = PVE::Network::SDN::Fabrics::config()->list_fabrics();
    for my $fabric_id (keys $fabrics->%*) {
        my $fabric = $fabrics->{$fabric_id};

        if ($fabric->{route_map_in}) {
            die "route map $route_map_id still referenced by fabric $fabric_id"
                if $fabric->{route_map_in} eq $route_map_id;
        }

        if ($fabric->{route_map_out}) {
            die "route map $route_map_id still referenced by fabric $fabric_id"
                if $fabric->{route_map_out} eq $route_map_id;
        }
    }
}

sub route_map_properties {
    my ($update) = @_;

    my $properties = {
        'route-map-id' => get_standard_option('pve-sdn-route-map-id'),
        'order' => get_standard_option('pve-sdn-route-map-order'),
        digest => get_standard_option('pve-config-digest'),
        action => {
            description => 'Matching policy of a route map entry.',
            type => 'string',
            enum => ['permit', 'deny'],
            optional => $update,
        },
        set => {
            type => 'array',
            items => {
                type => 'string',
                format => {
                    key => {
                        type => 'string',
                        enum => [
                            'ip-next-hop-peer-address',
                            'ip-next-hop',
                            'ip-next-hop-unchanged',
                            'ip6-next-hop-peer-address',
                            'ip6-next-hop-prefer-global',
                            'ip6-next-hop',
                            'local-preference',
                            'tag',
                            'weight',
                            'metric',
                            'src',
                        ],
                    },
                    value => {
                        type => 'string',
                        optional => 1,
                        description => 'Value that the field <key> should be set to.',
                        format_description => '<key-dependent>',
                        pattern => '\S+',
                    },
                },
            },
            optional => 1,
        },
        match => {
            type => 'array',
            items => {
                type => 'string',
                format => $ROUTE_MAP_MATCH_FORMAT,
            },
            optional => 1,
        },
        'exit-action' => {
            type => 'string',
            format => {
                key => {
                    type => 'string',
                    enum => [
                        'on-match-goto', 'on-match-next', 'continue',
                    ],
                },
                value => get_standard_option('pve-sdn-route-map-order', {
                        optional => 1,
                }),
            },
            optional => 1,
        },
        call => get_standard_option('pve-sdn-route-map-id', {
                optional => 1,
        }),
    };

    if ($update) {
        $properties->{delete} = {
            type => 'array',
            optional => 1,
            items => {
                type => 'string',
                enum => ['set', 'match', 'call', 'exit-action'],
            },
        };
    }

    return $properties;
}

=head3 api_validate_entry_property_references($entry, $privs, $rpcenv, $authuser)

For properties that reference another SDN entity in C<$entry> this function
checks if they exist and if the C<$authuser> has the permissions in C<$privs>
for that entity.

If C<$authuser> and C<$rpcenv> are not given, they are obtained via
C<PVE::RPCEnvironment::get>.

=cut

sub api_validate_entry_property_references {
    my ($entry, $privs, $rpcenv, $authuser) = @_;

    $rpcenv = PVE::RPCEnvironment::get() if !defined($rpcenv);
    $authuser = $rpcenv->get_user() if !defined($authuser);

    my $prefix_list_config = PVE::Network::SDN::PrefixLists::config();
    my $route_map_config = PVE::Network::SDN::RouteMaps::config();

    if (my $route_map = $entry->{'call'}) {
        raise_param_exc({ call => "could not find route map $route_map" })
            if !scalar($route_map_config->list_route_map($route_map));

        raise_param_exc({ call => "could not find route map $route_map" })
            if !$rpcenv->check_any($authuser, "/sdn/route-maps/$route_map", $privs, 1);
    }

    if (my $match_statements = $entry->{'match'}) {
        for my $match_statement ($match_statements->@*) {
            my $parsed_statement = PVE::RS::SDN::RouteMaps::parse_match($match_statement);

            if ($parsed_statement->{key} =~
                m/\A(?:ip-address-prefix-list|ip6-address-prefix-list|ip-next-hop-prefix-list|ip6-next-hop-prefix-list)\z/
            ) {
                raise_param_exc({
                    match => "could not find prefix list $parsed_statement->{value}" })
                    if !$prefix_list_config->get($parsed_statement->{value});

                raise_param_exc({
                    match => "could not find prefix list $parsed_statement->{value}" })
                    if !$rpcenv->check_any(
                        $authuser,
                        "/sdn/prefix-lists/$parsed_statement->{value}",
                        $privs,
                        1,
                    );
            }
        }
    }
}

1;
