use strict;
use warnings;
use File::Copy;
use PVE::Cluster qw(cfs_read_file);

use PVE::Network::SDN;
use Data::Dumper;


my $network_config = PVE::Network::SDN::generate_etc_network_config();
PVE::Network::SDN::write_etc_network_config($network_config);
print "/etc/network/interfaces\n";
print $network_config;
print "\n";


my $controller_config = PVE::Network::SDN::generate_controller_config();
if ($controller_config) {
    print Dumper($controller_config);
    PVE::Network::SDN::write_controller_config($controller_config);
    print "/etc/frr/frr.conf\n";
}
