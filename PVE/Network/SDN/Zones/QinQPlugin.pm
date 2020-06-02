package PVE::Network::SDN::Zones::QinQPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Zones::Plugin;

use base('PVE::Network::SDN::Zones::Plugin');

sub type {
    return 'qinq';
}

sub properties {
    return {
	tag => {
	    type => 'integer',
	    minimum => 0,
	    description => "Service-VLAN Tag",
	},
	mtu => {
	    type => 'integer',
	    description => "MTU",
	    optional => 1,
	},
       'vlan-protocol' => {
	    type => 'string',
	    enum => ['802.1q', '802.1ad'],
	    default => '802.1q',
	    optional => 1,
	}
    };
}

sub options {

    return {
        nodes => { optional => 1},
	'tag' => { optional => 0 },
	'bridge' => { optional => 0 },
	'mtu' => { optional => 1 },
	'vlan-protocol' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $interfaces_config, $config) = @_;

    my $stag = $plugin_config->{tag};
    my $mtu = $plugin_config->{mtu};
    my $bridge = $plugin_config->{'bridge'};
    my $vlanprotocol = $plugin_config->{'vlan-protocol'};
    my $ctag = $vnet->{tag};
    my $alias = $vnet->{alias};
    die "can't find bridge $bridge" if !-d "/sys/class/net/$bridge";

    my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");
    my $is_ovs = 1 if !-d "/sys/class/net/$bridge/brif";

    my @iface_config = ();
    my $vnet_bridge_ports = "";

    if($is_ovs) {

        #ovs--->ovsintport(dot1q-tunnel tag)------->vlanawarebrige-----(tag)--->vnet

	$vlanprotocol = "802.1q" if !$vlanprotocol;
	my $svlan_iface = "sv_".$zoneid;
	my $zone = "z_$zoneid";

	#ovs dot1q-tunnel port
	@iface_config = ();
	push @iface_config, "ovs_type OVSIntPort";
	push @iface_config, "ovs_bridge $bridge";
	push @iface_config, "ovs_options vlan_mode=dot1q-tunnel tag=$stag other_config:qinq-ethtype=$vlanprotocol";
	push(@{$config->{$svlan_iface}}, @iface_config) if !$config->{$svlan_iface};

	#redefine main ovs bridge, ifupdown2 will merge ovs_ports
	@iface_config = ();
	push @iface_config, "ovs_ports $svlan_iface";
	push(@{$config->{$bridge}}, @iface_config); 

	#zone vlan aware bridge
	@iface_config = ();
	push @iface_config, "mtu $mtu" if $mtu;
	push @iface_config, "bridge-stp off";
	push @iface_config, "bridge-ports $svlan_iface";
	push @iface_config, "bridge-fd 0";
	push @iface_config, "bridge-vlan-aware yes";
	push @iface_config, "bridge-vids 2-4094";
	push(@{$config->{$zone}}, @iface_config) if !$config->{$zone};

	$vnet_bridge_ports = "$zone.$ctag";

    } elsif ($vlan_aware) {

        #vlanawarebrige-(tag)----->vlanwarebridge-(tag)----->vnet

	my $zone = "z_$zoneid";

	if($vlanprotocol) {
	    @iface_config = ();
	    push @iface_config, "bridge-vlan-protocol $vlanprotocol";
	    push(@{$config->{$bridge}}, @iface_config) if !$config->{$bridge};
	}

	#zone vlan bridge
	@iface_config = ();
	push @iface_config, "mtu $mtu" if $mtu;
	push @iface_config, "bridge-stp off";
	push @iface_config, "bridge-ports $bridge.$stag";
	push @iface_config, "bridge-fd 0";
	push @iface_config, "bridge-vlan-aware yes";
	push @iface_config, "bridge-vids 2-4094";
	push(@{$config->{$zone}}, @iface_config) if !$config->{$zone};

	$vnet_bridge_ports = "$zone.$ctag";

    } else {

	#eth--->eth.x(svlan)--->eth.x.y(cvlan)---->vnet

	my @bridge_ifaces = ();
	my $dir = "/sys/class/net/$bridge/brif";
	PVE::Tools::dir_glob_foreach($dir, '(((eth|bond)\d+|en[^.]+)(\.\d+)?)', sub {
	    push @bridge_ifaces, $_[0];
	});

	foreach my $bridge_iface (@bridge_ifaces) {

	    # use named vlan interface to avoid too long names
	    my $svlan_iface = "sv_$vnetid";
	    my $cvlan_iface = "cv_$vnetid";

	    #svlan
	    @iface_config = ();
	    push @iface_config, "vlan-raw-device $bridge_iface";
	    push @iface_config, "vlan-id $stag";
	    push @iface_config, "vlan-protocol $vlanprotocol" if $vlanprotocol;
	    push(@{$config->{$svlan_iface}}, @iface_config) if !$config->{$svlan_iface};

	    #cvlan
	    @iface_config = ();
	    push @iface_config, "vlan-raw-device $svlan_iface";
	    push @iface_config, "vlan-id $ctag";
	    push(@{$config->{$cvlan_iface}}, @iface_config) if !$config->{$cvlan_iface};

	    $vnet_bridge_ports .= " $cvlan_iface";
        }
   }

    #vnet bridge
    @iface_config = ();
    push @iface_config, "bridge_ports $vnet_bridge_ports";
    push @iface_config, "bridge_stp off";
    push @iface_config, "bridge_fd 0";
    if($vnet->{vlanaware}) {
	push @iface_config, "bridge-vlan-aware yes";
	push @iface_config, "bridge-vids 2-4094";
    }
    push @iface_config, "mtu $mtu" if $mtu;
    push @iface_config, "alias $alias" if $alias;
    push(@{$config->{$vnetid}}, @iface_config) if !$config->{$vnetid};

}

sub status {
    my ($class, $plugin_config, $zone, $id, $vnet, $err_config, $status, $vnet_status, $zone_status) = @_;

    my $bridge = $plugin_config->{bridge};
    $vnet_status->{$id}->{zone} = $zone;
    $zone_status->{$zone}->{status} = 'available' if !defined($zone_status->{$zone}->{status});

    if($err_config) {
	$vnet_status->{$id}->{status} = 'pending';
	$vnet_status->{$id}->{statusmsg} = $err_config;
	$zone_status->{$zone}->{status} = 'pending';
    } elsif ($status->{$bridge}->{status} && $status->{$bridge}->{status} eq 'pass') {
	$vnet_status->{$id}->{status} = 'available';
    } else {
	$vnet_status->{$id}->{status} = 'error';
	$vnet_status->{$id}->{statusmsg} = 'missing bridge';
	$zone_status->{$zone}->{status} = 'error';
    }
}

1;


