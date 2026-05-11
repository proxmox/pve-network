package PVE::Network::SDN::PrefixLists;

use strict;
use warnings;

use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file cfs_write_file);
use PVE::JSONSchema qw(get_standard_option);
use PVE::INotify;
use PVE::Network::SDN;
use PVE::Network::SDN::RouteMaps;
use PVE::RS::SDN::PrefixLists;
use PVE::RS::SDN::Fabrics;

PVE::JSONSchema::register_format(
    'pve-sdn-prefix-list-id',
    sub {
        my ($id, $noerr) = @_;

        if ($id =~ m/^(only_default|only_default_v6|loopbacks_ips)$/) {
            return undef if $noerr;
            die "prefix list ID '$id' is currently reserved and cannot be used\n";
        }

        if ($id !~ m/^[a-zA-Z0-9][a-zA-Z0-9-_]{0,30}[a-zA-Z0-9]?$/i) {
            return undef if $noerr;
            die "prefix list ID '$id' contains illegal characters\n";
        }

        return $id;
    },
);

PVE::JSONSchema::register_standard_option(
    'pve-sdn-prefix-list-id',
    {
        description => "The SDN prefix list identifier",
        type => 'string',
        format => 'pve-sdn-prefix-list-id',
    },
);

cfs_register_file(
    'sdn/prefix-lists.cfg', \&parse_prefix_lists_config, \&write_prefix_lists_config,
);

sub parse_prefix_lists_config {
    my ($filename, $raw) = @_;
    return $raw // '';
}

sub write_prefix_lists_config {
    my ($filename, $config) = @_;
    return $config // '';
}

sub config {
    my ($running) = @_;

    if ($running) {
        my $running_config = PVE::Network::SDN::running_config();

        # if the config hasn't yet been applied after the introduction of
        # prefix lists then the key does not exist in the running config so we
        # default to an empty hash
        my $prefix_lists_config = $running_config->{'prefix-lists'}->{ids} // {};
        return PVE::RS::SDN::PrefixLists->running_config($prefix_lists_config);
    }

    my $prefix_lists_config = cfs_read_file("sdn/prefix-lists.cfg");
    return PVE::RS::SDN::PrefixLists->config($prefix_lists_config);
}

sub write_config {
    my ($config) = @_;
    cfs_write_file("sdn/prefix-lists.cfg", $config->to_raw(), 1);
}

sub check_references {
    my ($prefix_list_id) = @_;

    my $fabrics = PVE::Network::SDN::Fabrics::config()->list_fabrics();
    for my $fabric_id (keys $fabrics->%*) {
        my $fabric = $fabrics->{$fabric_id};

        if ($fabric->{route_filter}) {
            die "prefix list $prefix_list_id is still referenced by fabric $fabric_id"
                if $fabric->{route_filter} eq $prefix_list_id;
        }
    }

    my $route_map_entries = PVE::Network::SDN::RouteMaps::config()->list();
    for my $route_map_entry (values $route_map_entries->%*) {
        for my $match_action_property_string ($route_map_entry->{match}->@*) {
            my $match_action = PVE::JSONSchema::parse_property_string(
                $PVE::Network::SDN::RouteMaps::ROUTE_MAP_MATCH_FORMAT,
                $match_action_property_string,
            );

            next if $match_action->{key} !~ m/^(.*)-prefix-list$/;

            die
                "prefix list $prefix_list_id is still referenced by route map entry $route_map_entry->{'route-map-id'} #$route_map_entry->{'order'}"
                if $match_action->{value} eq $prefix_list_id;
        }
    }
}

sub prefix_list_entry_properties {
    my ($update, $standalone) = @_;

    my $properties = {
        action => {
            type => 'string',
            enum => ['permit', 'deny'],
            optional => $update,
        },
        prefix => {
            type => 'string',
            format => 'CIDR',
            optional => $update,
        },
        le => {
            type => 'integer',
            minimum => 0,
            maximum => 128,
            optional => 1,
        },
        ge => {
            type => 'integer',
            minimum => 0,
            maximum => 128,
            optional => 1,
        },
        seq => {
            type => 'integer',
            minimum => 1,
            maximum => 2**32 - 1,
            optional => 1,
        },
    };

    if ($update && $standalone) {
        $properties->{delete} = {
            type => 'array',
            optional => 1,
            items => {
                type => 'string',
                enum => ['le', 'ge', 'seq'],
            },
        };
    }

    return $properties;
}

sub prefix_list_properties {
    my ($update) = @_;

    my $properties = {
        id => get_standard_option('pve-sdn-prefix-list-id'),
        digest => get_standard_option('pve-config-digest'),
        entries => {
            type => 'array',
            optional => 1,
            items => {
                type => 'string',
                format => prefix_list_entry_properties($update, 0),
            },
        },
    };

    if ($update) {
        $properties->{delete} = {
            type => 'array',
            optional => 1,
            items => {
                type => 'string',
                enum => ['entries'],
            },
        };
    }

    return $properties;
}

1;
