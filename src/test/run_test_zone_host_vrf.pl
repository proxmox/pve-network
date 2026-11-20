#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
use Test::MockModule;

use PVE::INotify;
use PVE::Network::SDN::Zones;

my $interfaces_config;
my $inotify = Test::MockModule->new('PVE::INotify');
$inotify->mock(
    nodename => sub { return 'localhost' },
    read_file => sub {
        my ($file) = @_;
        die "unexpected read of '$file'\n" if $file ne 'interfaces';
        return $interfaces_config;
    },
);

my $iproute = Test::MockModule->new('PVE::IPRoute2');
$iproute->mock(get_bridge_port_mapping => sub { return {} });

my @warnings;
my $zones = Test::MockModule->new('PVE::Network::SDN::Zones');
$zones->mock(log_warn => sub { push @warnings, $_[0] });

my sub warnings_for {
    my ($zone, $interfaces) = @_;

    open(my $fh, '<', \$interfaces) or die "cannot open interfaces string - $!\n";
    $interfaces_config = PVE::INotify::__read_etc_network_interfaces($fh, undef, undef);
    close($fh);

    my $cfg = {
        version => 1,
        zones => { ids => { blue => { type => 'simple', 'dedicated-vrf' => 1, %$zone } } },
        vnets => { ids => {} },
    };

    @warnings = ();
    PVE::Network::SDN::Zones::generate_etc_network_config($cfg);
    return [@warnings];
}

my $uplink = <<'EOF';
auto eno1
iface eno1 inet static
	address 192.0.2.2/24
	vrf vrf_blue
EOF

my $other_node = { nodes => { other => 1 } };

is_deeply(warnings_for({}, $uplink), [], 'no warning while the zone generates the VRF');

my $warnings = warnings_for($other_node, $uplink);
is(scalar(@$warnings), 1, 'one warning once the zone VRF is gone');
like(
    $warnings->[0],
    qr/^host interface 'eno1' is configured to use VRF 'vrf_blue', which is not defined/,
    'warning names the interface and VRF',
);

my $address_only = <<'EOF';

auto vrf_blue
iface vrf_blue inet static
	address 198.51.100.1/32
EOF
is(
    scalar(warnings_for($other_node, $uplink . $address_only)->@*),
    1,
    'a host stanza that does not set a VRF table does not define the VRF',
);

for my $option ('vrf-table auto', 'vrf_table 100') {
    my $host_vrf = <<"EOF";

auto vrf_blue
iface vrf_blue inet manual
	$option
EOF
    is_deeply(
        warnings_for($other_node, $uplink . $host_vrf),
        [],
        "no warning for a host VRF defined with '$option'",
    );
}

my $other_vrf = <<'EOF';
auto eno1
iface eno1 inet static
	address 192.0.2.2/24
	vrf mgmt
EOF
is_deeply(warnings_for($other_node, $other_vrf), [], 'VRFs not named like a zone VRF are ignored');

done_testing();
