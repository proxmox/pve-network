package PVE::Network::SDN::Zones::Plugin;

use strict;
use warnings;

use PVE::Tools qw(run_command);
use PVE::JSONSchema;
use PVE::Cluster;
use PVE::Network;

use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file(
    'sdn/zones.cfg',
    sub { __PACKAGE__->parse_config(@_); },
    sub { __PACKAGE__->write_config(@_); },
);

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
	zone => get_standard_option('pve-sdn-zone-id', {
	    completion => \&PVE::Network::SDN::Zones::complete_sdn_zone,
	}),
	ipam => {
	    type => 'string',
	    description => "use a specific ipam",
	    optional => 1,
	},
    },
};

sub private {
    return $defaultData;
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

sub decode_value {
    my ($class, $type, $key, $value) = @_;

    if ($key eq 'nodes' || $key eq 'exitnodes') {
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

    if ($key eq 'nodes' || $key eq 'exitnodes') {
	return join(',', keys(%$value));
    }

    return $value;
}

sub generate_sdn_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $controller, $controller_cfg, $subnet_cfg, $interfaces_config, $config) = @_;

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

sub vnet_update_hook {
    my ($class, $vnet_cfg, $vnetid, $zone_cfg) = @_;

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

sub generate_status_message {
    my ($class, $vnetid, $status, $ifaces) = @_;

    my $err_msg = [];

    return ["vnet is not generated. Please check the 'reload network' task log."]
	if !$status->{$vnetid}->{status};

    foreach my $iface (@{$ifaces}) {
        if (!$status->{$iface}->{status}) {
	    push @$err_msg, "missing $iface";
        } elsif ($status->{$iface}->{status} ne 'pass') {
	    push @$err_msg, "error $iface";
        }
    }

    return $err_msg;
}

sub status {
    my ($class, $plugin_config, $zone, $vnetid, $vnet, $status) = @_;

    return $class->generate_status_message($vnetid, $status);
}


sub tap_create {
    my ($class, $plugin_config, $vnet, $iface, $vnetid) = @_;

    PVE::Network::tap_create($iface, $vnetid);
}

sub veth_create {
    my ($class, $plugin_config, $vnet, $veth, $vethpeer, $vnetid, $hwaddr) = @_;

    PVE::Network::veth_create($veth, $vethpeer, $vnetid, $hwaddr);
}

sub tap_plug {
    my ($class, $plugin_config, $vnet, $tag, $iface, $vnetid, $firewall, $trunks, $rate) = @_;

    my $vlan_aware = PVE::Tools::file_read_firstline("/sys/class/net/$vnetid/bridge/vlan_filtering");
    die "vm vlans are not allowed on vnet $vnetid" if !$vlan_aware && ($tag || $trunks);

    my $opts = {};
    $opts->{learning} = 0 if $plugin_config->{'bridge-disable-mac-learning'};
    $opts->{isolation} = 1 if $vnet->{'isolate-ports'};
    PVE::Network::tap_plug($iface, $vnetid, $tag, $firewall, $trunks, $rate, $opts);
}

sub add_bridge_fdb {
    my ($class, $plugin_config, $iface, $macaddr) = @_;

    PVE::Network::add_bridge_fdb($iface, $macaddr) if $plugin_config->{'bridge-disable-mac-learning'};
}

sub del_bridge_fdb {
    my ($class, $plugin_config, $iface, $macaddr) = @_;

    PVE::Network::del_bridge_fdb($iface, $macaddr) if $plugin_config->{'bridge-disable-mac-learning'};
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
    my ($peers, $iface) = @_;

    my $network_config = PVE::INotify::read_file('interfaces');
    my $ifaces = $network_config->{ifaces};
    
    #if iface is defined, return ip if exist (if not,try to find it on other ifaces)
    if ($iface) {
	my $ip = $ifaces->{$iface}->{address};
	return ($ip,$iface) if $ip;
    }

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

sub find_bridge {
    my ($bridge) = @_;

    die "can't find bridge $bridge" if !-d "/sys/class/net/$bridge";
}

sub is_vlanaware {
    my ($bridge) = @_;

    return PVE::Tools::file_read_firstline("/sys/class/net/$bridge/bridge/vlan_filtering");
}

sub is_ovs {
    my ($bridge) = @_;

    my $is_ovs = !-d "/sys/class/net/$bridge/brif";
    return $is_ovs;    
}

sub get_bridge_ifaces {
    my ($bridge) = @_;

    my @bridge_ifaces = ();
    my $dir = "/sys/class/net/$bridge/brif";
    PVE::Tools::dir_glob_foreach($dir, '(((eth|bond)\d+|en[^.]+)(\.\d+)?)', sub {
	push @bridge_ifaces, $_[0];
    });

    return @bridge_ifaces;
}

sub datacenter_config {
    return PVE::Cluster::cfs_read_file('datacenter.cfg');
}


sub get_mtu {
    my ($class, $plugin_config) = @_;

    die "please implement inside plugin";
}

1;
