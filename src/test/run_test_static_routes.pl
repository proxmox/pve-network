#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Storable qw(dclone);
use Test::More;
use Test::MockModule;

use PVE::API2::Network::SDN::Zones;
use PVE::Network::SDN;

my $routes = [
    'prefix=0.0.0.0/0,via=192.0.2.1,iface=uplink0,distance=20',
    'prefix=::/0,via=fe80::1,iface=uplink0',
    'prefix=10.20.0.0/16,iface=vnet0',
];
my $zones = {
    ids => {
        isolated => {
            type => 'simple',
            'dedicated-vrf' => 1,
            nodes => { localhost => 1 },
            route => $routes,
        },
        plain => {
            type => 'simple',
            route => ['prefix=198.51.100.0/24,via=192.0.2.1'],
        },
        remote => {
            type => 'simple',
            'dedicated-vrf' => 1,
            nodes => { othernode => 1 },
            route => ['prefix=192.0.2.0/24,iface=remote0'],
        },
    },
};

subtest 'route API schema and Rust validation' => sub {
    my $create = PVE::API2::Network::SDN::Zones->map_method_by_name('create');
    my $schema = $create->{parameters}->{properties}->{route};
    is($schema->{type}, 'array', 'API accepts repeatable routes');

    my $errors = {};
    PVE::JSONSchema::check_prop($routes, $schema, 'route', $errors);
    is_deeply($errors, {}, 'default routes and interface-only routes are valid');

    for my $route (
        'via=192.0.2.1',
        'prefix=0.0.0.0/0',
        'prefix=::/0,via=fe80::1',
        'prefix=0.0.0.0/0,via=2001:db8::1',
        'prefix=::/0,via=192.0.2.1',
        'prefix=0.0.0.0/0,via=192.0.2.1,distance=256',
        'prefix=10.0.0.0/33,via=192.0.2.1',
        'prefix=example,via=192.0.2.1',
        'prefix=10.0.0.0/8,iface=-uplink',
    ) {
        my $errors = {};
        PVE::JSONSchema::check_prop([$route], $schema, 'route', $errors);
        ok(scalar(keys %$errors), "reject invalid route: $route");
    }

    for my $method ('index', 'read') {
        my $info = PVE::API2::Network::SDN::Zones->map_method_by_name($method);
        my $properties =
            $method eq 'index'
            ? $info->{returns}->{items}->{properties}
            : $info->{returns}->{properties};
        is_deeply(
            $properties->{route}->{items},
            $schema->{items},
            "$method returns route strings",
        );
        is(
            $properties->{pending}->{properties}->{route}->{type},
            'array',
            "$method pending routes are arrays",
        );
    }

    eval {
        PVE::Network::SDN::Zones::VlanPlugin->check_config(
            'vlanzone',
            { bridge => 'vmbr0', route => $routes },
            1,
            1,
        );
    };
    like($@, qr/unexpected property 'route'/, 'routes are only supported on simple zones');
};

subtest 'repeatable config persistence' => sub {
    my $raw = PVE::Network::SDN::Zones::Plugin->write_config('zones.cfg', dclone($zones));
    is(scalar(() = $raw =~ /^\s+route /gm), 5, 'one config line per route');
    my $parsed = PVE::Network::SDN::Zones::Plugin->parse_config('zones.cfg', $raw);
    ok(!$parsed->{errors}, 'all routes parse without errors');
    is_deeply($parsed->{ids}, $zones->{ids}, 'routes and node restrictions survive round trip');
};

subtest 'pending arrays compare by value' => sub {
    my $running = { zones => dclone($zones) };
    my $configured = dclone($zones);
    my $pending = PVE::Network::SDN::pending_config($running, $configured, 'zones');
    ok(!$pending->{ids}->{isolated}->{state}, 'equal arrays are unchanged');

    $configured->{ids}->{isolated}->{route} = [reverse @$routes];
    $pending = PVE::Network::SDN::pending_config($running, $configured, 'zones');
    ok(!$pending->{ids}->{isolated}->{state}, 'route ordering does not cause pending changes');

    $configured->{ids}->{isolated}->{route} = ['prefix=::/0,iface=vnet1'];
    $pending = PVE::Network::SDN::pending_config($running, $configured, 'zones');
    is($pending->{ids}->{isolated}->{state}, 'changed', 'route modification detected');
    is_deeply(
        $pending->{ids}->{isolated}->{pending}->{route},
        ['prefix=::/0,iface=vnet1'],
        'pending retains an array',
    );

    delete $configured->{ids}->{isolated}->{route};
    $pending = PVE::Network::SDN::pending_config($running, $configured, 'zones');
    is($pending->{ids}->{isolated}->{pending}->{route}, 'deleted', 'route removal detected');
};

