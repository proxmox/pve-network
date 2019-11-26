package PVE::Network::SDN::Controllers::EvpnPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Controllers::Plugin;
use PVE::Tools;
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);

use base('PVE::Network::SDN::Controllers::Plugin');

sub type {
    return 'evpn';
}

sub properties {
    return {
	'uplink-id' => {
	    type => 'integer',
	    minimum => 1, maximum => 4096,
	    description => 'Uplink interface',
	},
        'asn' => {
            type => 'integer',
            description => "autonomous system number",
        },
        'peers' => {
            description => "peers address list.",
            type => 'string', format => 'ip-list'
        },
	'gateway-nodes' => get_standard_option('pve-node-list'),
        'gateway-external-peers' => {
            description => "upstream bgp peers address list.",
            type => 'string', format => 'ip-list'
        },
    };
}

sub options {

    return {
	'uplink-id' => { optional => 0 },
        'asn' => { optional => 0 },
        'peers' => { optional => 0 },
	'gateway-nodes' => { optional => 1 },
	'gateway-external-peers' => { optional => 1 },
    };
}

# Plugin implementation
sub generate_controller_config {
    my ($class, $plugin_config, $controller, $id, $uplinks, $config) = @_;

    my @peers = split(',', $plugin_config->{'peers'}) if $plugin_config->{'peers'};

    my $asn = $plugin_config->{asn};
    my $uplink = $plugin_config->{'uplink-id'};
    my $gatewaynodes = $plugin_config->{'gateway-nodes'};
    my @gatewaypeers = split(',', $plugin_config->{'gateway-external-peers'}) if $plugin_config->{'gateway-external-peers'};

    return if !$asn;

    my $iface = "uplink$uplink";
    my $ifaceip = "";

    if($uplinks->{$uplink}->{name}) {
	$iface = $uplinks->{$uplink}->{name};
        $ifaceip = PVE::Network::SDN::Controllers::Plugin::get_first_local_ipv4_from_interface($iface);
    }

    my $is_gateway = undef;
    my $local_node = PVE::INotify::nodename();

    foreach my $gatewaynode (PVE::Tools::split_list($gatewaynodes)) {
        $is_gateway = 1 if $gatewaynode eq $local_node;
    }

    my @controller_config = ();

    push @controller_config, "bgp router-id $ifaceip";
    push @controller_config, "no bgp default ipv4-unicast";
    push @controller_config, "coalesce-time 1000";

    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	push @controller_config, "neighbor $address remote-as $asn";
    }

    if ($is_gateway) {
	foreach my $address (@gatewaypeers) {
	    push @controller_config, "neighbor $address remote-as external";
	}
    }
    push(@{$config->{frr}->{router}->{"bgp $asn"}->{""}}, @controller_config);

    @controller_config = ();
    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	push @controller_config, "neighbor $address activate";
    }
    push @controller_config, "advertise-all-vni";
    push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"l2vpn evpn"}}, @controller_config);

    if ($is_gateway) {

        @controller_config = ();
        #import /32 routes of evpn network from vrf1 to default vrf (for packet return)
	foreach my $address (@gatewaypeers) {
	    push @controller_config, "neighbor $address activate";
	}
        push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv4 unicast"}}, @controller_config);
        push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv6 unicast"}}, @controller_config);

    }

    return $config;
}

sub generate_controller_zone_config {
    my ($class, $plugin_config, $controller, $id, $uplinks, $config) = @_;

    my $vrf = $id;
    my $vrfvxlan = $plugin_config->{'vrf-vxlan'};
    my $asn = $controller->{asn};
    my $gatewaynodes = $controller->{'gateway-nodes'};

    return if !$vrf || !$vrfvxlan || !$asn;

    #vrf
    my @controller_config = ();
    push @controller_config, "vni $vrfvxlan";
    push(@{$config->{frr}->{vrf}->{"$vrf"}}, @controller_config);

    push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{""}}, "!");

    @controller_config = ();

    my $is_gateway = undef;
    my $local_node = PVE::INotify::nodename();

    foreach my $gatewaynode (PVE::Tools::split_list($gatewaynodes)) {
	$is_gateway = 1 if $gatewaynode eq $local_node;
    }

    if ($is_gateway) {

	@controller_config = ();
	#import /32 routes of evpn network from vrf1 to default vrf (for packet return)
	push @controller_config, "import vrf $vrf";
	push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv4 unicast"}}, @controller_config);
	push(@{$config->{frr}->{router}->{"bgp $asn"}->{"address-family"}->{"ipv6 unicast"}}, @controller_config);

	@controller_config = ();
	#redistribute connected to be able to route to local vms on the gateway
	push @controller_config, "redistribute connected";
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"ipv4 unicast"}}, @controller_config);
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"ipv6 unicast"}}, @controller_config);

	@controller_config = ();
	#add default originate to announce 0.0.0.0/0 type5 route in evpn
	push @controller_config, "default-originate ipv4";
	push @controller_config, "default-originate ipv6";
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"l2vpn evpn"}}, @controller_config);
    }

    return $config;
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

    # verify that asn is not already used by another controller
    my $asn = $controller_cfg->{ids}->{$controllerid}->{asn};
    foreach my $id (keys %{$controller_cfg->{ids}}) {
	next if $id eq $controllerid;
        my $controller = $controller_cfg->{ids}->{$id};
        die "asn $asn is already used by $id"
            if (defined($controller->{asn}) && $controller->{asn} eq $asn);
    }
}

