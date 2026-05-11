package PVE::API2::Network::SDN::PrefixLists::PrefixList;

use strict;
use warnings;

use PVE::API2::Network::SDN::PrefixLists::PrefixListEntry;
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN::PrefixLists;
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::PrefixLists::PrefixListEntry",
    path => 'entries',
});

__PACKAGE__->register_method({
    name => 'get_prefix_list',
    path => '',
    method => 'GET',
    permissions => {
        check => ['perm', '/sdn/prefix-lists/{id}', ['SDN.Audit']],
    },
    description => "Get Prefix List",
    parameters => {
        properties => {
            id => get_standard_option('pve-sdn-prefix-list-id'),
        },
    },
    returns => {
        type => "object",
        properties => {},
    },
    code => sub {
        my ($param) = @_;

        my $prefix_list_id = extract_param($param, 'id');
        my $prefix_list_entry = PVE::Network::SDN::PrefixLists::config()->get($prefix_list_id);

        raise_param_exc({ 'id' => "$prefix_list_id doesn't exist" })
            if !$prefix_list_entry;

        return $prefix_list_entry;
    },
});

__PACKAGE__->register_method({
    name => 'update_prefix_list',
    path => '',
    method => 'PUT',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/prefix-lists/{id}', ['SDN.Allocate']],
    },
    description => "Update Prefix List",
    parameters => {
        properties => {
            digest => get_standard_option('pve-config-digest'),
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
            PVE::Network::SDN::PrefixLists::prefix_list_properties(1)->%*,
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
                my $config = PVE::Network::SDN::PrefixLists::config();

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                my $prefix_list_id = extract_param($param, 'id');
                my $delete = extract_param($param, 'delete');

                $config->update($prefix_list_id, $param, $delete);
                PVE::Network::SDN::PrefixLists::write_config($config);
            },
            "updating prefix list failed",
            $lock_token,
        );

        return;
    },
});

__PACKAGE__->register_method({
    name => 'delete_prefix_list',
    path => '',
    method => 'DELETE',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/prefix-lists/{id}', ['SDN.Allocate']],
    },
    description => "Delete Prefix List",
    parameters => {
        properties => {
            id => get_standard_option('pve-sdn-prefix-list-id'),
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
                my $config = PVE::Network::SDN::PrefixLists::config();

                my $digest = extract_param($param, 'digest');
                PVE::Tools::assert_if_modified($config->digest(), $digest) if $digest;

                my $prefix_list_id = extract_param($param, 'id');
                PVE::Network::SDN::PrefixLists::check_references($prefix_list_id);

                $config->delete($prefix_list_id);
                PVE::Network::SDN::PrefixLists::write_config($config);
            },
            "deleting prefix list failed",
            $lock_token,
        );

        return;
    },
});

1;
