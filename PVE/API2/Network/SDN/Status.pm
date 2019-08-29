package PVE::API2::Network::SDN::Status;

use strict;
use warnings;

use File::Path;
use File::Basename;
use PVE::Tools;
use PVE::INotify;
use PVE::Cluster;
use PVE::API2::Network::SDN::Content;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Exception qw(raise_param_exc);

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Network::SDN::Content", 
    path => '{sdn}/content',
});

__PACKAGE__->register_method ({
    name => 'index', 
    path => '',
    method => 'GET',
    description => "Get status for all transportzones.",
    permissions => { 
	description => "Only list entries where you have 'SDN.Audit'",
	user => 'all',
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node')
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		sdn => get_standard_option('pve-sdn-id'),
		status => {
		    description => "Status of transportzone",
		    type => 'string',
		},
	    },
	},
	links => [ { rel => 'child', href => "{sdn}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $localnode = PVE::INotify::nodename();

	my $res = [];

        my ($transport_status, $vnet_status) = PVE::Network::SDN::status();

        foreach my $id (keys %{$transport_status}) {
	    my $item->{sdn} = $id;
	    $item->{status} = $transport_status->{$id}->{'status'};
	    push @$res,$item;
        }

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'diridx',
    path => '{sdn}', 
    method => 'GET',
    description => "",
#    permissions => { 
#	check => ['perm', '/sdn/{sdn}', ['SDN.Audit'], any => 1],
#    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    sdn => get_standard_option('pve-sdn-id'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		subdir => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{subdir}" } ],
    },
    code => sub {
	my ($param) = @_;
	my $res = [
	    { subdir => 'content' },
	    ];
	
	return $res;
    }});

1;
