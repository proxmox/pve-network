package PVE::Network::SDN::Zones;

use strict;
use warnings;

use JSON;
use Storable qw(dclone);

use PVE::Exception qw(raise_param_exc);
use PVE::Tools qw(extract_param dir_glob_regex run_command);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::IPRoute2;
use PVE::Network;
use PVE::RESTEnvironment qw(log_warn);

use PVE::Network::SDN::Controllers;
use PVE::Network::SDN::Dns;
use PVE::Network::SDN::Fabrics;
use PVE::Network::SDN::Ipams;
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones::VlanPlugin;
use PVE::Network::SDN::Zones::QinQPlugin;
use PVE::Network::SDN::Zones::VxlanPlugin;
use PVE::Network::SDN::Zones::EvpnPlugin;
use PVE::Network::SDN::Zones::FaucetPlugin;
use PVE::Network::SDN::Zones::SimplePlugin;
use PVE::Network::SDN::Zones::Plugin;

PVE::Network::SDN::Zones::VlanPlugin->register();
PVE::Network::SDN::Zones::QinQPlugin->register();
PVE::Network::SDN::Zones::VxlanPlugin->register();
PVE::Network::SDN::Zones::EvpnPlugin->register();
PVE::Network::SDN::Zones::FaucetPlugin->register();
PVE::Network::SDN::Zones::SimplePlugin->register();
PVE::Network::SDN::Zones::Plugin->init();

my $local_network_sdn_file = "/etc/network/interfaces.d/sdn";
my $default_mtu = 1500;

sub sdn_zones_config {
    my ($cfg, $id, $noerr) = @_;

    die "no sdn zone ID specified\n" if !$id;

    my $scfg = $cfg->{ids}->{$id};
    die "sdn zone '$id' does not exist\n" if (!$noerr && !$scfg);

    return $scfg;
}

sub config {
    my ($running) = @_;

    if ($running) {
        my $cfg = PVE::Network::SDN::running_config();
        # Before the first apply there is no section, which equals one without any entries.
        return $cfg->{zones} // { ids => {} };
    }

    return cfs_read_file("sdn/zones.cfg");
}

# Assigns a conntrack zone to a simple zone with a dedicated VRF and removes it from other zones.
#
# A zone that has a conntrack zone in the running config gets that one back if no other zone uses
# it, so that applying keeps the existing connections of the zone, including their NAT bindings,
# in the same conntrack zone. Otherwise, a new conntrack zone follows the highest one in use, also
# in the running config, so that the conntrack zone of another zone that is still active or was
# just deleted is not reused right away.
sub update_ct_zone {
    my ($zone_cfg, $id) = @_;

    my $zone = $zone_cfg->{ids}->{$id};

    if ($zone->{type} ne 'simple' || !$zone->{'dedicated-vrf'}) {
        delete $zone->{'ct-zone'};
        return;
    }

    return if defined($zone->{'ct-zone'});

    my $first = $PVE::Network::SDN::Zones::Plugin::VRF_CT_ZONE_FIRST;
    my $last = $PVE::Network::SDN::Zones::Plugin::VRF_CT_ZONE_LAST;

    my $running_zones = PVE::Network::SDN::Zones::config(1)->{ids};
    my $used = {};
    for my $zones ($zone_cfg->{ids}, $running_zones) {
        for my $zone_id (keys $zones->%*) {
            next if $zone_id eq $id;
            my $ct_zone = $zones->{$zone_id}->{'ct-zone'};
            $used->{$ct_zone} = 1 if defined($ct_zone) && $ct_zone >= $first && $ct_zone <= $last;
        }
    }

    my $running_ct_zone = $running_zones->{$id} ? $running_zones->{$id}->{'ct-zone'} : undef;
    if (
        defined($running_ct_zone)
        && $running_ct_zone >= $first
        && $running_ct_zone <= $last
        && !$used->{$running_ct_zone}
    ) {
        $zone->{'ct-zone'} = $running_ct_zone;
        return;
    }

    my $count = $last - $first + 1;
    die "no conntrack zone left for the VRF of zone '$id'\n" if scalar(keys $used->%*) >= $count;

    my ($highest) = sort { $b <=> $a } keys $used->%*;
    $highest //= $last;

    for my $offset (1 .. $count) {
        my $ct_zone = $first + ($highest - $first + $offset) % $count;
        if (!$used->{$ct_zone}) {
            $zone->{'ct-zone'} = $ct_zone;
            return;
        }
    }
}

sub get_plugin_config {
    my ($vnet) = @_;
    my $zoneid = $vnet->{zone};
    my $zone_cfg = PVE::Network::SDN::Zones::config();
    return $zone_cfg->{ids}->{$zoneid};
}

