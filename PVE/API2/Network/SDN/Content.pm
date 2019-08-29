package PVE::API2::Network::SDN::Content;

use strict;
use warnings;
use Data::Dumper;

use PVE::SafeSyslog;
use PVE::Cluster;
use PVE::Storage;
use PVE::INotify;
use PVE::Exception qw(raise_param_exc);
use PVE::RPCEnvironment;
use PVE::RESTHandler;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    name => 'index', 
    path => '',
    method => 'GET',
    description => "List transportzone content.",
#    permissions => { 
#	check => ['perm', '/sdn/{sdn}', ['SDN.Audit'], any => 1],
#    },
    protected => 1,
    proxyto => 'node',
    parameters => {
    	additionalProperties => 0,
	properties => { 
	    node => get_standard_option('pve-node'),
	    sdn => get_standard_option('pve-sdn-id', {
		completion => \&PVE::Network::SDN::complete_sdn,
            }),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { 
		vnet => {
		    description => "Vnet identifier.",
		    type => 'string',
		},
		status => {
		    description => "Status.",
		    type => 'string',
		    optional => 1,
		},
	    },
	},
	links => [ { rel => 'child', href => "{vnet}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $transportid = $param->{sdn};

	my $res = [];

        my ($transport_status, $vnet_status) = PVE::Network::SDN::status();

	foreach my $id (keys %{$vnet_status}) {
	    if ($vnet_status->{$id}->{transportzone} eq $transportid) {
		my $item->{vnet} = $id;
		$item->{status} = $vnet_status->{$id}->{'status'};
		push @$res,$item;
	    }
        }

	return $res;    
    }});

1;