my $running = { zones => $zones, controllers => { ids => {} }, vnets => { ids => {} } };
my $sdn = Test::MockModule->new('PVE::Network::SDN');
$sdn->mock(running_config => sub { return $running; });
my $inotify = Test::MockModule->new('PVE::INotify');
$inotify->mock(nodename => sub { return 'localhost'; });
my $controllers = Test::MockModule->new('PVE::Network::SDN::Controllers');
$controllers->mock(read_etc_network_interfaces => sub { return { ifaces => {} }; });
my $frr = Test::MockModule->new('PVE::Network::SDN::Frr');
$frr->mock(local_frr_config_exists => sub { return 0; });
$frr->mock(
    read_local_frr_config => sub { return 'ip prefix-list LOCAL seq 5 permit 203.0.113.0/24'; },
);

subtest 'route-only FRR detection' => sub {
    ok(PVE::Network::SDN::running_config_has_frr(), 'routes without controllers require FRR');
    local $running->{zones} = { ids => { empty => { type => 'simple', route => [] } } };
    ok(!PVE::Network::SDN::running_config_has_frr(), 'empty route array does not require FRR');
};

subtest 'zone routes reach FRR with local config' => sub {
    my $fabric_config = PVE::RS::SDN::Fabrics->running_config({});
    my $route_maps = PVE::RS::SDN::RouteMaps->running_config({});
    my $prefix_lists = PVE::RS::SDN::PrefixLists->running_config({});
    my $raw = PVE::Network::SDN::generate_frr_raw_config(
        $running, $fabric_config, $route_maps, $prefix_lists,
    );
    my $config = join("\n", @$raw);
    like(
        $config,
        qr/^ip route 0\.0\.0\.0\/0 192\.0\.2\.1 uplink0 20 vrf vrf_isolated$/m,
        'IPv4 default route with distance',
    );
    like(
        $config,
        qr/^ipv6 route ::\/0 fe80::1 uplink0 vrf vrf_isolated$/m,
        'IPv6 link-local default route',
    );
    like(
        $config,
        qr/^ip route 10\.20\.0\.0\/16 vnet0 vrf vrf_isolated$/m,
        'interface-only route in zone VRF',
    );
    unlike($config, qr/198\.51\.100\.0/, 'routes of a zone without dedicated VRF are omitted');
    unlike($config, qr/remote0/, 'routes restricted to another node are omitted');
    like(
        $config,
        qr/^ip prefix-list LOCAL seq 5 permit 203\.0\.113\.0\/24$/m,
        'local FRR configuration coexists with zone routes',
    );
};

