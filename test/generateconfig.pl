use strict;
use warnings;
use File::Copy;
use PVE::Cluster qw(cfs_read_file);

use PVE::Network::SDN;



my $network_config = PVE::Network::SDN::generate_etc_network_config();
PVE::Network::SDN::write_etc_network_config($network_config);
print "/etc/network/interfaces\n";
print $network_config;
print "\n";


my $frr_config = PVE::Network::SDN::generate_frr_config();
if ($frr_config) {
    PVE::Network::SDN::write_frr_config($frr_config);
    print "/etc/frr/frr.conf\n";
    print $frr_config;
}
