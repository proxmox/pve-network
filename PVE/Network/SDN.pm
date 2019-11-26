package PVE::Network::SDN;

use strict;
use warnings;

use Data::Dumper;
use JSON;

use PVE::Network::SDN::Zones;

use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);

# improve me : move status code inside plugins ?

sub ifquery_check {

    my $cmd = ['ifquery', '-a', '-c', '-o','json'];

    my $result = '';
    my $reader = sub { $result .= shift };

    eval {
	run_command($cmd, outfunc => $reader);
    };

    my $resultjson = decode_json($result);
    my $interfaces = {};

    foreach my $interface (@$resultjson) {
	my $name = $interface->{name};
	$interfaces->{$name} = {
	    status => $interface->{status},
	    config => $interface->{config},
	    config_status => $interface->{config_status},
	};
    }

    return $interfaces;
}

sub status {

    my ($transport_status, $vnet_status) = PVE::Network::SDN::Zones::status();
    return($transport_status, $vnet_status);
}

1;

