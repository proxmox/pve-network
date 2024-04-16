package PVE::Network::SDN::Controllers::IsisPlugin;

use strict;
use warnings;

use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(run_command file_set_contents file_get_contents);

use PVE::Network::SDN::Controllers::Plugin;
use PVE::Network::SDN::Zones::Plugin;
use Net::IP;

use base('PVE::Network::SDN::Controllers::Plugin');

sub type {
    return 'isis';
}

PVE::JSONSchema::register_format('pve-sdn-isis-net', \&pve_verify_sdn_isis_net);
sub pve_verify_sdn_isis_net {
    my ($net) = @_;

    if ($net !~ m/^[a-fA-F0-9]{2}(\.[a-fA-F0-9]{4}){3,9}\.[a-fA-F0-9]{2}$/) {
	die "value does not look like a valid isis net\n";
    }
    return $net;
}

sub properties {
    return {
	'isis-domain' => {
	    description => "ISIS domain.",
	    type => 'string'
	},
	'isis-ifaces' => {
	    description => "ISIS interface.",
	    type => 'string', format => 'pve-iface-list',
	},
	'isis-net' => {
	    description => "ISIS network entity title.",
	    type => 'string', format => 'pve-sdn-isis-net',
	},
    };
}

sub options {
    return {
	'isis-domain' => { optional => 0 },
	'isis-net' => { optional => 0 },
	'isis-ifaces' => { optional => 0 },
        'node' => { optional => 0 },
        'loopback' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_controller_config {
    my ($class, $plugin_config, $controller, $id, $uplinks, $config) = @_;

    my $isis_ifaces = $plugin_config->{'isis-ifaces'};
    my $isis_net = $plugin_config->{'isis-net'};
    my $isis_domain = $plugin_config->{'isis-domain'};
    my $local_node = PVE::INotify::nodename();

    return if !$isis_ifaces || !$isis_net || !$isis_domain;
    return if $local_node ne $plugin_config->{node};

    my @router_config = (
	"net $isis_net",
	"redistribute ipv4 connected level-1",
	"redistribute ipv6 connected level-1",
	"log-adjacency-changes",
    );

    push(@{$config->{frr}->{router}->{"isis $isis_domain"}}, @router_config);

    my @iface_config = (
	"ip router isis $isis_domain"
    );

    my @ifaces = PVE::Tools::split_list($isis_ifaces);
    for my $iface (sort @ifaces) {
	push(@{$config->{frr_interfaces}->{$iface}}, @iface_config);
    }

    return $config;
}

sub generate_controller_zone_config {
    my ($class, $plugin_config, $controller, $controller_cfg, $id, $uplinks, $config) = @_;

}

sub on_delete_hook {
    my ($class, $controllerid, $zone_cfg) = @_;

}

sub on_update_hook {
    my ($class, $controllerid, $controller_cfg) = @_;

    # we can only have 1 bgp controller by node
    my $local_node = PVE::INotify::nodename();
    my $controllernb = 0;
    foreach my $id (keys %{$controller_cfg->{ids}}) {
        next if $id eq $controllerid;
        my $controller = $controller_cfg->{ids}->{$id};
        next if $controller->{type} ne "isis";
        next if $controller->{node} ne $local_node;
        $controllernb++;
        die "only 1 bgp or isis controller can be defined" if $controllernb > 1;
    }
}

sub generate_controller_rawconfig {
    my ($class, $plugin_config, $config) = @_;
    return "";
}

sub write_controller_config {
    my ($class, $plugin_config, $config) = @_;
    return;
}

sub reload_controller {
    my ($class) = @_;
    return;
}

1;


