package PVE::Network::SDN::Controllers::Plugin;

use strict;
use warnings;

use PVE::Tools;
use PVE::JSONSchema;
use PVE::Cluster;

use PVE::Network::SDN::RouteMaps;

use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file(
    'sdn/controllers.cfg',
    sub { __PACKAGE__->parse_config(@_); },
    sub { __PACKAGE__->write_config(@_); },
);

PVE::JSONSchema::register_standard_option(
    'pve-sdn-controller-id',
    {
        description => "The SDN controller object identifier.",
        type => 'string',
        minLength => 2,
        maxLength => 64,
        pattern => '[a-zA-Z][a-zA-Z0-9_-]*[a-zA-Z0-9]',
    },
);

my $defaultData = {

    propertyList => {
        type => {
            description => "Plugin type.",
            type => 'string',
            format => 'pve-configid',
            type => 'string',
        },
        controller => get_standard_option(
            'pve-sdn-controller-id',
            { completion => \&PVE::Network::SDN::complete_sdn_controller },
        ),
        'route-map-in' => {
            description => "Route Map that should be applied for incoming routes",
            type => 'string',
            format => 'pve-sdn-route-map-id',
            optional => 1,
        },
        'route-map-out' => {
            description => "Route Map that should be applied for outgoing routes",
            type => 'string',
            format => 'pve-sdn-route-map-id',
            optional => 1,
        },
        'ebgp-multihop' => {
            type => 'integer',
            optional => 1,
            description => 'Set maximum amount of hops for eBGP peers.',
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

sub generate_frr_config {
    my ($class, $plugin_config, $controller_cfg, $id, $uplinks, $config) = @_;

    die "please implement inside plugin";
}

sub generate_zone_frr_config {
    my ($class, $plugin_config, $controller, $controller_cfg, $id, $uplinks, $config) = @_;

    die "please implement inside plugin";
}

sub generate_vnet_frr_config {
    my ($class, $plugin_config, $controller, $zoneid, $vnetid, $config) = @_;

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
    my $mac = PVE::Tools::file_read_firstline("/sys/class/net/$iface/master/address");
    return $mac if $mac;
    return PVE::Tools::file_read_firstline("/sys/class/net/$iface/address");
}

sub get_router_id {
    my ($ip, $iface) = @_;

    return $ip if Net::IP::ip_is_ipv4($ip);

    #for ipv6, use 4 last bytes of iface mac address as unique id
    my $mac = read_iface_mac($iface);

    die "can't autofind a router-id value from ip or mac" if !$mac;

    if ($mac eq '00:00:00:00:00:00') {
        die "Interface $iface has a zero MAC address. Cannot derive a BGP router-id. "
            . "Please use a dummy interface or assign an IPv4 address to $iface.\n";
    }

    my @mac_bytes = split(':', $mac);
    return
        hex($mac_bytes[2]) . "."
        . hex($mac_bytes[3]) . "."
        . hex($mac_bytes[4]) . "."
        . hex($mac_bytes[5]);
}

=head3 get_default_router_asn($node_name, \%controller_config)

This function determines the ASN that should be used for the BGP router
definition in the FRR configuration on node $node_name with the given controller
configuration \%controller_config.

For backwards-compatibility reasons, this function checks if there is any EVPN
controller in auto mode. The initial SDN implementation *always* uses the ASN
in the BGP controller for its router defintion, if it exists, so return the ASN
of the BGP controller if one is configured and any EVPN controller uses the
auto mode.

The ASN in the router definition defines the ASN of the local node, and is used
for deriving e.g. Route Targets in EVPN setups. Therefore the configuration
needs to always use the EVPN ASN in its router definition to ensure correct
generation for Route Targets (if not using the autort patch).

The FRR config generation logic utilizes the local-as directive for specifying
alternate ASN numbers. Since local-as is only applicable for eBGP sessions, the
internal ASN number always needs to be used for the router definition. So if
there are no EVPN controllers, but iBGP BGP sessions, utilize the ASN configured
there.

In other cases fallback to the BGP controller ASN, if there is no EVPN
controller.

Any configuration that has two iBGP sessions with different ASNs is rejected and
an error thrown, since it is by definition not possible to have two iBGP
sessions with different ASNs on the same BGP instance, as one instance can only
have one local ASN.

=cut

sub get_default_router_asn {
    my ($node_name, $controller_config) = @_;

    my $auto_asn = undef;
    my $evpn_asn = undef;
    my $ibgp_asn = undef;

    my $bgp_controller = PVE::Network::SDN::Controllers::EvpnPlugin::find_bgp_controller(
        $node_name, $controller_config,
    );

    if ($bgp_controller && !$bgp_controller->{ebgp}) {
        $ibgp_asn = $bgp_controller->{asn};
    }

    for my $controller_id (sort keys $controller_config->{ids}->%*) {
        my $controller = $controller_config->{ids}->{$controller_id};

        next if $controller->{type} ne 'evpn';

        if (defined($controller->{nodes})) {
            my @nodes = PVE::Tools::split_list($controller->{nodes});
            next if !grep { $_ eq $node_name } @nodes;
        }

        die "all EVPN controllers on a node must have the same ASN configured"
            if defined($evpn_asn) && $evpn_asn ne $controller->{asn};

        $evpn_asn = $controller->{asn};

        my $bgp_mode = $controller->{'bgp-mode'} // 'auto';
        $auto_asn = $bgp_controller->{asn} if $bgp_mode eq 'auto' && $bgp_controller;

        next if $bgp_mode eq 'external';

        die "cannot have two different ASNs for iBGP sessions configured"
            if defined($ibgp_asn) && $ibgp_asn ne $controller->{asn};

        $ibgp_asn = $controller->{asn};
    }

    return $auto_asn // $evpn_asn // $ibgp_asn // $bgp_controller->{asn};
}

1;
