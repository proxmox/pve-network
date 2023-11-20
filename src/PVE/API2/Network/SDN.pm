package PVE::API2::Network::SDN;

use strict;
use warnings;

use PVE::Cluster qw(cfs_lock_file cfs_read_file cfs_write_file);
use PVE::Exception qw(raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::SafeSyslog;
use PVE::Tools qw(run_command);
use PVE::Network::SDN;

use PVE::API2::Network::SDN::Controllers;
use PVE::API2::Network::SDN::Vnets;
use PVE::API2::Network::SDN::Zones;
use PVE::API2::Network::SDN::Ipams;
use PVE::API2::Network::SDN::Dns;

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

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Network::SDN::Ipams",
    path => 'ipams',
});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Network::SDN::Dns",
    path => 'dns',
});

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Directory index.",
    permissions => {
	check => ['perm', '/sdn', [ 'SDN.Audit' ]],
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
	    { id => 'ipams' },
	    { id => 'dns' },
	];

	return $res;
    }});

my $create_reload_network_worker = sub {
    my ($nodename) = @_;

    # FIXME: how to proxy to final node ?
    my $upid;
    print "$nodename: reloading network config\n";
    run_command(['pvesh', 'set', "/nodes/$nodename/network"], outfunc => sub {
	my $line = shift;
	if ($line =~ /["']?(UPID:[^\s"']+)["']?$/) {
	    $upid = $1;
	}
    });
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

	PVE::Network::SDN::commit_config();

        my $code = sub {
            $rpcenv->{type} = 'priv'; # to start tasks in background
	    PVE::Cluster::check_cfs_quorum();
	    my $nodelist = PVE::Cluster::get_nodelist();
	    for my $node (@$nodelist) {
		my $pid = eval { $create_reload_network_worker->($node) };
		warn $@ if $@;
	    }

	    # FIXME: use libpve-apiclient (like in cluster join) to create
	    # tasks and moitor the tasks.

	    return;
        };

        return $rpcenv->fork_worker('reloadnetworkall', undef, $authuser, $code);

    }});


1;
