package PVE::API2::Network::Vnet;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Network::Vnet;
use PVE::Network::Vnet::Plugin;
use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $api_vnet_config = sub {
    my ($cfg, $vnetid) = @_;

    my $scfg = dclone(PVE::Network::Vnet::vnet_config($cfg, $vnetid));
    $scfg->{vnet} = $vnetid;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index', 
    path => '',
    method => 'GET',
    description => "Vnet index.",
    permissions => { 
	description => "Only list entries where you have 'NetworkVnet.Audit' or 'NetworkVnet.Allocate' permissions on '/cluster/network/vnet/<vnet>'",
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    type => { 
		description => "Only list vnet of specific type",
		type => 'string', 
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { vnet => { type => 'string'} },
	},
	links => [ { rel => 'child', href => "{vnet}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();


	my $cfg = PVE::Network::Vnet::config();

	my @sids = PVE::Network::Vnet::vnets_ids($cfg);
	my $res = [];
	foreach my $vnetid (@sids) {
#	    my $privs = [ 'NetworkVnet.Audit', 'NetworkVnet.Allocate' ];
#	    next if !$rpcenv->check_any($authuser, "/cluster/network/vnet/$vnetid", $privs, 1);

	    my $scfg = &$api_vnet_config($cfg, $vnetid);
	    next if $param->{type} && $param->{type} ne $scfg->{type};
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read', 
    path => '{vnet}',
    method => 'GET',
    description => "Read vnet configuration.",
#    permissions => { 
#	check => ['perm', '/cluster/network/vnet/{vnet}', ['NetworkVnet.Allocate']],
#   },

    parameters => {
    	additionalProperties => 0,
	properties => {
	    vnet => get_standard_option('pve-vnet-id'),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Network::Vnet::config();

	return &$api_vnet_config($cfg, $param->{vnet});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '', 
    method => 'POST',
    description => "Create a new network vnet.",
#    permissions => { 
#	check => ['perm', '/cluster/network/vnet', ['NetworkVnet.Allocate']],
#    },
    parameters => PVE::Network::Vnet::Plugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $vnetid = extract_param($param, 'vnet');
	my $type = "vnet";
	my $plugin = PVE::Network::Vnet::Plugin->lookup($type);
	my $opts = $plugin->check_config($vnetid, $param, 1, 1);

        PVE::Network::Vnet::lock_vnet_config(
	    sub {

		my $cfg = PVE::Network::Vnet::config();

		if (my $scfg = PVE::Network::Vnet::vnet_config($cfg, $vnetid, 1)) {
		    die "network vnet ID '$vnetid' already defined\n";
		}

		$cfg->{ids}->{$vnetid} = $opts;

		PVE::Network::Vnet::write_config($cfg);
	    
	    }, "create network vnet failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{vnet}',
    method => 'PUT',
    description => "Update network vnet configuration.",
#    permissions => { 
#	check => ['perm', '/cluster/network/vnet', ['NetworkVnet.Allocate']],
#    },
    parameters => PVE::Network::Vnet::Plugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $vnetid = extract_param($param, 'vnet');
	my $digest = extract_param($param, 'digest');

        PVE::Network::Vnet::lock_vnet_config(
	 sub {

	    my $cfg = PVE::Network::Vnet::config();

	    PVE::SectionConfig::assert_if_modified($cfg, $digest);

	    my $scfg = PVE::Network::Vnet::vnet_config($cfg, $vnetid);
	    my $plugin = PVE::Network::Vnet::Plugin->lookup($scfg->{type});
	    my $opts = $plugin->check_config($vnetid, $param, 0, 1);

	    foreach my $k (%$opts) {
		$scfg->{$k} = $opts->{$k};
	    }
	    PVE::Network::Vnet::write_config($cfg);

	    }, "update network vnet failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{vnet}', # /networkvnets/{vnet}
    method => 'DELETE',
    description => "Delete network vnet configuration.",
#    permissions => { 
#	check => ['perm', '/networkvnets', ['NetworkVnet.Allocate']],
#    },
    parameters => {
    	additionalProperties => 0,
	properties => { 
	    vnet => get_standard_option('pve-vnet-id', {
                completion => \&PVE::Network::Vnet::complete_vnet,
            }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $vnetid = extract_param($param, 'vnet');

        PVE::Network::Vnet::lock_vnet_config(
	    sub {

		my $cfg = PVE::Network::Vnet::config();

		my $scfg = PVE::Network::Vnet::vnet_config($cfg, $vnetid);

		delete $cfg->{ids}->{$vnetid};

		PVE::Network::Vnet::write_config($cfg);

	    }, "delete network vnet failed");


	return undef;
    }});

1;
