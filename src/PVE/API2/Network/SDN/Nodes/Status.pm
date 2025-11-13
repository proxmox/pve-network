package PVE::API2::Network::SDN::Nodes::Status;

use strict;
use warnings;

use PVE::API2::Network::SDN::Nodes::Fabrics;
use PVE::API2::Network::SDN::Nodes::Zones;

use PVE::JSONSchema qw(get_standard_option);

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Nodes::Fabrics",
    path => 'fabrics',
});

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Nodes::Zones",
    path => 'zones',
});

__PACKAGE__->register_method({
    name => 'sdnindex',
    path => '',
    method => 'GET',
    permissions => { user => 'all' },
    description => "SDN index.",
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {},
        },
        links => [{ rel => 'child', href => "{name}" }],
    },
    code => sub {
        my ($param) = @_;

        my $result = [
            { name => 'fabrics' }, { name => 'zones' },
        ];
        return $result;
    },
});

1;
