package PVE::API2::Network::SDN::Nodes::Fabrics;

use strict;
use warnings;

use PVE::API2::Network::SDN::Nodes::Fabric;

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Nodes::Fabric",
    path => '{fabric}',
});

1;
