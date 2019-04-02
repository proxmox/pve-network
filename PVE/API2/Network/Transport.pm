package PVE::API2::Network::Transport;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Network::Transport;
use PVE::Network::Transport::Plugin;
use PVE::Network::Transport::VlanPlugin;
use PVE::Network::Transport::VxlanMulticastPlugin;
use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $transport_type_enum = PVE::Network::Transport::Plugin->lookup_types();

my $api_transport_config = sub {
    my ($cfg, $transportid) = @_;

    my $scfg = dclone(PVE::Network::Transport::transport_config($cfg, $transportid));
    $scfg->{transport} = $transportid;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index', 
    path => '',
    method => 'GET',
    description => "Transport index.",
    permissions => { 
	description => "Only list entries where you have 'NetworkTransport.Audit' or 'NetworkTransport.Allocate' permissions on '/cluster/network/transport/<transport>'",
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    type => { 
		description => "Only list transport of specific type",
		type => 'string', 
		enum => $transport_type_enum,
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { transport => { type => 'string'} },
	},
	links => [ { rel => 'child', href => "{transport}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();


	my $cfg = PVE::Network::Transport::config();

	my @sids = PVE::Network::Transport::transports_ids($cfg);
	my $res = [];
	foreach my $transportid (@sids) {
#	    my $privs = [ 'NetworkTransport.Audit', 'NetworkTransport.Allocate' ];
#	    next if !$rpcenv->check_any($authuser, "/cluster/network/transport/$transportid", $privs, 1);

	    my $scfg = &$api_transport_config($cfg, $transportid);
	    next if $param->{type} && $param->{type} ne $scfg->{type};
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read', 
    path => '{transport}',
    method => 'GET',
    description => "Read transport configuration.",
#    permissions => { 
#	check => ['perm', '/cluster/network/transport/{transport}', ['NetworkTransport.Allocate']],
#   },

    parameters => {
    	additionalProperties => 0,
	properties => {
	    transport => get_standard_option('pve-transport-id'),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Network::Transport::config();

	return &$api_transport_config($cfg, $param->{transport});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '', 
    method => 'POST',
    description => "Create a new network transport.",
#    permissions => { 
#	check => ['perm', '/cluster/network/transport', ['NetworkTransport.Allocate']],
#    },
    parameters => PVE::Network::Transport::Plugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $transportid = extract_param($param, 'transport');

	my $plugin = PVE::Network::Transport::Plugin->lookup($type);
	my $opts = $plugin->check_config($transportid, $param, 1, 1);

        PVE::Network::Transport::lock_transport_config(
	    sub {

		my $cfg = PVE::Network::Transport::config();

		if (my $scfg = PVE::Network::Transport::transport_config($cfg, $transportid, 1)) {
		    die "network transport ID '$transportid' already defined\n";
		}

		$cfg->{ids}->{$transportid} = $opts;

		#improveme:
		#check local configuration of all nodes for conflict

		PVE::Network::Transport::write_config($cfg);
	    
	    }, "create network transport failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{transport}',
    method => 'PUT',
    description => "Update network transport configuration.",
#    permissions => { 
#	check => ['perm', '/cluster/network/transport', ['NetworkTransport.Allocate']],
#    },
    parameters => PVE::Network::Transport::Plugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $transportid = extract_param($param, 'transport');
	my $digest = extract_param($param, 'digest');

        PVE::Network::Transport::lock_transport_config(
	 sub {

	    my $cfg = PVE::Network::Transport::config();

	    PVE::SectionConfig::assert_if_modified($cfg, $digest);

	    my $scfg = PVE::Network::Transport::transport_config($cfg, $transportid);

	    my $plugin = PVE::Network::Transport::Plugin->lookup($scfg->{type});
	    my $opts = $plugin->check_config($transportid, $param, 0, 1);

	    foreach my $k (%$opts) {
		$scfg->{$k} = $opts->{$k};
	    }
	    #improveme:
            #add vlan/vxlan check on existingvnets
	    #check local configuration of all nodes for conflict
	    PVE::Network::Transport::write_config($cfg);

	    }, "update network transport failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{transport}', # /cluster/network/transport/{transport}
    method => 'DELETE',
    description => "Delete network transport configuration.",
#    permissions => { 
#	check => ['perm', '/cluster/network/transport', ['NetworkTransport.Allocate']],
#    },
    parameters => {
    	additionalProperties => 0,
	properties => { 
	    transport => get_standard_option('pve-transport-id', {
                completion => \&PVE::Network::Transport::complete_transport,
            }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $transportid = extract_param($param, 'transport');

        PVE::Network::Transport::lock_transport_config(
	    sub {

		my $cfg = PVE::Network::Transport::config();

		my $scfg = PVE::Network::Transport::transport_config($cfg, $transportid);

#		my $plugin = PVE::Network::Transport::Plugin->lookup($scfg->{type});
#		$plugin->on_delete_hook($transportid, $scfg);

		delete $cfg->{ids}->{$transportid};
		#improveme:
 		#check that vnet don't use this transport
		PVE::Network::Transport::write_config($cfg);

	    }, "delete network transport failed");


	return undef;
    }});

1;
