#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
use Test::MockModule;

use PVE::Network::SDN::Fabrics;

my $running_cfg = {
    fabrics => {
        ids => {
            test => {
                id => 'test',
                type => 'ospf_fabric',
                area => '0',
                ip_prefix => '172.20.30.0/24',
            },
            test_localhost => {
                id => 'test_localhost',
                type => 'ospf_node',
                ip => '172.20.30.1',
                interfaces => ['name=ens19,ip=172.16.3.10/31'],
            },
        },
    },
};

my $interfaces;
my $inotify = Test::MockModule->new('PVE::INotify');
$inotify->mock(
    nodename => sub { return 'localhost' },
    read_file => sub {
        my ($file) = @_;
        die "unexpected read of '$file'\n" if $file ne 'interfaces';
        return { ifaces => $interfaces };
    },
);

$interfaces = { ens19 => { vrf => 'vrf_blue' } };
eval { PVE::Network::SDN::Fabrics::generate_etc_network_config($running_cfg) };
like(
    $@,
    qr/^interface 'ens19' - cannot set VRF 'vrf_blue' on an interface that is part of a fabric/,
    'VRF on a fabric interface fails',
);

$interfaces = { ens20 => { vrf => 'vrf_blue' }, ens19 => {} };
my $config = eval { PVE::Network::SDN::Fabrics::generate_etc_network_config($running_cfg) };
is($@, '', 'VRF on another interface is allowed');
like($config, qr/^iface ens19 inet static$/m, 'fabric interface config is generated');

my $zone_cfg = {
    fabrics => {
        ids => {
            red => {
                id => 'red',
                type => 'ospf_fabric',
                area => '0',
                ip_prefix => '172.20.30.0/24',
                zone => 'red',
            },
            red_localhost => {
                id => 'red_localhost',
                type => 'ospf_node',
                ip => '172.20.30.1',
                interfaces => ['name=ens19,ip=172.16.3.10/31'],
            },
        },
    },
};

$interfaces = { ens19 => {} };
$config = eval { PVE::Network::SDN::Fabrics::generate_etc_network_config($zone_cfg) };
is($@, '', 'OSPF fabric in a zone VRF is allowed');
like(
    $config,
    qr/^iface ens19 inet static\n(?:\t.*\n)*\tvrf vrf_red$/m,
    'fabric interface is put into the zone VRF',
);

$interfaces = { ens19 => { vrf => 'vrf_red' } };
eval { PVE::Network::SDN::Fabrics::generate_etc_network_config($zone_cfg) };
like(
    $@,
    qr/^interface 'ens19' - cannot set VRF 'vrf_red'/,
    'host VRF on a zone fabric interface fails',
);

done_testing();
