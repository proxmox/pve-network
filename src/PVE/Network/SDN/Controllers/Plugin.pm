package PVE::Network::SDN::Controllers::Plugin;

use strict;
use warnings;

use PVE::Tools;
use PVE::JSONSchema;
use PVE::Cluster;

use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file('sdn/controllers.cfg',
    sub { __PACKAGE__->parse_config(@_); },
    sub { __PACKAGE__->write_config(@_); }
);

PVE::JSONSchema::register_standard_option('pve-sdn-controller-id', {
    description => "The SDN controller object identifier.",
    type => 'string', format => 'pve-sdn-controller-id',
});

PVE::JSONSchema::register_format('pve-sdn-controller-id', \&parse_sdn_controller_id);
sub parse_sdn_controller_id {
    my ($id, $noerr) = @_;

    if ($id !~ m/^[a-z][a-z0-9_-]*[a-z0-9]$/i) {
        return undef if $noerr;
        die "controller ID '$id' contains illegal characters\n";
    }
    die "controller ID '$id' can't be more length than 64 characters\n" if length($id) > 64;
    return $id;
}

my $defaultData = {

    propertyList => {
	type => {
	    description => "Plugin type.",
	    type => 'string', format => 'pve-configid',
	    type => 'string',
	},
        controller => get_standard_option('pve-sdn-controller-id',
            { completion => \&PVE::Network::SDN::complete_sdn_controller }),
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

sub generate_sdn_config {
    my ($class, $plugin_config, $node, $data, $ctime) = @_;

    die "please implement inside plugin";
}

sub generate_controller_config {
    my ($class, $plugin_config, $controller_cfg, $id, $uplinks, $config) = @_;

    die "please implement inside plugin";
}


sub generate_controller_zone_config {
    my ($class, $plugin_config, $controller, $controller_cfg, $id, $uplinks, $config) = @_;

    die "please implement inside plugin";
}

sub generate_controller_vnet_config {
    my ($class, $plugin_config, $controller, $zoneid, $vnetid, $config) = @_;

}

sub generate_controller_rawconfig {
    my ($class, $plugin_config, $config) = @_;

    die "please implement inside plugin";
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
    my ($class, $controllerid, $zone_cfg) = @_;

    # do nothing by default
}

sub on_update_hook {
    my ($class, $controllerid, $controller_cfg) = @_;

    # do nothing by default
}

#helpers

sub read_iface_mac {
    my ($iface) = @_;
    return PVE::Tools::file_read_firstline("/sys/class/net/$iface/master/address");
}

sub get_router_id {
    my ($ip, $iface) = @_;

    return $ip if Net::IP::ip_is_ipv4($ip);

    #for ipv6, use 4 last bytes of iface mac address as unique id
    my $mac = read_iface_mac($iface);

    die "can't autofind a router-id value from ip or mac" if !$mac;

    my @mac_bytes = split(':', $mac);
    return hex($mac_bytes[2]).".".hex($mac_bytes[3]).".".hex($mac_bytes[4]).".".hex($mac_bytes[5]);
}

1;
