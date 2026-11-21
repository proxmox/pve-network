#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
use Test::MockModule;

use PVE::API2::Network::SDN::Dns;
use PVE::API2::Network::SDN::Fabrics;
use PVE::API2::Network::SDN::Fabrics::Node;
use PVE::API2::Network::SDN::Ipams;
use PVE::Network::SDN::Dns;
use PVE::Network::SDN::Fabrics;
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

# fabric nodes as listed by pve-rs, keyed by section ID, current and running config
my $fabric_nodes = {};
my $running_fabric_nodes = {};

sub TestFabricConfig::new {
    my ($class, $nodes) = @_;
    # the API adds the digest to the returned nodes
    return bless { nodes => { map { $_ => { $nodes->{$_}->%* } } keys $nodes->%* } }, $class;
}
sub TestFabricConfig::list_nodes { return $_[0]->{nodes} }
sub TestFabricConfig::list_all { return ({}, $_[0]->{nodes}) }
sub TestFabricConfig::digest { return 'digest' }

my $fabrics_mock = Test::MockModule->new('PVE::Network::SDN::Fabrics');
$fabrics_mock->redefine(
    config => sub {
        my ($running) = @_;
        return TestFabricConfig->new($running ? $running_fabric_nodes : $fabric_nodes);
    },
);

my sub listed_fabric_nodes {
    my ($param) = @_;

    my $id = sub {
        my ($node) = @_;
        my $fabric_id = $node->{fabric_id} // $node->{pending}->{fabric_id};
        my $node_id = $node->{node_id} // $node->{pending}->{node_id};
        return "${fabric_id}_$node_id";
    };

    my $nodes = PVE::API2::Network::SDN::Fabrics::Node->list_nodes({%$param});
    my $all = PVE::API2::Network::SDN::Fabrics->list_all({%$param})->{nodes};

    my $listed = [sort map { $id->($_) } @$nodes];
    is_deeply([sort map { $id->($_) } @$all], $listed, 'both fabric node lists agree');
    return $listed;
}

my $wg_pve1 = { fabric_id => 'wg', node_id => 'pve1', protocol => 'wireguard' };
my $ospf_pve1 = { fabric_id => 'ospf', node_id => 'pve1', protocol => 'ospf' };
my $wg_pve2 = { fabric_id => 'wg', node_id => 'pve2', protocol => 'wireguard' };

$fabric_nodes = { wg_pve1 => $wg_pve1, ospf_pve1 => $ospf_pve1, wg_pve2 => $wg_pve2 };
$running_fabric_nodes = { wg_pve1 => $wg_pve1, wg_pve2 => $wg_pve2 };

$privs = {
    '/sdn/fabrics/wg' => { 'SDN.Audit' => 1 },
    '/nodes/pve1' => { 'Sys.Audit' => 1 },
};
is_deeply(listed_fabric_nodes({}), ['wg_pve1'], 'fabric node listed with fabric and node access');

$privs->{'/sdn/fabrics/ospf'} = { 'SDN.Audit' => 1 };
is_deeply(
    listed_fabric_nodes({}),
    ['ospf_pve1', 'wg_pve1'],
    'node in multiple fabrics listed once per fabric',
);
is_deeply(
    listed_fabric_nodes({ pending => 1 }),
    ['ospf_pve1', 'wg_pve1'],
    'new pending fabric node listed',
);

delete $privs->{'/nodes/pve1'};
is_deeply(listed_fabric_nodes({ pending => 1 }), [], 'fabric nodes not listed without node access');

done_testing();
