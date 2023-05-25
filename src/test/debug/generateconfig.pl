use strict;
use warnings;
use File::Copy;
use PVE::Cluster qw(cfs_read_file);

use PVE::Network::SDN;
use PVE::Network::SDN::Zones;
use PVE::Network::SDN::Controllers;
use Data::Dumper;

PVE::Network::SDN::commit_config();
my $network_config = PVE::Network::SDN::Zones::generate_etc_network_config();

PVE::Network::SDN::Zones::write_etc_network_config($network_config);
print "/etc/network/interfaces.d/sdn\n";
print $network_config;
print "\n";

my $controller_config = PVE::Network::SDN::Controllers::generate_controller_config();

if ($controller_config) {
    print Dumper($controller_config);
    PVE::Network::SDN::Controllers::write_controller_config($controller_config);
}
