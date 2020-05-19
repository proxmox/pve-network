package PVE::Network::SDN::Zones::Plugin;

use strict;
use warnings;

use PVE::Tools qw(run_command);
use PVE::JSONSchema;
use PVE::Cluster;
use PVE::Network;

use Data::Dumper;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file('sdn/zones.cfg',
				 sub { __PACKAGE__->parse_config(@_); },
				 sub { __PACKAGE__->write_config(@_); });

PVE::JSONSchema::register_standard_option('pve-sdn-zone-id', {
    description => "The SDN zone object identifier.",
    type => 'string', format => 'pve-sdn-zone-id',
});

PVE::JSONSchema::register_format('pve-sdn-zone-id', \&parse_sdn_zone_id);
sub parse_sdn_zone_id {
    my ($id, $noerr) = @_;

    if ($id !~ m/^[a-z][a-z0-9]*[a-z0-9]$/i) {
	return undef if $noerr;
	die "zone ID '$id' contains illegal characters\n";
    }
    die "zone ID '$id' can't be more length than 8 characters\n" if length($id) > 8;
    return $id;
}

my $defaultData = {

    propertyList => {
	type => {
	    description => "Plugin type.",
	    type => 'string', format => 'pve-configid',
	    type => 'string',
	},
        nodes => get_standard_option('pve-node-list', { optional => 1 }),
        zone => get_standard_option('pve-sdn-zone-id',
            { completion => \&PVE::Network::SDN::Zones::complete_sdn_zone }),
    },
};

sub private {
    return $defaultData;
}

sub decode_value {
    my ($class, $type, $key, $value) = @_;

    if ($key eq 'nodes') {
        my $res = {};

        foreach my $node (PVE::Tools::split_list($value)) {
            if (PVE::JSONSchema::pve_verify_node_name($node)) {
                $res->{$node} = 1;
            }
        }

        return $res;
    } 

   return $value;
}

sub encode_value {
    my ($class, $type, $key, $value) = @_;

    if ($key eq 'nodes') {
        return join(',', keys(%$value));
    }

    return $value;
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
        my ($type, $id) = (lc($1), $2);
	my $errmsg = undef; # set if you want to skip whole section
	eval { PVE::JSONSchema::pve_verify_configid($type); };
	$errmsg = $@ if $@;
	my $config = {}; # to return additional attributes
	return ($type, $id, $errmsg, $config);
    }
    return undef;
}

sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $interfaces_config, $config) = @_;

    die "please implement inside plugin";
}

sub generate_controller_config {
    my ($class, $plugin_config, $controller, $id, $uplinks, $config) = @_;

    die "please implement inside plugin";
}

sub generate_controller_vnet_config {
    my ($class, $plugin_config, $controller, $zoneid, $vnetid, $config) = @_;

}

sub write_controller_config {
    my ($class, $plugin_config, $config) = @_;

    die "please implement inside plugin";
}

sub controller_reload {
    my ($class) = @_;

    die "please implement inside plugin";
}

sub on_delete_hook {
    my ($class, $zoneid, $vnet_cfg) = @_;

    # verify that no vnet are associated to this zone
    foreach my $id (keys %{$vnet_cfg->{ids}}) {
	my $vnet = $vnet_cfg->{ids}->{$id};
	die "zone $zoneid is used by vnet $id"
	    if ($vnet->{type} eq 'vnet' && defined($vnet->{zone}) && $vnet->{zone} eq $zoneid);
    }
}

sub on_update_hook {
    my ($class, $zoneid, $zone_cfg, $controller_cfg) = @_;

    # do nothing by default
}

#helpers
sub parse_tag_number_or_range {
    my ($str, $max, $tag) = @_;

    my @elements = split(/,/, $str);
    my $count = 0;
    my $allowed = undef;

    die "extraneous commas in list\n" if $str ne join(',', @elements);
    foreach my $item (@elements) {
	if ($item =~ m/^([0-9]+)-([0-9]+)$/) {
	    $count += 2;
	    my ($port1, $port2) = ($1, $2);
	    die "invalid port '$port1'\n" if $port1 > $max;
	    die "invalid port '$port2'\n" if $port2 > $max;
	    die "backwards range '$port1:$port2' not allowed, did you mean '$port2:$port1'?\n" if $port1 > $port2;

	    if ($tag && $tag >= $port1 && $tag <= $port2){
		$allowed = 1;
		last;
	    }

	} elsif ($item =~ m/^([0-9]+)$/) {
	    $count += 1;
	    my $port = $1;
	    die "invalid port '$port'\n" if $port > $max;

	    if ($tag && $tag == $port){
		$allowed = 1;
		last;
	    }
	}
    }
    die "tag $tag is not allowed" if $tag && !$allowed;

    return (scalar(@elements) > 1);
}

