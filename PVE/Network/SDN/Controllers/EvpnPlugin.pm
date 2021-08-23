package PVE::Network::SDN::Controllers::EvpnPlugin;

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
    return 'evpn';
}

sub properties {
    return {
	asn => {
	    type => 'integer',
	    description => "autonomous system number",
	},
	peers => {
	    description => "peers address list.",
	    type => 'string', format => 'ip-list'
	},
    };
}

sub options {
    return {
	'asn' => { optional => 0 },
	'peers' => { optional => 0 },
    };
}

# Plugin implementation
sub generate_controller_config {
    my ($class, $plugin_config, $controller_cfg, $id, $uplinks, $config) = @_;

    my @peers;
    @peers = PVE::Tools::split_list($plugin_config->{'peers'}) if $plugin_config->{'peers'};

    my $local_node = PVE::INotify::nodename();

    my $asn = $plugin_config->{asn};
    my $ebgp = undef;
    my $loopback = undef;
    my $autortas = undef;
    my $bgprouter = find_bgp_controller($local_node, $controller_cfg);
    if($bgprouter) {
	$ebgp = 1 if $plugin_config->{'asn'} ne $bgprouter->{asn};
	$loopback = $bgprouter->{loopback} if $bgprouter->{loopback};
	$asn = $bgprouter->{asn} if $bgprouter->{asn};
	$autortas = $plugin_config->{'asn'} if $ebgp;
    }

    return if !$asn;

    my $bgp = $config->{frr}->{router}->{"bgp $asn"} //= {};

    my ($ifaceip, $interface) = PVE::Network::SDN::Zones::Plugin::find_local_ip_interface_peers(\@peers, $loopback);

    my $remoteas = $ebgp ? "external" : $asn;

    #global options
    my @controller_config = (
	"bgp router-id $ifaceip",
	"no bgp default ipv4-unicast",
	"coalesce-time 1000",
    );

    push(@{$bgp->{""}}, @controller_config) if keys %{$bgp} == 0;

    @controller_config = ();
    
    #VTEP neighbors
    push @controller_config, "neighbor VTEP peer-group";
    push @controller_config, "neighbor VTEP remote-as $remoteas";
    push @controller_config, "neighbor VTEP bfd";

    if($ebgp && $loopback) {
	push @controller_config, "neighbor VTEP ebgp-multihop 10";
	push @controller_config, "neighbor VTEP update-source $loopback";
    }

    # VTEP peers
    foreach my $address (@peers) {
	next if $address eq $ifaceip;
	push @controller_config, "neighbor $address peer-group VTEP";
    }

    push(@{$bgp->{""}}, @controller_config);

    # address-family l2vpn
    @controller_config = ();
    push @controller_config, "neighbor VTEP activate";
    push @controller_config, "advertise-all-vni";
    push @controller_config, "autort as $autortas" if $autortas;
    push(@{$bgp->{"address-family"}->{"l2vpn evpn"}}, @controller_config);

    return $config;
}

sub generate_controller_zone_config {
    my ($class, $plugin_config, $controller, $controller_cfg, $id, $uplinks, $config) = @_;

    my $local_node = PVE::INotify::nodename();

    my $vrf = "vrf_$id";
    my $vrfvxlan = $plugin_config->{'vrf-vxlan'};
    my $exitnodes = $plugin_config->{'exitnodes'};
    my $advertisesubnets = $plugin_config->{'advertise-subnets'};
    my $exitnodes_local_routing = $plugin_config->{'exitnodes-local-routing'};

    my $asn = $controller->{asn};
    my $ebgp = undef;
    my $loopback = undef;
    my $autortas = undef;
    my $bgprouter = find_bgp_controller($local_node, $controller_cfg);
    if($bgprouter) {
        $ebgp = 1 if $controller->{'asn'} ne $bgprouter->{asn};
	$loopback = $bgprouter->{loopback} if $bgprouter->{loopback};
	$asn = $bgprouter->{asn} if $bgprouter->{asn};
	$autortas = $controller->{'asn'} if $ebgp;
    }

    return if !$vrf || !$vrfvxlan || !$asn;

    # vrf
    my @controller_config = ();
    push @controller_config, "vni $vrfvxlan";
    push(@{$config->{frr}->{vrf}->{"$vrf"}}, @controller_config);

    #main vrf router
    @controller_config = ();
    push @controller_config, "no bgp ebgp-requires-policy" if $ebgp;
#    push @controller_config, "!";
    push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{""}}, @controller_config);

    if ($autortas) {
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"l2vpn evpn"}}, "route-target import $autortas:$vrfvxlan");
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"l2vpn evpn"}}, "route-target export $autortas:$vrfvxlan");
    }

    my $is_gateway = $exitnodes->{$local_node};

    if ($is_gateway) {

	if (!$exitnodes_local_routing) {
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
	}

	@controller_config = ();
	#add default originate to announce 0.0.0.0/0 type5 route in evpn
	push @controller_config, "default-originate ipv4";
	push @controller_config, "default-originate ipv6";
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"l2vpn evpn"}}, @controller_config);
    } elsif ($advertisesubnets) {

	@controller_config = ();
	#redistribute connected networks
	push @controller_config, "redistribute connected";
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"ipv4 unicast"}}, @controller_config);
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"ipv6 unicast"}}, @controller_config);

	@controller_config = ();
	#advertise connected networks type5 route in evpn
	push @controller_config, "advertise ipv4 unicast";
	push @controller_config, "advertise ipv6 unicast";
	push(@{$config->{frr}->{router}->{"bgp $asn vrf $vrf"}->{"address-family"}->{"l2vpn evpn"}}, @controller_config);
    }

    return $config;
}