subtest 'static routes require Sys.Modify on the zone nodes' => sub {
    my $zone_cfg;
    my $allowed = {};
    my $zones_module = Test::MockModule->new('PVE::Network::SDN::Zones');
    $zones_module->mock(
        config => sub { return dclone($zone_cfg); },
        write_config => sub { $zone_cfg = $_[0]; },
        api_validate_property_references => sub { },
    );
    my $config_modules = [
        map {
            my $module = Test::MockModule->new("PVE::Network::SDN::$_");
            $module->mock(config => sub { return { ids => {} }; });
            $module;
        } qw(Controllers Dns Subnets Vnets)
    ];
    my $fabrics_module = Test::MockModule->new('PVE::Network::SDN::Fabrics');
    $fabrics_module->mock(config => sub { return PVE::RS::SDN::Fabrics->running_config({}); });
    my $sdn_module = Test::MockModule->new('PVE::Network::SDN');
    $sdn_module->mock(lock_sdn_config => sub { return $_[0]->(); });
    my $cluster = Test::MockModule->new('PVE::Cluster');
    $cluster->mock(
        check_cfs_quorum => sub { },
        get_nodelist => sub { return ['node1', 'node2']; },
    );
    my $api = Test::MockModule->new('PVE::API2::Network::SDN::Zones');
    $api->mock(create_etc_interfaces_sdn_dir => sub { });

    my $rpcenv = Test::MockModule->new('PVE::RPCEnvironment');
    $rpcenv->mock(
        get => sub { return bless {}, 'PVE::RPCEnvironment'; },
        get_user => sub { return 'delegate@pve'; },
        check_any => sub {
            my ($self, $user, $path, $privs, $noerr) = @_;
            return 1 if $allowed->{$path};
            die "permission check failed\n" if !$noerr;
            return 0;
        },
    );

    my $call = sub {
        my ($method, $param) = @_;
        eval { PVE::API2::Network::SDN::Zones->$method(dclone($param)) };
        return $@;
    };
    my $route = 'prefix=0.0.0.0/0,via=192.0.2.1';
    my $missing = qr/missing 'Sys.Modify' on node/;

    my $reset = sub {
        $allowed = {};
        $zone_cfg = {
            ids => {
                plain => { type => 'simple' },
                routed => { type => 'simple', 'dedicated-vrf' => 1, route => [$route] },
                pinned => {
                    type => 'simple',
                    'dedicated-vrf' => 1,
                    nodes => { node1 => 1 },
                    route => [$route],
                },
            },
        };
    };

    $reset->();
    like(
        $call->(
            'create',
            { zone => 'new', type => 'simple', 'dedicated-vrf' => 1, route => [$route] },
        ),
        $missing,
        'create with routes requires Sys.Modify',
    );
    ok(!$zone_cfg->{ids}->{new}, 'rejected zone is not created');
    is(
        $call->('create', { zone => 'new', type => 'simple' }),
        '',
        'create without routes does not require Sys.Modify',
    );

    like(
        $call->('update', { zone => 'plain', 'dedicated-vrf' => 1, route => [$route] }),
        $missing,
        'adding routes requires Sys.Modify',
    );
    ok(!$zone_cfg->{ids}->{plain}->{route}, 'rejected route is not stored');
    like(
        $call->('update', { zone => 'routed', delete => 'route' }),
        $missing,
        'removing routes requires Sys.Modify',
    );
    like(
        $call->('update', { zone => 'routed', nodes => 'node1' }),
        $missing,
        'changing the nodes of a zone with routes requires Sys.Modify',
    );
    like(
        $call->('update', { zone => 'routed', delete => 'dedicated-vrf' }),
        qr/zone still has static routes/,
        'the dedicated VRF of a zone with routes cannot be disabled',
    );
    like($call->('delete', { zone => 'routed' }), $missing, 'deleting a zone with routes');
    is(
        $call->('update', { zone => 'routed', mtu => 1400 }),
        '',
        'unrelated changes are allowed',
    );
    is(
        $call->('update', { zone => 'plain', mtu => 1400 }),
        '',
        'zones without routes unaffected',
    );
    is($call->('delete', { zone => 'plain' }), '', 'deleting a zone without routes');

    $allowed->{'/nodes/node1'} = 1;
    like(
        $call->(
            'update',
            { zone => 'routed', route => [$route, 'prefix=::/0,via=2001:db8::1'] },
        ),
        qr/missing 'Sys.Modify' on node node2/,
        'zones without nodes require Sys.Modify on all cluster nodes',
    );
    is(
        $call->('update', { zone => 'pinned', route => ['prefix=::/0,via=2001:db8::1'] }),
        '',
        'Sys.Modify on the zone nodes is sufficient',
    );
    like(
        $call->('update', { zone => 'pinned', nodes => 'node1,node2' }),
        qr/missing 'Sys.Modify' on node node2/,
        'adding a node to a zone with routes requires Sys.Modify on it',
    );
    like(
        $call->('update', { zone => 'pinned', nodes => '' }),
        qr/missing 'Sys.Modify' on node node2/,
        'an empty node list applies to all nodes',
    );

    $allowed->{'/nodes/node2'} = 1;
    like(
        $call->('create', { zone => 'novrf', type => 'simple', route => [$route] }),
        qr/static routes require a dedicated VRF/,
        'create with routes requires a dedicated VRF',
    );
    like(
        $call->('update', { zone => 'new', route => [$route] }),
        qr/static routes require a dedicated VRF/,
        'adding routes requires a dedicated VRF',
    );
    is(
        $call->('update', { zone => 'new', 'dedicated-vrf' => 1, route => [$route] }),
        '',
        'allowed with Sys.Modify',
    );
    is_deeply($zone_cfg->{ids}->{new}->{route}, [$route], 'route stored');
    is($call->('delete', { zone => 'routed' }), '', 'delete allowed with Sys.Modify');
};

done_testing();
