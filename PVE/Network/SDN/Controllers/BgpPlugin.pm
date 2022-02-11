package PVE::Network::SDN::Controllers::BgpPlugin;

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
    return 'bgp';
}

sub properties {
    return {
	ebgp => {
	    type => 'boolean',
	    optional => 1,
	    description => "Enable ebgp. (remote-as external)",
	},
	'ebgp-multihop' => {
	    type => 'integer',
	    optional => 1,
	},
	loopback => {
	    description => "source loopback interface.",
	    type => 'string'
	},
        node => get_standard_option('pve-node'),
    };
}

sub options {
    return {
	'node' => { optional => 0 },
	'asn' => { optional => 0 },
	'peers' => { optional => 0 },
	'ebgp' => { optional => 1 },
	'ebgp-multihop' => { optional => 1 },
	'loopback' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_controller_config {
    my ($class, $plugin_config, $controller, $id, $uplinks, $config) = @_;

    my @peers;
    @peers = PVE::Tools::split_list($plugin_config->{'peers'}) if $plugin_config->{'peers'};

    my $asn = $plugin_config->{asn};
    my $ebgp = $plugin_config->{ebgp};
    my $ebgp_multihop = $plugin_config->{'ebgp-multihop'};
    my $loopback = $plugin_config->{loopback};
    my $local_node = PVE::INotify::nodename();


    return if !$asn;
    return if $local_node ne $plugin_config->{node};

    my $bgp = $config->{frr}->{router}->{"bgp $asn"} //= {};

    my ($ifaceip, $interface) = PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers, $loopback);

    my $remoteas = $ebgp ? "external" : $asn;

    #global options
    my @controller_config = (
        "bgp router-id $ifaceip",
        "no bgp default ipv4-unicast",
        "coalesce-time 1000",
        "bgp network import-check"
    );

    push(@{$bgp->{""}}, @controller_config) if keys %{$bgp} == 0;

    @controller_config = ();
    if($ebgp) {
	push @controller_config, "no bgp ebgp-requires-policy";
	push @controller_config, "bgp disable-ebgp-connected-route-check" if $loopback;
    }

    #BGP neighbors
    if(@peers) {
	push @controller_config, "neighbor BGP peer-group";
	push @controller_config, "neighbor BGP remote-as $remoteas";
	push @controller_config, "neighbor BGP bfd";
	push @controller_config, "neighbor BGP ebgp-multihop $ebgp_multihop" if $ebgp && $ebgp_multihop;
    }

    # BGP peers
    foreach my $address (@peers) {
	push @controller_config, "neighbor $address peer-group BGP";
    }
    push(@{$bgp->{""}}, @controller_config);

    # address-family unicast
    if (@peers) {
	my $ipversion = Net::IP::ip_is_ipv6($ifaceip) ? "ipv6" : "ipv4";
	my $mask = Net::IP::ip_is_ipv6($ifaceip) ? "/128" : "32";

	push(@{$bgp->{"address-family"}->{"$ipversion unicast"}}, "network $ifaceip/$mask") if $loopback;
	push(@{$bgp->{"address-family"}->{"$ipversion unicast"}}, "neighbor BGP activate");
	push(@{$bgp->{"address-family"}->{"$ipversion unicast"}}, "neighbor BGP soft-reconfiguration inbound");
    }

    if ($loopback) {
	push(@{$config->{frr}->{''}}, "ip prefix-list loopbacks_ips seq 10 permit 0.0.0.0/0 le 32");
	push(@{$config->{frr}->{''}}, "ip protocol bgp route-map correct_src");
	push(@{$config->{frr}->{'route-map'}->{'correct_src permit 1'}}, "match ip address prefix-list loopbacks_ips");
	push(@{$config->{frr}->{'route-map'}->{'correct_src permit 1'}}, "set src $ifaceip");
    }

    return $config;
}

sub generate_controller_zone_config {
    my ($class, $plugin_config, $controller, $controller_cfg, $id, $uplinks, $config) = @_;

}

sub on_delete_hook {
    my ($class, $controllerid, $zone_cfg) = @_;

    # verify that zone is associated to this controller
    foreach my $id (keys %{$zone_cfg->{ids}}) {
	my $zone = $zone_cfg->{ids}->{$id};
	die "controller $controllerid is used by $id"
	    if (defined($zone->{controller}) && $zone->{controller} eq $controllerid);
    }
}

sub on_update_hook {
    my ($class, $controllerid, $controller_cfg) = @_;

    # we can only have 1 bgp controller by node
    my $local_node = PVE::INotify::nodename();
    my $controllernb = 0;
    foreach my $id (keys %{$controller_cfg->{ids}}) {
        next if $id eq $controllerid;
        my $controller = $controller_cfg->{ids}->{$id};
        next if $controller->{type} ne "bgp";
        next if $controller->{node} ne $local_node;
        $controllernb++;
        die "only 1 bgp controller can be defined" if $controllernb > 1;
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


