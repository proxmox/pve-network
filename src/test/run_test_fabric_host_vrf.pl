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

my @warnings;
my $fabrics = Test::MockModule->new('PVE::Network::SDN::Fabrics');
$fabrics->mock(log_warn => sub { push @warnings, $_[0] });

$interfaces = { ens19 => { vrf => 'vrf_blue' } };
my $config = eval { PVE::Network::SDN::Fabrics::generate_etc_network_config($running_cfg) };
is($@, '', 'VRF on a fabric interface does not fail');
is(scalar(@warnings), 1, 'VRF on a fabric interface warns once');
like(
    $warnings[0],
    qr/^interface 'ens19' has host VRF 'vrf_blue'/,
    'warning names the interface and VRF',
);
like($config, qr/^iface ens19 inet static$/m, 'fabric interface config is still generated');

@warnings = ();
$interfaces = { ens20 => { vrf => 'vrf_blue' }, ens19 => {} };
$config = eval { PVE::Network::SDN::Fabrics::generate_etc_network_config($running_cfg) };
is($@, '', 'VRF on another interface is allowed');
is(scalar(@warnings), 0, 'VRF on another interface does not warn');
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

@warnings = ();
$interfaces = { ens19 => {} };
$config = eval { PVE::Network::SDN::Fabrics::generate_etc_network_config($zone_cfg) };
is($@, '', 'OSPF fabric in a zone VRF is allowed');
like(
    $config,
    qr/^iface ens19 inet static\n(?:\t.*\n)*\tvrf vrf_red$/m,
    'fabric interface is put into the zone VRF',
);

is(scalar(@warnings), 0, 'zone fabric without host VRF does not warn');
my $zone_config = $config;

$interfaces = { ens19 => { vrf => 'vrf_blue' } };
$config = eval { PVE::Network::SDN::Fabrics::generate_etc_network_config($zone_cfg) };
is($@, '', 'other host VRF on a zone fabric interface does not fail');
is(scalar(@warnings), 1, 'other host VRF on a zone fabric interface warns once');
like($warnings[0], qr/^interface 'ens19' has host VRF 'vrf_blue';/, 'warning names the host VRF');
is($config, $zone_config, 'zone fabric config is the same as without host VRF');

@warnings = ();
$interfaces = { ens19 => { vrf => 'vrf_red' } };
$config = eval { PVE::Network::SDN::Fabrics::generate_etc_network_config($zone_cfg) };
is($@, '', 'host VRF on a zone fabric interface does not fail');
is(scalar(@warnings), 1, 'host VRF on a zone fabric interface warns once');
like($warnings[0], qr/^interface 'ens19' has host VRF 'vrf_red';/, 'zone warning names the VRF');
like($config, qr/^iface ens19 inet static$/m, 'zone fabric interface config is still generated');

done_testing();