sub write_config {
    my ($cfg) = @_;

    cfs_write_file("sdn/zones.cfg", $cfg);
}

sub sdn_zones_ids {
    my ($cfg) = @_;

    my @sorted_ids = sort keys $cfg->{ids}->%*;
    return @sorted_ids;
}

sub complete_sdn_zone {
    my ($cmdname, $pname, $cvalue) = @_;

    my $cfg = PVE::Network::SDN::running_config();

    return $cmdname eq 'add' ? [] : [PVE::Network::SDN::sdn_zones_ids($cfg)];
}

sub get_zone {
    my ($zoneid, $running) = @_;

    my $cfg = PVE::Network::SDN::Zones::config($running);

    my $zone = PVE::Network::SDN::Zones::sdn_zones_config($cfg, $zoneid, 1);

    return $zone;
}

sub get_vnets {
    my ($zoneid, $running) = @_;

    return if !$zoneid;

    my $vnets_config = PVE::Network::SDN::Vnets::config($running);
    my $vnets = undef;

    for my $vnetid (keys %{ $vnets_config->{ids} }) {
        my $vnet = PVE::Network::SDN::Vnets::sdn_vnets_config($vnets_config, $vnetid);
        next if !$vnet->{zone} || $vnet->{zone} ne $zoneid;
        $vnets->{$vnetid} = $vnet;
    }

    return $vnets;
}

