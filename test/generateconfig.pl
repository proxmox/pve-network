use strict;
use warnings;
use File::Copy;
use PVE::Cluster qw(cfs_read_file);

use PVE::Network::Vnet;
use PVE::Network::Plugin;
use PVE::Network::VlanPlugin;
use PVE::Network::VxlanMulticastPlugin;

PVE::Network::VlanPlugin->register();
PVE::Network::VxlanMulticastPlugin->register();
PVE::Network::Plugin->init();


my $rawconfig = generate_network_config();
print $rawconfig;
verify_merged_config($rawconfig);
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
		$uplinks->{$interface->{'uplink-id'}} = $id;
	}
     }

      my $vnet_cfg = PVE::Cluster::cfs_read_file('network/vnet.cfg');
      my $transport_cfg = PVE::Cluster::cfs_read_file('network/transports.cfg');

       #generate configuration
       my $rawconfig = "";
       foreach my $id (keys %{$vnet_cfg->{ids}}) {
	     my $vnet = $vnet_cfg->{ids}->{$id};
	     my $zone = $vnet->{transportzone};

	     my $plugin_config = $transport_cfg->{ids}->{$zone};
	     die "zone $zone don't exist" if !defined($plugin_config);
             my $plugin = PVE::Network::Plugin->lookup($plugin_config->{type});
             $rawconfig .= $plugin->generate_network_config($plugin_config, $zone, $id, $vnet, $uplinks);
        }

return $rawconfig;
}

#implement reload (split and reuse code from API2/Network.pm for bridge delete verification)

sub verify_merged_config {
    my ($rawconfig) = @_;

	#merge main network intefaces and vnet file for possible conflict verification
	my $tmp_merged_network_interfaces = "/var/tmp/pve-merged_network_interfaces";
	copy("/etc/network/interfaces", $tmp_merged_network_interfaces);

	my $writefh = IO::File->new($tmp_merged_network_interfaces, '>>');
	print $writefh $rawconfig;
	$writefh->close();

	my $readfh = IO::File->new($tmp_merged_network_interfaces);
	my $merged_interfaces_config = PVE::INotify::read_etc_network_interfaces(1,$readfh);
	$readfh->close();
	unlink $tmp_merged_network_interfaces;
	PVE::INotify::__write_etc_network_interfaces($merged_interfaces_config, 1);

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




