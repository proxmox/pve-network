package PVE::Network::SDN::FrrPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Plugin;
use PVE::Tools;

use base('PVE::Network::SDN::Plugin');

sub type {
    return 'frr';
}

sub properties {
    return {
        'asn' => {
            type => 'integer',
            description => "autonomous system number",
        },
        'peers' => {
            description => "peers address list.",
            type => 'string',  #fixme: format 
        },
    };
}

sub options {

    return {
	'uplink-id' => { optional => 0 },
        'asn' => { optional => 0 },
        'peers' => { optional => 0 },
    };
}

# Plugin implementation
sub generate_frr_config {
    my ($class, $plugin_config, $zoneid, $vnetid, $vnet, $uplinks) = @_;

    my $asn = $plugin_config->{'asn'};
    my @peers = split(',', $plugin_config->{'peers'}) if $plugin_config->{'peers'};

    my $uplink = $plugin_config->{'uplink-id'};

    die "missing peers" if !$plugin_config->{'peers'};

    my $iface = "uplink$uplink";
    my $ifaceip = "";

    if($uplinks->{$uplink}->{name}) {
	$iface = $uplinks->{$uplink}->{name};
	$ifaceip = get_first_local_ipv4_from_interface($iface);
    }

    my $config = "\n";
    $config .= "router bgp $asn\n";
    $config .= "bgp router-id $ifaceip\n";
    $config .= "no bgp default ipv4-unicast\n";
    $config .= "coalesce-time 1000\n";

    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	$config .= "neighbor $address remote-as $asn\n";
    } 
    $config .= "!\n";
    $config .= "address-family l2vpn evpn\n";
    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	$config .= " neighbor $address activate\n";
    }
    $config .= " advertise-all-vni\n";
    $config .= "exit-address-family\n";
    $config .= "!\n";
    $config .= "line vty\n";
    $config .= "!\n";


    return $config;
}

sub on_delete_hook {
    my ($class, $transportid, $sdn_cfg) = @_;

}

sub on_update_hook {
    my ($class, $transportid, $sdn_cfg) = @_;

}

1;


