use strict;
use warnings;
use PVE::Network::SDN;
use Data::Dumper;

my ($transport_status, $vnet_status, $fabric_status) = PVE::Network::SDN::status();

print Dumper($fabric_status);
print Dumper($vnet_status);
print Dumper($transport_status);
