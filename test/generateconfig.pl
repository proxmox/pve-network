use strict;
use warnings;
use File::Copy;
use PVE::Cluster qw(cfs_read_file);

use PVE::Network::SDN;


my ($network_config, $frr_config) = PVE::Network::SDN::generate_etc_network_config();
PVE::Network::SDN::write_etc_network_config($network_config);
print $network_config;
print $frr_config;
