package PVE::API2::Network::SDN;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools;
use PVE::Cluster qw(cfs_lock_file cfs_read_file cfs_write_file);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Exception qw(raise_param_exc);
use PVE::API2::Network::SDN::Vnets;
use PVE::API2::Network::SDN::Zones;
use PVE::API2::Network::SDN::Controllers;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Network::SDN::Vnets",  
    path => 'vnets',
			      });

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Network::SDN::Zones",  
    path => 'zones',
			      });

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Network::SDN::Controllers",  
    path => 'controllers',
});

__PACKAGE__->register_method({
    name => 'index', 
    path => '', 
    method => 'GET',
    description => "Directory index.",
    permissions => {
	check => ['perm', '/', [ 'SDN.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		id => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{id}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $res = [ 
	    { id => 'vnets' },
	    { id => 'zones' },
	    { id => 'controllers' },
	];

	return $res;
    }});

my $create_reload_network_worker = sub {
    my ($nodename) = @_;

    #fixme: how to proxy to final node ?
    my $upid = PVE::Tools::run_command(['pvesh', 'set', "/nodes/$nodename/network"]);
    #my $upid = PVE::API2::Network->reload_network_config(node => $nodename});
    my $res = PVE::Tools::upid_decode($upid);

    return $res->{pid};
};

__PACKAGE__->register_method ({
    name => 'reload',
    protected => 1,
    path => '',
    method => 'PUT',
    description => "Apply sdn controller changes && reload.",
    permissions => {
       check => ['perm', '/sdn', ['SDN.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
    },
    returns => {
        type => 'string',
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

	if (-e "/etc/pve/sdn/controllers.cfg.new") {
	    rename("/etc/pve/sdn/controllers.cfg.new", "/etc/pve/sdn/controllers.cfg")
		|| die "applying sdn/controllers.cfg changes failed - $!\n";
	}

	if (-e "/etc/pve/sdn/zones.cfg.new") {
	    rename("/etc/pve/sdn/zones.cfg.new", "/etc/pve/sdn/zones.cfg")
		|| die "applying sdn/zones.cfg changes failed - $!\n";
	}

	if (-e "/etc/pve/sdn/vnets.cfg.new") {
	    rename("/etc/pve/sdn/vnets.cfg.new", "/etc/pve/sdn/vnets.cfg")
		|| die "applying sdn/vnets.cfg changes failed - $!\n";
	}

        my $code = sub {
            $rpcenv->{type} = 'priv'; # to start tasks in background
	    PVE::Cluster::check_cfs_quorum();
	    my $nodelist = PVE::Cluster::get_nodelist();
	    foreach my $node (@$nodelist) {

		my $pid;
		eval { $pid = &$create_reload_network_worker($node); };
		warn $@ if $@;
		next if !$pid;
	    }
	    return;
        };

        return $rpcenv->fork_worker('reloadnetworkall', undef, $authuser, $code);

    }});


1;
