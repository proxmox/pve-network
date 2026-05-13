package PVE::API2::Network::SDN::PrefixLists::PrefixListEntry;

use strict;
use warnings;

use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN::PrefixLists;
use PVE::Tools qw(extract_param);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'get_prefix_list_entries',
    path => '',
    method => 'GET',
    permissions => {
        check => ['perm', '/sdn/prefix-lists/{id}', ['SDN.Audit']],
    },
    description => "List Prefix List Entries",
    parameters => {
        properties => {
            id => get_standard_option('pve-sdn-prefix-list-id'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {},
        },
        links => [{ rel => 'child', href => "{seq}" }],
    },
    code => sub {
        my ($param) = @_;

        my $prefix_list_id = extract_param($param, 'id');
        return PVE::Network::SDN::PrefixLists::config()->list_entries($prefix_list_id);
    },
});

__PACKAGE__->register_method({
    name => 'get_prefix_list_entry',
    path => '{url_seq}',
    method => 'GET',
    permissions => {
        check => ['perm', '/sdn/prefix-lists/{id}', ['SDN.Audit']],
    },
    description => "Get Prefix List Entry",
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
        my $seq_nr = extract_param($param, 'url_seq');
        my $prefix_list_entry =
            PVE::Network::SDN::PrefixLists::config()->get_entry($prefix_list_id, $seq_nr);

        raise_param_exc({
            'id' => "entry $seq_nr in prefix list $prefix_list_id doesn't exist" })
            if !$prefix_list_entry;

        return $prefix_list_entry;
    },
});

__PACKAGE__->register_method({
    name => 'update_prefix_list_entry',
    path => '{url_seq}',
    method => 'PUT',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/prefix-lists/{id}', ['SDN.Allocate']],
    },
    description => "Update Prefix List Entry",
    parameters => {
        properties => {
            digest => get_standard_option('pve-config-digest'),
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
            PVE::Network::SDN::PrefixLists::prefix_list_entry_properties(1, 1)->%*,
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
                my $old_seq = extract_param($param, 'url_seq');
                my $delete = extract_param($param, 'delete');

                $config->update_entry($prefix_list_id, $old_seq, $param, $delete);
                PVE::Network::SDN::PrefixLists::write_config($config);
            },
            "updating prefix list entry failed",
            $lock_token,
        );

        return;
    },
});

__PACKAGE__->register_method({
    name => 'delete_prefix_list_entry',
    path => '{url_seq}',
    method => 'DELETE',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/prefix-lists/{id}', ['SDN.Allocate']],
    },
    description => "Delete Prefix List Entry",
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
                my $seq_nr = extract_param($param, 'url_seq');

                $config->delete_entry($prefix_list_id, $seq_nr);
                PVE::Network::SDN::PrefixLists::write_config($config);
            },
            "deleting prefix list entry failed",
            $lock_token,
        );

        return;
    },
});

__PACKAGE__->register_method({
    name => 'create_prefix_list_entry',
    path => '',
    method => 'POST',
    protected => 1,
    permissions => {
        check => ['perm', '/sdn/prefix-lists/{id}', ['SDN.Allocate']],
    },
    description => "Create Prefix List Entry",
    parameters => {
        properties => {
            id => get_standard_option('pve-sdn-prefix-list-id'),
            'lock-token' => get_standard_option('pve-sdn-lock-token'),
            PVE::Network::SDN::PrefixLists::prefix_list_entry_properties(0, 1)->%*,
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

                $config->create_entry($prefix_list_id, $param);
                PVE::Network::SDN::PrefixLists::write_config($config);
            },
            "creating prefix list entry failed",
            $lock_token,
        );

        return;
    },
});

1;
