package PVE::API2::Network::SDN::Zones::Status;

use strict;
use warnings;

use File::Path;
use File::Basename;
use PVE::Tools;
use PVE::INotify;
use PVE::Cluster;
use PVE::API2::Network::SDN::Zones::Content;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Exception qw(raise_param_exc);

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Network::SDN::Zones::Content",
    path => '{zone}/content',
});

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Get status for all zones.",
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
		zone => get_standard_option('pve-sdn-zone-id'),
		status => {
		    description => "Status of zone",
		    type => 'string',
		    enum => ['available', 'pending', 'error'],
		},
	    },
	},
	links => [ { rel => 'child', href => "{zone}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $localnode = PVE::INotify::nodename();

	my $res = [];

	my ($zone_status, $vnet_status) = PVE::Network::SDN::status();

	foreach my $id (sort keys %{$zone_status}) {
	    my $item->{zone} = $id;
	    $item->{status} = $zone_status->{$id}->{'status'};
	    push @$res, $item;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'diridx',
    path => '{zone}',
    method => 'GET',
    description => "",
    permissions => {
	check => ['perm', '/sdn/zones/{zone}', ['SDN.Audit'], any => 1],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    zone => get_standard_option('pve-sdn-zone-id'),
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