sub generate_controller_vnet_config {
    my ($class, $plugin_config, $controller, $zone, $zoneid, $vnetid, $config) = @_;

    my $exitnodes = $zone->{'exitnodes'};
    my $exitnodes_local_routing = $zone->{'exitnodes-local-routing'};

    return if !$exitnodes_local_routing;

    my $local_node = PVE::INotify::nodename();
    my $is_gateway = $exitnodes->{$local_node};
    
    return if !$is_gateway;

    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid, 1);
    my @controller_config = ();
    foreach my $subnetid (sort keys %{$subnets}) {
        my $subnet = $subnets->{$subnetid};
	my $cidr = $subnet->{cidr};
	push @controller_config, "ip route $cidr 10.255.255.2 xvrf_$zoneid";
    }
    push(@{$config->{frr}->{''}}, @controller_config);
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

    # we can only have 1 evpn controller / 1 asn by server

    my $controllernb = 0;
    foreach my $id (keys %{$controller_cfg->{ids}}) {
	next if $id eq $controllerid;
	my $controller = $controller_cfg->{ids}->{$id};
	next if $controller->{type} ne "evpn";
	$controllernb++;
	die "only 1 global evpn controller can be defined" if $controllernb > 1;
    }
}

sub find_bgp_controller {
    my ($nodename, $controller_cfg) = @_;

    my $controller = undef;
    foreach my $id  (keys %{$controller_cfg->{ids}}) {
        $controller = $controller_cfg->{ids}->{$id};
        next if $controller->{type} ne 'bgp';
        next if $controller->{node} ne $nodename;
	last;
    }

    return $controller;
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

    if ($a =~ /bgp (\d+)$/) {
	$a_val = 2;
    }

    if ($b =~ /bgp (\d+)$/) {
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

   # FIXME: make this generic
   my $paddinglevel = undef;
   if ($level == 1 || $level == 2) {
	$paddinglevel = $level - 1;
   } elsif ($level == 3 || $level ==  4) {
	$paddinglevel = $level - 2;
   }

   my $padding = "";
   $padding = ' ' x ($paddinglevel) if $paddinglevel;

   if (ref $content eq  'HASH') {
	foreach my $key (sort sort_frr_config keys %$content) {
	    if ($parentkey && defined($keylist->{$parentkey})) {
		push @{$final_config}, $padding."!";
		push @{$final_config}, $padding."$parentkey $key";
	    } elsif ($key ne '' && !defined($keylist->{$key})) {
		push @{$final_config}, $padding."$key";
	    }

	    my $option = $content->{$key};
	    generate_frr_recurse($final_config, $option, $key, $level+1);

	    push @{$final_config}, $padding."exit-$parentkey" if $parentkey && defined($exitkeylist->{$parentkey});
	}
    }

    if (ref $content eq 'ARRAY') {
	push @{$final_config}, map { $padding . "$_" } @$content;
    }
}

sub generate_controller_rawconfig {
    my ($class, $plugin_config, $config) = @_;

    my $nodename = PVE::INotify::nodename();

    my $final_config = [];
    push @{$final_config}, "log syslog informational";
    push @{$final_config}, "ip forwarding";
    push @{$final_config}, "ipv6 forwarding";
    push @{$final_config}, "frr defaults datacenter";
    push @{$final_config}, "service integrated-vtysh-config";
    push @{$final_config}, "hostname $nodename";
    push @{$final_config}, "!";

    if (-e "/etc/frr/frr.conf.local") {
	generate_frr_recurse($final_config, $config->{frr}->{vrf}, "vrf", 1);
	push @{$final_config}, "!";

	my $local_conf = file_get_contents("/etc/frr/frr.conf.local");
	chomp ($local_conf);
	push @{$final_config}, $local_conf;
    } else {
	generate_frr_recurse($final_config, $config->{frr}, undef, 0);
    }

    push @{$final_config}, "!";
    push @{$final_config}, "line vty";
    push @{$final_config}, "!";

    my $rawconfig = join("\n", @{$final_config});

    return if !$rawconfig;
    return $rawconfig;
}

sub write_controller_config {
    my ($class, $plugin_config, $config) = @_;

    my $rawconfig = $class->generate_controller_rawconfig($plugin_config, $config);
    return if !$rawconfig;
    return if !-d "/etc/frr";

    file_set_contents("/etc/frr/frr.conf", $rawconfig);
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
	run_command([$bin_path, '--stdout', '--reload', $conf_file], outfunc => {}, errfunc => $err);
    }
}

1;


