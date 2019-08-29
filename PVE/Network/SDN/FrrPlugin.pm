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
    my ($class, $plugin_config, $asn, $id, $uplinks, $config) = @_;

    my @peers = split(',', $plugin_config->{'peers'}) if $plugin_config->{'peers'};

    my $uplink = $plugin_config->{'uplink-id'};

    my $iface = "uplink$uplink";
    my $ifaceip = "";

    if($uplinks->{$uplink}->{name}) {
	$iface = $uplinks->{$uplink}->{name};
        $ifaceip = PVE::Network::SDN::Plugin::get_first_local_ipv4_from_interface($iface);
    }

    my @router_config = ();

    push @router_config, "bgp router-id $ifaceip";
    push @router_config, "coalesce-time 1000";

    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	push @router_config, "neighbor $address remote-as $asn";
    } 
    push @router_config, "!";
    push @router_config, "address-family l2vpn evpn";
    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	push @router_config, " neighbor $address activate";
    }
    push @router_config, " advertise-all-vni";
    push @router_config, "exit-address-family";

    push(@{$config->{router}->{"router bgp $asn"}}, @router_config);

    return $config;
}

sub on_delete_hook {
    my ($class, $transportid, $sdn_cfg) = @_;

}

sub on_update_hook {
    my ($class, $transportid, $sdn_cfg) = @_;

}

1;


