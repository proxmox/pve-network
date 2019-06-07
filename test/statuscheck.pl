use strict;
use warnings;
use File::Copy;
use PVE::Cluster qw(cfs_read_file);

use PVE::Network::SDN;
use Data::Dumper;
use PVE::Network::SDN::Plugin;
use PVE::Network::SDN::VnetPlugin;
use PVE::Network::SDN::VlanPlugin;
use PVE::Network::SDN::VxlanMulticastPlugin;


my $status = PVE::Network::SDN::status();

my $network_cfg = PVE::Cluster::cfs_read_file('networks.cfg');
my $vnet_cfg = undef;
my $transport_cfg = undef;

my $vnet_status = {};
my $transport_status = {};

foreach my $id (keys %{$network_cfg->{ids}}) {
    if ($network_cfg->{ids}->{$id}->{type} eq 'vnet') {
	my $transportzone = $network_cfg->{ids}->{$id}->{transportzone};
	$transport_status->{$transportzone}->{status} = 1 if !defined($transport_status->{$transportzone}->{status});

	if ($status->{$id}->{status} && $status->{$id}->{status} eq 'pass') {
	    $vnet_status->{$id}->{status} = 1;
	    my $bridgeport = $status->{$id}->{config}->{'bridge-ports'};

	    if ($status->{$bridgeport}->{status} && $status->{$bridgeport}->{status} ne 'pass') {
		$vnet_status->{$id}->{status} = 0;
		$transport_status->{$transportzone}->{status} = 0;
	    }
	} else {
	    $vnet_status->{$id}->{status} = 0;
	    $transport_status->{$transportzone}->{status} = 0;
	}
    }
}

print Dumper($vnet_status);
print Dumper($transport_status);
