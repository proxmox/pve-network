#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
use Test::MockModule;

use PVE::API2::Network::SDN::Zones;
use PVE::Network::SDN::Zones;

my $running_zones = {};

my $mocked_zones = Test::MockModule->new('PVE::Network::SDN::Zones');
$mocked_zones->mock(
    config => sub {
        my ($running) = @_;
        die "unexpected read of zones.cfg\n" if !$running;
        return { ids => $running_zones };
    },
);

sub vrf_zone {
    my ($ct_zone) = @_;
    my $zone = { type => 'simple', 'dedicated-vrf' => 1 };
    $zone->{'ct-zone'} = $ct_zone if defined($ct_zone);
    return $zone;
}

sub ct_zone_of {
    my ($zones, $id) = @_;
    my $zone_cfg = { ids => $zones };
    PVE::Network::SDN::Zones::update_ct_zone($zone_cfg, $id);
    return $zone_cfg->{ids}->{$id}->{'ct-zone'};
}

is(ct_zone_of({ new => vrf_zone() }, 'new'), 16384, 'first zone VRF gets the first conntrack zone');

is(
    ct_zone_of({ a => vrf_zone(16384), b => vrf_zone(16390), new => vrf_zone() }, 'new'),
    16391,
    'new conntrack zone follows the highest one in use',
);

is(ct_zone_of({ a => vrf_zone(16500) }, 'a'), 16500, 'existing conntrack zone is kept');

is(
    ct_zone_of({ a => { type => 'simple', 'ct-zone' => 16400 } }, 'a'),
    undef,
    'conntrack zone is removed without a dedicated VRF',
);

is(
    ct_zone_of({ a => { type => 'evpn', 'dedicated-vrf' => 1, 'ct-zone' => 16400 } }, 'a'),
    undef,
    'only simple zones get a conntrack zone',
);

$running_zones = { old => vrf_zone(16395) };
is(
    ct_zone_of({ a => vrf_zone(16384), new => vrf_zone() }, 'new'),
    16396,
    'conntrack zone of a zone that is only in the running config is not reused',
);
ok(!exists($running_zones->{new}), 'running config is not mutated for a new zone');

$running_zones = { a => vrf_zone(16384), old => vrf_zone(16395) };
is(
    ct_zone_of({ a => vrf_zone(), b => vrf_zone(16390) }, 'a'),
    16384,
    'zone gets its conntrack zone from the running config back',
);

is(
    ct_zone_of({ a => vrf_zone(), b => vrf_zone(16384) }, 'a'),
    16396,
    'conntrack zone from the running config is not reused if another zone uses it',
);
$running_zones = {};

is(
    ct_zone_of({ a => vrf_zone(17407), b => vrf_zone(16384), new => vrf_zone() }, 'new'),
    16385,
    'allocation wraps around after the last conntrack zone',
);

is(
    ct_zone_of({ a => { type => 'vlan', 'ct-zone' => 17000 }, new => vrf_zone() }, 'new'),
    17001,
    'conntrack zones of other zones are taken into account',
);

is(
    ct_zone_of({ a => vrf_zone(5), new => vrf_zone() }, 'new'),
    16384,
    'conntrack zones out of range are ignored',
);

$running_zones = { a => vrf_zone(5) };
is(
    ct_zone_of({ a => vrf_zone() }, 'a'),
    16384,
    'out of range conntrack zone from the running config is not reused',
);
$running_zones = {};

my $all = { map { ("z$_" => vrf_zone($_)) } 16384 .. 17407 };
eval { ct_zone_of({ %$all, new => vrf_zone() }, 'new') };
like($@, qr/no conntrack zone left/, 'allocation fails if all conntrack zones are in use');

$running_zones = $all;
is(
    ct_zone_of({ %$all, z16384 => vrf_zone() }, 'z16384'),
    16384,
    'zone gets its conntrack zone back when all conntrack zones are in use',
);
$running_zones = {};

for my $method ('create', 'update') {
    my $param = { zone => 'zone0', 'ct-zone' => 16384 };
    $param->{type} = 'simple' if $method eq 'create';

    eval { PVE::API2::Network::SDN::Zones->$method($param) };
    like($@, qr/ct-zone.*assigned automatically/s, "$method rejects setting ct-zone");
}

eval { PVE::API2::Network::SDN::Zones->update({ zone => 'zone0', delete => 'ct-zone' }) };
like($@, qr/ct-zone.*assigned automatically/s, 'update rejects deleting ct-zone');

done_testing();