sub sort_frr_config {
    my $order = {};
    $order->{''} = 0;
    $order->{'vrf'} = 1;
    $order->{'ipv4 unicast'} = 1;
    $order->{'ipv6 unicast'} = 2;
    $order->{'l2vpn evpn'} = 3;

    my $a_val = 100;
    my $b_val = 100;

    $a_val = $order->{$a} if defined($order->{$a});
    $b_val = $order->{$b} if defined($order->{$b});

    if($a =~ /bgp (\d+)$/) {
	$a_val = 2;
    }

    if($b =~ /bgp (\d+)$/) {
	$b_val = 2;
    }

    return $a_val <=> $b_val;
}

sub generate_frr_recurse{
   my ($final_config, $content, $parentkey, $level) = @_;

   my $keylist = {};
   $keylist->{vrf} = 1;
   $keylist->{'address-family'} = 1;
   $keylist->{router} = 1;

   my $exitkeylist = {};
   $exitkeylist->{vrf} = 1;
   $exitkeylist->{'address-family'} = 1;

   #fix me, make this generic
   my $paddinglevel = undef;
   if($level == 1 || $level == 2) {
     $paddinglevel = $level - 1;
   } elsif ($level == 3 || $level ==  4) {
     $paddinglevel = $level - 2;
   }

   my $padding = "";
   $padding = ' ' x ($paddinglevel) if $paddinglevel;

   if (ref $content eq ref {}) {
	foreach my $key (sort sort_frr_config keys %$content) {
	    if ($parentkey && defined($keylist->{$parentkey})) {
	 	    push @{$final_config}, $padding."!";
	 	    push @{$final_config}, $padding."$parentkey $key";
	    } else {
	 	    push @{$final_config}, $padding."$key" if $key ne '' && !defined($keylist->{$key});
	    }

	    my $option = $content->{$key};
	    generate_frr_recurse($final_config, $option, $key, $level+1);

	    push @{$final_config}, $padding."exit-$parentkey" if $parentkey && defined($exitkeylist->{$parentkey});
	}
    }

    if (ref $content eq 'ARRAY') {
	foreach my $value (@$content) {
	    push @{$final_config}, $padding."$value";
	}
    }
}

sub write_controller_config {
    my ($class, $plugin_config, $config) = @_;

    my $nodename = PVE::INotify::nodename();

    my $final_config = [];
    push @{$final_config}, "log syslog informational";
    push @{$final_config}, "ip forwarding";
    push @{$final_config}, "ipv6 forwarding";
    push @{$final_config}, "frr defaults traditional";
    push @{$final_config}, "service integrated-vtysh-config";
    push @{$final_config}, "hostname $nodename";
    push @{$final_config}, "!";

    generate_frr_recurse($final_config, $config->{frr}, undef, 0);

    push @{$final_config}, "!";
    push @{$final_config}, "line vty";
    push @{$final_config}, "!";

    my $rawconfig = join("\n", @{$final_config});


    return if !$rawconfig;
    return if !-d "/etc/frr";

    my $frr_config_file = "/etc/frr/frr.conf";

    my $writefh = IO::File->new($frr_config_file,">");
    print $writefh $rawconfig;
    $writefh->close();
}

sub reload_controller {
    my ($class) = @_;

    my $conf_file = "/etc/frr/frr.conf";
    my $bin_path = "/usr/lib/frr/frr-reload.py";

    if (!-e $bin_path) {
	warn "missing $bin_path. Please install frr-pythontools package";
	return;
    }

    my $err = sub {
	my $line = shift;
	if ($line =~ /ERROR:/) {
	    warn "$line \n";
	}
    };

    if (-e $conf_file && -e $bin_path) {
	PVE::Tools::run_command([$bin_path, '--stdout', '--reload', $conf_file], outfunc => {}, errfunc => $err);
    }
}

1;


