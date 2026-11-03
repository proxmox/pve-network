#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::MockModule;
use Test::More;

use PVE::Network::SDN;
use PVE::Network::SDN::Subnets;
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones;

my $running_config = {};
my $sdn_module = Test::MockModule->new('PVE::Network::SDN');
$sdn_module->redefine(running_config => sub { return $running_config });

# a VNet and zone that exist only in the configuration that was not applied yet
my $vnets_module = Test::MockModule->new('PVE::Network::SDN::Vnets');
$vnets_module->redefine(
    cfs_read_file => sub { return { ids => { pending => { zone => 'pending' } } } });
my $zones_module = Test::MockModule->new('PVE::Network::SDN::Zones');
$zones_module->redefine(cfs_read_file => sub { return { ids => { pending => {} } } });

my $rpcenv_module = Test::MockModule->new('PVE::RPCEnvironment');
$rpcenv_module->redefine(get => sub { return bless {}, 'TestRPCEnvironment' });

package TestRPCEnvironment {
    sub get_user { return 'root@pam' }
    sub check_any { return 1 }
}

my $getters = {
    Subnets => \&PVE::Network::SDN::Subnets::config,
    Vnets => \&PVE::Network::SDN::Vnets::config,
    Zones => \&PVE::Network::SDN::Zones::config,
};
for my $module (sort keys $getters->%*) {
    my $config = $getters->{$module}->(1);
    is_deeply($config, { ids => {} }, "running $module config is empty before the first apply");
}

eval {
    PVE::Network::SDN::Vnets::api_get_vnet_checked(
        'pending',
        ['SDN.Audit'],
        PVE::Network::SDN::Vnets::config(1),
    );
};
like($@, qr/could not find vnet 'pending'/, 'running config does not fall back to pending VNets');

$running_config = { vnets => { ids => { applied => { zone => 'applied' } } } };
my $vnet = PVE::Network::SDN::Vnets::api_get_vnet_checked(
    'applied',
    ['SDN.Audit'],
    PVE::Network::SDN::Vnets::config(1),
);
is($vnet->{vnet}, 'applied', 'applied VNet is found in the running config');

done_testing();
