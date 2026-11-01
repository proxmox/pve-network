#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
use Test::MockModule;

use PVE::API2::Network::SDN::Dns;
use PVE::API2::Network::SDN::Ipams;
use PVE::Network::SDN::Dns;
use PVE::Network::SDN::Ipams;

my $ipams = {
    ids => {
        netbox => { type => 'netbox', url => 'https://netbox', token => 'NETBOX_TOKEN' },
        phpipam => {
            type => 'phpipam',
            url => 'https://phpipam',
            token => 'PHPIPAM_TOKEN',
            section => 1,
        },
    },
    digest => 'digest',
};
my $dns = {
    ids =>
        { powerdns => { type => 'powerdns', url => 'http://powerdns', key => 'POWERDNS_KEY' } },
    digest => 'digest',
};

my $ipam_mock = Test::MockModule->new('PVE::Network::SDN::Ipams');
$ipam_mock->redefine(config => sub { $ipams });
my $dns_mock = Test::MockModule->new('PVE::Network::SDN::Dns');
$dns_mock->redefine(config => sub { $dns });

# privileges of the test user per ACL path
my $privs = {};

my $rpcenv = bless {}, 'PVE::RPCEnvironment::Test';
sub PVE::RPCEnvironment::Test::get_user { return 'user@pve'; }

sub PVE::RPCEnvironment::Test::check_any {
    my ($self, $user, $path, $wanted, $noerr) = @_;
    return scalar(grep { $privs->{$path}->{$_} } @$wanted);
}

sub PVE::RPCEnvironment::Test::check {
    my ($self, $user, $path, $wanted, $noerr) = @_;
    return !grep { !$privs->{$path}->{$_} } @$wanted;
}
my $rpc_mock = Test::MockModule->new('PVE::RPCEnvironment');
$rpc_mock->redefine(get => sub { $rpcenv });

my sub index_by_id {
    my ($api, $id_key) = @_;
    return { map { $_->{$id_key} => $_ } $api->index({})->@* };
}

$privs = {
    '/sdn/ipams/netbox' => { 'SDN.Audit' => 1 },
    '/sdn/ipams/phpipam' => { 'SDN.Audit' => 1, 'SDN.Allocate' => 1 },
    '/sdn/dns/powerdns' => { 'SDN.Audit' => 1 },
};
my $ipam_index = index_by_id('PVE::API2::Network::SDN::Ipams', 'ipam');
my $dns_index = index_by_id('PVE::API2::Network::SDN::Dns', 'dns');

ok(!exists($ipam_index->{netbox}->{token}), 'ipam token hidden without SDN.Allocate');
is($ipam_index->{netbox}->{url}, 'https://netbox', 'ipam url listed without SDN.Allocate');
is($ipam_index->{phpipam}->{token}, 'PHPIPAM_TOKEN', 'ipam token listed with SDN.Allocate');
ok(!exists($dns_index->{powerdns}->{key}), 'dns key hidden without SDN.Allocate');

$privs = { '/sdn/dns/powerdns' => { 'SDN.Allocate' => 1 } };
$ipam_index = index_by_id('PVE::API2::Network::SDN::Ipams', 'ipam');
$dns_index = index_by_id('PVE::API2::Network::SDN::Dns', 'dns');

ok(!%$ipam_index, 'ipams without privileges not listed');
is($dns_index->{powerdns}->{key}, 'POWERDNS_KEY', 'dns key listed with SDN.Allocate');

ok(exists($ipams->{ids}->{netbox}->{token}), 'config itself unchanged');

done_testing();
