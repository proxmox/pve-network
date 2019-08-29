use strict;
use warnings;
use File::Copy;
use PVE::Cluster qw(cfs_read_file);

use PVE::Network::SDN;


my $rawconfig = PVE::Network::SDN::generate_etc_network_config();
PVE::Network::SDN::write_etc_network_config($rawconfig);
print $rawconfig;
