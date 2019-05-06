package PVE::API2::Network::Network;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Network::Network;
use PVE::Network::Network::Plugin;
use PVE::Network::Network::VlanPlugin;
use PVE::Network::Network::VxlanMulticastPlugin;
use PVE::Network::Network::VnetPlugin;
use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $network_type_enum = PVE::Network::Network::Plugin->lookup_types();

my $api_network_config = sub {
    my ($cfg, $networkid) = @_;

    my $scfg = dclone(PVE::Network::Network::network_config($cfg, $networkid));
    $scfg->{network} = $networkid;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index', 
    path => '',
    method => 'GET',
    description => "Network index.",
    permissions => { 
	description => "Only list entries where you have 'Network.Audit' or 'Network.Allocate' permissions on '/cluster/network/<network>'",
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    type => { 
		description => "Only list network of specific type",
		type => 'string', 
		enum => $network_type_enum,
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { network => { type => 'string'} },
	},
	links => [ { rel => 'child', href => "{network}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();


	my $cfg = PVE::Network::Network::config();

	my @sids = PVE::Network::Network::networks_ids($cfg);
	my $res = [];
	foreach my $networkid (@sids) {
#	    my $privs = [ 'Network.Audit', 'Network.Allocate' ];
#	    next if !$rpcenv->check_any($authuser, "/cluster/network/$networkid", $privs, 1);

	    my $scfg = &$api_network_config($cfg, $networkid);
	    next if $param->{type} && $param->{type} ne $scfg->{type};
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read', 
    path => '{network}',
    method => 'GET',
    description => "Read network configuration.",
#    permissions => { 
#	check => ['perm', '/cluster/network/{network}', ['Network.Allocate']],
#   },

    parameters => {
    	additionalProperties => 0,
	properties => {
	    network => get_standard_option('pve-network-id'),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Network::Network::config();

	return &$api_network_config($cfg, $param->{network});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '', 
    method => 'POST',
    description => "Create a new network object.",
#    permissions => { 
#	check => ['perm', '/cluster/network', ['Network.Allocate']],
#    },
    parameters => PVE::Network::Network::Plugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $networkid = extract_param($param, 'network');

	my $plugin = PVE::Network::Network::Plugin->lookup($type);
	my $opts = $plugin->check_config($networkid, $param, 1, 1);

        PVE::Network::Network::lock_network_config(
	    sub {

		my $cfg = PVE::Network::Network::config();

		my $scfg = undef;
		if ($scfg = PVE::Network::Network::network_config($cfg, $networkid, 1)) {
		    die "network object ID '$networkid' already defined\n";
		}

		$cfg->{ids}->{$networkid} = $opts;
		$plugin->on_update_hook($networkid, $cfg);
		#also verify transport associated to vnet
		if($scfg->{type} eq 'vnet') {
		    my $transportid = $scfg->{transportzone};
		    die "missing transportzone" if !$transportid;
		    my $transport_cfg = $cfg->{ids}->{$transportid};
		    my $transport_plugin = PVE::Network::Network::Plugin->lookup($transport_cfg->{type});
		    $transport_plugin->on_update_hook($transportid, $cfg);
		}

		PVE::Network::Network::write_config($cfg);
	    
	    }, "create network object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'apply_configuration',
    protected => 1,
    path => '',
    method => 'PUT',
    description => "Apply network changes.",
#    permissions => { 
#	check => ['perm', '/cluster/network', ['Network.Allocate']],
#    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	die "no network changes to apply" if !-e "/etc/pve/networks.cfg.new";
	rename("/etc/pve/networks.cfg.new", "/etc/pve/networks.cfg")
	    || die "applying networks.cfg changes failed - $!\n";


	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'revert_configuration',
    protected => 1,
    path => '',
    method => 'DELETE',
    description => "Revert network changes.",
#    permissions => { 
#	check => ['perm', '/cluster/network', ['Network.Allocate']],
#    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	die "no network changes to revert" if !-e "/etc/pve/networks.cfg.new";
	unlink "/etc/pve/networks.cfg.new";

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{network}',
    method => 'PUT',
    description => "Update network object configuration.",
#    permissions => { 
#	check => ['perm', '/cluster/network', ['Network.Allocate']],
#    },
    parameters => PVE::Network::Network::Plugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $networkid = extract_param($param, 'network');
	my $digest = extract_param($param, 'digest');

        PVE::Network::Network::lock_network_config(
	 sub {

	    my $cfg = PVE::Network::Network::config();

	    PVE::SectionConfig::assert_if_modified($cfg, $digest);

	    my $scfg = PVE::Network::Network::network_config($cfg, $networkid);

	    my $plugin = PVE::Network::Network::Plugin->lookup($scfg->{type});
	    my $opts = $plugin->check_config($networkid, $param, 0, 1);

	    foreach my $k (%$opts) {
		$scfg->{$k} = $opts->{$k};
	    }

	    $plugin->on_update_hook($networkid, $cfg);
	    #also verify transport associated to vnet
            if($scfg->{type} eq 'vnet') {
                my $transportid = $scfg->{transportzone};
                die "missing transportzone" if !$transportid;
                my $transport_cfg = $cfg->{ids}->{$transportid};
                my $transport_plugin = PVE::Network::Network::Plugin->lookup($transport_cfg->{type});
                $transport_plugin->on_update_hook($transportid, $cfg);
            }
	    PVE::Network::Network::write_config($cfg);

	    }, "update network object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{network}', # /cluster/network/{network}
    method => 'DELETE',
    description => "Delete network object configuration.",
#    permissions => { 
#	check => ['perm', '/cluster/network', ['Network.Allocate']],
#    },
    parameters => {
    	additionalProperties => 0,
	properties => { 
	    network => get_standard_option('pve-network-id', {
                completion => \&PVE::Network::Network::complete_network,
            }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $networkid = extract_param($param, 'network');

        PVE::Network::Network::lock_network_config(
	    sub {

		my $cfg = PVE::Network::Network::config();

		my $scfg = PVE::Network::Network::network_config($cfg, $networkid);

		my $plugin = PVE::Network::Network::Plugin->lookup($scfg->{type});
		$plugin->on_delete_hook($networkid, $cfg);

		delete $cfg->{ids}->{$networkid};
		PVE::Network::Network::write_config($cfg);

	    }, "delete network object failed");


	return undef;
    }});

1;