sub status {
    my ($class, $plugin_config, $zone, $id, $vnet, $err_config, $status, $vnet_status, $zone_status) = @_;

    $vnet_status->{$id}->{zone} = $zone;
    $zone_status->{$zone}->{status} = 'available' if !defined($zone_status->{$zone}->{status});

    if($err_config) {
	$vnet_status->{$id}->{status} = 'pending';
	$vnet_status->{$id}->{statusmsg} = $err_config;
	$zone_status->{$zone}->{status} = 'pending';
    } elsif ($status->{$id}->{status} && $status->{$id}->{status} eq 'pass') {
	$vnet_status->{$id}->{status} = 'available';
	my $bridgeport = $status->{$id}->{config}->{'bridge-ports'};

	if ($bridgeport && $status->{$bridgeport}->{status} && $status->{$bridgeport}->{status} ne 'pass') {
	    $vnet_status->{$id}->{status} = 'error';
	    $vnet_status->{$id}->{statusmsg} = 'configuration not fully applied';
	    $zone_status->{$zone}->{status} = 'error';
	}

    } else {
	$vnet_status->{$id}->{status} = 'error';
	$vnet_status->{$id}->{statusmsg} = 'missing';
	$zone_status->{$zone}->{status} = 'error';
    }
}


sub get_bridge_vlan {
    my ($class, $plugin_config, $vnetid, $tag) = @_;

    my $bridge = $vnetid;
    $tag = undef;

    die "bridge $bridge is missing" if !-d "/sys/class/net/$bridge/";

    return ($bridge, $tag);
}

sub tap_create {
    my ($class, $plugin_config, $vnet, $iface, $vnetid) = @_;

    my $tag = $vnet->{tag};
    my ($bridge, undef) = $class->get_bridge_vlan($plugin_config, $vnetid, $tag);
    die "unable to get bridge setting\n" if !$bridge;

    PVE::Network::tap_create($iface, $bridge);
}

sub veth_create {
    my ($class, $plugin_config, $vnet, $veth, $vethpeer, $vnetid, $hwaddr) = @_;

    my $tag = $vnet->{tag};
    my ($bridge, undef) = $class->get_bridge_vlan($plugin_config, $vnetid, $tag);
    die "unable to get bridge setting\n" if !$bridge;

    PVE::Network::veth_create($veth, $vethpeer, $bridge, $hwaddr);
}

sub tap_plug {
    my ($class, $plugin_config, $vnet, $iface, $vnetid, $firewall, $rate) = @_;

    my $tag = $vnet->{tag};

    ($vnetid, $tag) = $class->get_bridge_vlan($plugin_config, $vnetid, $tag);
    my $trunks = undef;

    PVE::Network::tap_plug($iface, $vnetid, $tag, $firewall, $trunks, $rate);
}

#helper

sub get_uplink_iface {
    my ($interfaces_config, $uplink) = @_;

    my $iface = undef;
    foreach my $id (keys %{$interfaces_config->{ifaces}}) {
        my $interface = $interfaces_config->{ifaces}->{$id};
        if (my $iface_uplink = $interface->{'uplink-id'}) {
	    next if $iface_uplink ne $uplink;
            if($interface->{type} ne 'eth' && $interface->{type} ne 'bond') {
                warn "uplink $uplink is not a physical or bond interface";
                next;
            }
	    $iface = $id;
        }
    }

    #create a dummy uplink interface if no uplink found
    if(!$iface) {
        warn "can't find uplink $uplink in physical interface";
        $iface = "uplink${uplink}";
    }

    return $iface;
}

sub get_local_route_ip {
    my ($targetip) = @_;

    my $ip = undef;
    my $interface = undef;

    run_command(['/sbin/ip', 'route', 'get', $targetip], outfunc => sub {
        if ($_[0] =~ m/src ($PVE::Tools::IPRE)/) {
            $ip = $1;
        }
        if ($_[0] =~ m/dev (\S+)/) {
            $interface = $1;
        }

    });
    return ($ip, $interface);
}


sub find_local_ip_interface_peers {
    my ($peers) = @_;

    my $network_config = PVE::INotify::read_file('interfaces');
    my $ifaces = $network_config->{ifaces};
    #is a local ip member of peers list ?
    foreach my $address (@{$peers}) {
	while (my $interface = each %$ifaces) {
	    my $ip = $ifaces->{$interface}->{address};
	    if ($ip && $ip eq $address) {
		return ($ip, $interface);
	    }
	}
    }

    #if peer is remote, find source with ip route
    foreach my $address (@{$peers}) {
	my ($ip, $interface) = get_local_route_ip($address);
	return ($ip, $interface);
    }
}

1;