sub generate_etc_network_config {
    my ($cfg) = @_;

    my $version = $cfg->{version};
    my $vnet_cfg = $cfg->{vnets};
    my $zone_cfg = $cfg->{zones};
    my $subnet_cfg = $cfg->{subnets};
    my $controller_cfg = $cfg->{controllers};
    return if !$vnet_cfg && !$zone_cfg;

    my $vnet_ids = $vnet_cfg ? ($vnet_cfg->{ids} // {}) : {};
    my $zone_ids = $zone_cfg ? ($zone_cfg->{ids} // {}) : {};

    my $interfaces_config = PVE::INotify::read_file('interfaces');
    my $bridge_ports = PVE::IPRoute2::get_bridge_port_mapping();

    #generate configuration
    my $config = {};
    my $nodename = PVE::INotify::nodename();

    for my $zone_id (sort keys %$zone_ids) {
        my $plugin_config = $zone_ids->{$zone_id};
        next if defined($plugin_config->{nodes}) && !$plugin_config->{nodes}->{$nodename};

        my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
        $plugin->generate_zone_config($plugin_config, $zone_id, $config);
    }

    for my $id (sort keys %$vnet_ids) {
        my $vnet = $vnet_ids->{$id};
        my $zone = $vnet->{zone};

        if (!$zone) {
            warn "can't generate vnet '$id': no zone assigned!\n";
            next;
        }

        my $plugin_config = $zone_ids->{$zone};

        if (!defined($plugin_config)) {
            warn "can't generate vnet '$id': zone $zone don't exist\n";
            next;
        }

        next if defined($plugin_config->{nodes}) && !$plugin_config->{nodes}->{$nodename};

        my $controller;
        if (my $controllerid = $plugin_config->{controller}) {
            $controller = $controller_cfg->{ids}->{$controllerid};
        }

        my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
        eval {
            $plugin->generate_sdn_config(
                $plugin_config,
                $zone,
                $id,
                $vnet,
                $controller,
                $controller_cfg,
                $subnet_cfg,
                $interfaces_config,
                $config,
                $bridge_ports,
            );
        };
        if (my $err = $@) {
            warn "zone $zone : vnet $id : $err\n";
            next;
        }
    }

    # Warn about host interfaces in a zone VRF that is no longer generated, e.g. after the zone
    # was deleted. Sourced files are not checked. Only stanzas that set a VRF table define a VRF,
    # e.g. a host stanza that just adds an address to the VRF of a zone does not.
    my $sets_vrf_table = sub {
        my ($options) = @_;
        return grep { m/^vrf[-_]table\s/ } $options->@*;
    };
    my $host_ifaces = $interfaces_config->{ifaces};
    for my $iface (sort keys $host_ifaces->%*) {
        my $vrf = $host_ifaces->{$iface}->{vrf};
        next if !$vrf || $vrf !~ m/^vrf_/;
        next if $sets_vrf_table->($config->{$vrf} // []);

        my $host_vrf = $host_ifaces->{$vrf} // {};
        next if $sets_vrf_table->([map { ($_ // [])->@* } $host_vrf->@{qw(options options6)}]);

        log_warn("host interface '$iface' is configured to use VRF '$vrf', which is not defined"
            . " in /etc/network/interfaces or the SDN configuration of this node");
    }

    my $raw_network_config = "\#version:$version\n";
    foreach my $iface (sort keys %$config) {
        $raw_network_config .= "\n";
        $raw_network_config .= "auto $iface\n";
        $raw_network_config .= "iface $iface\n";
        foreach my $option (@{ $config->{$iface} }) {
            $raw_network_config .= "\t$option\n";
        }
    }

    return $raw_network_config;
}

sub read_etc_network_config_version {
    my $versionstr = PVE::Tools::file_read_firstline($local_network_sdn_file);

    return if !defined($versionstr);

    if ($versionstr =~ m/^\#version:(\d+)$/) {
        return $1;
    }
}

sub ifquery_check {

    my $cmd = ['ifquery', '-a', '-c', '-o', 'json'];

    my $result = '';
    my $reader = sub { $result .= shift };

    eval { run_command($cmd, outfunc => $reader); };

    my $resultjson = decode_json($result);
    my $interfaces = {};

    foreach my $interface (@$resultjson) {
        my $name = $interface->{name};
        $interfaces->{$name} = {
            status => $interface->{status},
            config => $interface->{config},
            config_status => $interface->{config_status},
        };
    }

    return $interfaces;
}

my $warned_about_reload;

sub status {

    my $err_config = undef;

    my $local_version = PVE::Network::SDN::Zones::read_etc_network_config_version();
    my $cfg = PVE::Network::SDN::running_config();
    my $sdn_version = $cfg->{version};

    return if !$sdn_version;

    if (!$local_version) {
        $err_config = "local sdn network configuration is not yet generated, please reload";
        if (!$warned_about_reload) {
            $warned_about_reload = 1;
            warn "$err_config\n";
        }
    } elsif ($local_version < $sdn_version) {
        $err_config = "local sdn network configuration is too old, please reload";
        if (!$warned_about_reload) {
            $warned_about_reload = 1;
            warn "$err_config\n";
        }
    } else {
        $warned_about_reload = 0;
    }

    my $status = ifquery_check();

    my $vnet_cfg = $cfg->{vnets};
    my $zone_cfg = $cfg->{zones};
    my $nodename = PVE::INotify::nodename();

    my $vnet_status = {};
    my $zone_status = {};

    for my $id (sort keys %{ $zone_cfg->{ids} }) {
        next
            if defined($zone_cfg->{ids}->{$id}->{nodes})
            && !$zone_cfg->{ids}->{$id}->{nodes}->{$nodename};

        $zone_status->{$id}->{status} = $err_config ? 'pending' : 'available';
        $zone_status->{$id}->{'zone-type'} = $zone_cfg->{ids}->{$id}->{type};
    }

    foreach my $id (sort keys %{ $vnet_cfg->{ids} }) {
        my $vnet = $vnet_cfg->{ids}->{$id};
        my $zone = $vnet->{zone};
        next if !defined($zone);

        my $plugin_config = $zone_cfg->{ids}->{$zone};

        if (!defined($plugin_config)) {
            $vnet_status->{$id}->{status} = 'error';
            $vnet_status->{$id}->{statusmsg} = "unknown zone '$zone' configured";
            next;
        }

        next if defined($plugin_config->{nodes}) && !$plugin_config->{nodes}->{$nodename};

        $vnet_status->{$id}->{zone} = $zone;
        $vnet_status->{$id}->{status} = 'available';

        if ($err_config) {
            $vnet_status->{$id}->{status} = 'pending';
            $vnet_status->{$id}->{statusmsg} = $err_config;
            next;
        }

        my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
        my $err_msg = $plugin->status($plugin_config, $zone, $id, $vnet, $status);
        if (@{$err_msg} > 0) {
            $vnet_status->{$id}->{status} = 'error';
            $vnet_status->{$id}->{statusmsg} = join(',', @{$err_msg});
            $zone_status->{$zone}->{status} = 'error';
        }
    }

    return ($zone_status, $vnet_status);
}

sub tap_create {
    my ($iface, $bridge) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge, 1);
    if (!$vnet) { # fallback for classic bridge
        PVE::Network::tap_create($iface, $bridge);
        return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->tap_create($plugin_config, $vnet, $iface, $bridge);
}

sub veth_create {
    my ($veth, $vethpeer, $bridge, $hwaddr) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge, 1);
    if (!$vnet) { # fallback for classic bridge
        PVE::Network::veth_create($veth, $vethpeer, $bridge, $hwaddr);
        return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->veth_create($plugin_config, $vnet, $veth, $vethpeer, $bridge, $hwaddr);
}

sub tap_plug {
    my ($iface, $bridge, $tag, $firewall, $trunks, $rate) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge, 1);
    if (!$vnet) { # fallback for classic bridge
        my $interfaces_config = PVE::INotify::read_file('interfaces');
        my $opts = {};
        $opts->{learning} = 0
            if $interfaces_config->{ifaces}->{$bridge}
            && $interfaces_config->{ifaces}->{$bridge}->{'bridge-disable-mac-learning'};
        PVE::Network::tap_plug($iface, $bridge, $tag, $firewall, $trunks, $rate, $opts);
        return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $nodename = PVE::INotify::nodename();

    die "vnet $bridge is not allowed on this node\n"
        if $plugin_config->{nodes} && !defined($plugin_config->{nodes}->{$nodename});

    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->tap_plug($plugin_config, $vnet, $tag, $iface, $bridge, $firewall, $trunks, $rate);
}

sub add_bridge_fdb {
    my ($iface, $macaddr, $bridge) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge, 1);
    if (!$vnet) { # fallback for classic bridge
        PVE::Network::add_bridge_fdb($iface, $macaddr);
        return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->add_bridge_fdb($plugin_config, $iface, $macaddr);
}

sub del_bridge_fdb {
    my ($iface, $macaddr, $bridge) = @_;

    my $vnet = PVE::Network::SDN::Vnets::get_vnet($bridge, 1);
    if (!$vnet) { # fallback for classic bridge
        PVE::Network::del_bridge_fdb($iface, $macaddr);
        return;
    }

    my $plugin_config = get_plugin_config($vnet);
    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
    $plugin->del_bridge_fdb($plugin_config, $iface, $macaddr);
}

sub get_mtu {
    my ($zone_config) = @_;

    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($zone_config->{type});
    return $plugin->get_mtu($zone_config) // $default_mtu;
}

=head3 api_get_zone($cfg, $id)

Returns the zone with ID C<$id> from C<$cfg>, with API-specific fields (zone,
digest) added.

Throws an error if the zone does not exist.

=cut

sub api_get_zone {
    my ($cfg, $id) = @_;

    my $zone = eval { PVE::Network::SDN::Zones::sdn_zones_config($cfg, $id) };
    raise_param_exc({ zone => "could not find zone '$id'" }) if $@;

    $zone = dclone($zone);
    $zone->{zone} = $id;
    $zone->{digest} = $cfg->{digest};

    if ($zone->{nodes}) {
        $zone->{nodes} =
            PVE::Network::SDN::encode_value($zone->{type}, 'nodes', $zone->{nodes});
    }

    if ($zone->{exitnodes}) {
        $zone->{exitnodes} =
            PVE::Network::SDN::encode_value($zone->{type}, 'exitnodes', $zone->{exitnodes});
    }

    my $pending = $zone->{pending};
    if ($pending->{nodes}) {
        $pending->{nodes} =
            PVE::Network::SDN::encode_value($zone->{type}, 'nodes', $pending->{nodes});
    }

    if ($pending->{exitnodes}) {
        $pending->{exitnodes} =
            PVE::Network::SDN::encode_value($zone->{type}, 'exitnodes', $pending->{exitnodes});
    }

    return $zone;
}

=head3 api_get_zone_checked($zoneid, $privs, $cfg)

Returns the API-formatted version from C<api_get_zone()>, if the current user
has the permissions specified in C<$privs> and the zone exists in the
configuration.

It uses the passed C<$cfg> which can either be a pending, running or normal SDN
configuration. The permission check honors pending changes to the parent zone.

The same error message is returned in all cases, preventing information leaks.

=cut

sub api_get_zone_checked {
    my ($zoneid, $privs, $cfg) = @_;

    $cfg = config() if !defined($cfg);

    my $rpcenv = PVE::RPCEnvironment::get();
    my $authuser = $rpcenv->get_user();

    raise_param_exc({ zone => "could not find zone '$zoneid'" })
        if !$rpcenv->check_any($authuser, "/sdn/zones/$zoneid", $privs, 1);

    return api_get_zone($cfg, $zoneid);
}

=head3 api_check_route_privs($zone, $old_zone, $rpcenv, $authuser)

Static routes are installed on the zone nodes and can affect the host, e.g. via a host interface
in the VRF, so require C<Sys.Modify> on these nodes to change them.

C<$old_zone> and C<$zone> are the zone configs before and after the change, either may be undef
on create or delete. If the routes, or the nodes or VRF they are installed on, change, the
permission is checked for all nodes that have the routes before or after the change. Zones
without nodes, or with an empty node list, use all cluster nodes.

=cut

sub api_check_route_privs {
    my ($zone, $old_zone, $rpcenv, $authuser) = @_;

    my @nodes;
    for my $z ($zone, $old_zone) {
        next if !$z || !$z->{route} || !$z->{route}->@*;
        my @zone_nodes = $z->{nodes} ? keys $z->{nodes}->%* : ();
        # an empty node list is not stored, so the zone applies to all nodes
        @zone_nodes = PVE::Cluster::get_nodelist()->@* if !@zone_nodes;
        push @nodes, @zone_nodes;
    }
    return if !@nodes;

    if ($zone && $old_zone) {
        my $changed = 0;
        for my $key ('route', 'nodes', 'dedicated-vrf') {
            my $new = PVE::Network::SDN::encode_value(undef, $key, $zone->{$key}) // '';
            my $old = PVE::Network::SDN::encode_value(undef, $key, $old_zone->{$key}) // '';
            $changed = 1 if $new ne $old;
        }
        return if !$changed;
    }

    $rpcenv = PVE::RPCEnvironment::get() if !defined($rpcenv);
    $authuser = $rpcenv->get_user() if !defined($authuser);

    my %seen;
    for my $node (sort grep { !$seen{$_}++ } @nodes) {
        next if $rpcenv->check_any($authuser, "/nodes/$node", ['Sys.Modify'], 1);
        raise_param_exc({ route => "permission check failed: missing 'Sys.Modify' on node $node" });
    }
}

=head3 api_validate_property_references($zone, $privs, $rpcenv, $authuser)

For properties that reference another SDN entity in C<$zone> this function
checks if they exist and if the C<$authuser> has the permissions in C<$privs>
for that entity.

If C<$authuser> and C<$rpcenv> are not given, they are obtained via
C<PVE::RPCEnvironment::get>.

=cut

sub api_validate_property_references {
    my ($zone, $privs, $rpcenv, $authuser) = @_;

    $rpcenv = PVE::RPCEnvironment::get() if !defined($rpcenv);
    $authuser = $rpcenv->get_user() if !defined($authuser);

    my $dns_config = PVE::Network::SDN::Dns::config();
    my $controller_config = PVE::Network::SDN::Controllers::config();
    my $ipam_config = PVE::Network::SDN::Ipams::config();
    my $fabric_config = PVE::Network::SDN::Fabrics::config();

    if (my $dns = $zone->{dns}) {
        raise_param_exc({ dns => "could not find dns plugin $dns" })
            if !$dns_config->{ids}->{$dns};

        raise_param_exc({ dns => "could not find dns plugin $dns" })
            if !$rpcenv->check_any($authuser, "/sdn/dns/$dns", $privs, 1);
    }

    if (my $dns = $zone->{reversedns}) {
        raise_param_exc({ reversedns => "could not find dns plugin $dns" })
            if !$dns_config->{ids}->{$dns};

        raise_param_exc({ reversedns => "could not find dns plugin $dns" })
            if !$rpcenv->check_any($authuser, "/sdn/dns/$dns", $privs, 1);
    }

    if (my $ipam = $zone->{ipam}) {
        raise_param_exc({ ipam => "could not find ipam plugin $ipam" })
            if $ipam ne 'pve' && !$ipam_config->{ids}->{$ipam};

        raise_param_exc({ ipam => "could not find ipam plugin $ipam" })
            if !$rpcenv->check_any($authuser, "/sdn/ipams/$ipam", $privs, 1);
    }

    if (my $controller = $zone->{controller}) {
        raise_param_exc({ controller => "could not find controller $controller" })
            if !$controller_config->{ids}->{$controller};

        raise_param_exc({ controller => "could not find controller $controller" })
            if !$rpcenv->check_any($authuser, "/sdn/controllers/$controller", $privs, 1);
    }

    if ($zone->{'secondary-controllers'}) {
        for my $controller ($zone->{'secondary-controllers'}->@*) {
            raise_param_exc({ 'secondary-controllers' => "could not find controller $controller" })
                if !$controller_config->{ids}->{$controller};

            raise_param_exc({ 'secondary-controllers' => "could not find controller $controller" })
                if !$rpcenv->check_any($authuser, "/sdn/controllers/$controller", $privs, 1);
        }
    }

    if (my $fabric = $zone->{fabric}) {
        raise_param_exc({ fabric => "could not find fabric $fabric" })
            if !$fabric_config->get_fabric($fabric);

        raise_param_exc({ fabric => "could not find fabric $fabric" })
            if !$rpcenv->check_any($authuser, "/sdn/fabrics/$fabric", $privs, 1);
    }
}

1;

