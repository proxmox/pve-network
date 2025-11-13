package PVE::API2::Network::SDN::Nodes::Vnets;

use strict;
use warnings;

use PVE::API2::Network::SDN::Nodes::Vnet;

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Nodes::Vnet",
    path => '{vnet}',
});

1;
