#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;

use PVE::Network::SDN::Fabrics;
use PVE::RS::SDN::Fabrics;

my $raw_config = <<'EOF';
wireguard_fabric: wg1

wireguard_node: wg1_pve1
	endpoint 192.0.2.1
	interfaces name=wg0,listen_port=51820,public_key=GgItH+R/ekPfm0Z/0Hg1QD/aBEo9I//gksYk8etky0c=,ip=10.66.0.1/24
	role internal

ospf_fabric: os2
	area 1
	ip_prefix 10.71.0.0/24
	zone s2

ospf_node: os2_pve1
	interfaces name=ens19
	ip 10.71.0.1

ospf_fabric: osn
	area 2
	ip_prefix 10.72.0.0/24
EOF

my sub check {
    my ($config, $node_id) = @_;
    eval {
        PVE::Network::SDN::Fabrics::assert_no_wireguard_interfaces_in_zone_fabrics(
            $config, $node_id,
        );
    };
    my $err = $@;
    return '' if !$err;
    return ref($err)
        ? join(', ', map { "$_: $err->{errors}->{$_}" } sort keys $err->{errors}->%*)
        : $err;
}

my $config = PVE::RS::SDN::Fabrics->config($raw_config);
is(check($config, 'pve1'), '', 'zone fabric without WireGuard interfaces');

$config->add_node({
    fabric_id => 'osn',
    node_id => 'pve1',
    protocol => 'ospf',
    ip => '10.72.0.1',
    interfaces => ['name=wg0'],
});
is(check($config, 'pve1'), '', 'fabric without zone may use a WireGuard interface');

$config->update_node(
    'os2',
    'pve1',
    { protocol => 'ospf', interfaces => ['name=ens19', 'name=wg0'] },
);
like(
    check($config, 'pve1'),
    qr/^interfaces: fabric 'os2' in zone 's2' cannot use the interface 'wg0' of WireGuard fabric 'wg1'/,
    'zone fabric using a WireGuard interface is rejected',
);

$config->add_node({
    fabric_id => 'os2',
    node_id => 'pve2',
    protocol => 'ospf',
    ip => '10.71.0.2',
    interfaces => ['name=wg0'],
});
is(check($config, 'pve2'), '', 'WireGuard interface of another node does not count');

# the other order: the zone fabric uses the interface first, then the WireGuard fabric defines it
$config = PVE::RS::SDN::Fabrics->config($raw_config);
$config->update_node(
    'os2',
    'pve1',
    { protocol => 'ospf', interfaces => ['name=ens19', 'name=wg1'] },
);
is(check($config, 'pve1'), '', 'zone fabric with an interface no WireGuard fabric defines');

$config->update_node(
    'wg1',
    'pve1',
    {
        protocol => 'wireguard',
        role => 'internal',
        endpoint => '192.0.2.1',
        interfaces => [
            'name=wg0,listen_port=51820,public_key=GgItH+R/ekPfm0Z/0Hg1QD/aBEo9I//gksYk8etky0c=',
            'name=wg1,listen_port=51821,public_key=ZzFDfMz9LQJg7EtR3/ZveyEO8/gQGKmE8QWojfWGETY=',
        ],
    },
);
like(
    check($config, 'pve1'),
    qr/fabric 'os2' in zone 's2' cannot use the interface 'wg1' of WireGuard fabric 'wg1'/,
    'WireGuard interface used by a zone fabric is rejected',
);

done_testing();
