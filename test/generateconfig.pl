use strict;
use warnings;
use File::Copy;
use PVE::Cluster qw(cfs_read_file);

use PVE::Network::SDN::Plugin;
use PVE::Network::SDN::VnetPlugin;
use PVE::Network::SDN::VlanPlugin;
use PVE::Network::SDN::VxlanMulticastPlugin;

PVE::Network::SDN::VnetPlugin->register();
PVE::Network::SDN::VlanPlugin->register();
PVE::Network::SDN::VxlanMulticastPlugin->register();
PVE::Network::SDN::Plugin->init();


my $rawconfig = generate_network_config();
print $rawconfig;
write_final_config($rawconfig);

sub generate_network_config {

     #only support ifupdown2
    die "you need ifupdown2 to reload networking\n" if !-e '/usr/share/ifupdown2';

     #read main config for physical interfaces
     my $current_config_file = "/etc/network/interfaces";
     my $fh = IO::File->new($current_config_file);
     my $interfaces_config = PVE::INotify::read_etc_network_interfaces(1,$fh);
     $fh->close();

     #check uplinks
     my $uplinks = {};
     foreach my $id (keys %{$interfaces_config->{ifaces}}) {
        my $interface = $interfaces_config->{ifaces}->{$id};
	if (my $uplink = $interface->{'uplink-id'}) {
		die "uplink-id $uplink is already defined on $uplinks->{$uplink}" if $uplinks->{$uplink};
		$interface->{name} = $id;
		$uplinks->{$interface->{'uplink-id'}} = $interface;
	}
     }

    my $network_cfg = PVE::Cluster::cfs_read_file('networks.cfg');
    my $vnet_cfg = undef;
    my $transport_cfg = undef;

    foreach my $id (keys %{$network_cfg->{ids}}) {
	if ($network_cfg->{ids}->{$id}->{type} eq 'vnet') {
	    $vnet_cfg->{ids}->{$id} = $network_cfg->{ids}->{$id};
	} else {
	    $transport_cfg->{ids}->{$id} = $network_cfg->{ids}->{$id};
	}
    }

       #generate configuration
       my $rawconfig = "";
       foreach my $id (keys %{$vnet_cfg->{ids}}) {
	     my $vnet = $vnet_cfg->{ids}->{$id};
	     my $zone = $vnet->{transportzone};

	     die "zone $zone don't exist" if !$zone;
	     my $plugin_config = $transport_cfg->{ids}->{$zone};
	     die "zone $zone don't exist" if !defined($plugin_config);
             my $plugin = PVE::Network::SDN::Plugin->lookup($plugin_config->{type});
             $rawconfig .= $plugin->generate_network_config($plugin_config, $zone, $id, $vnet, $uplinks);
        }

return $rawconfig;
}


sub write_final_config {
    my ($rawconfig) = @_;
	#now write final separate filename
	my $tmp_file = "/var/tmp/pve-vnet.cfg";

	my $vnet_interfaces_file = "/etc/network/interfaces.d/vnet";

	my $writefh = IO::File->new($vnet_interfaces_file,">");
	print $writefh $rawconfig;
	$writefh->close();
}




