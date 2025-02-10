package PVE::API2::Network::SDN::Zones::Content;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Cluster;
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
    description => "List zone content.",
    permissions => {
	check => ['perm', '/sdn/zones/{zone}', ['SDN.Audit'], any => 1],
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    zone => get_standard_option('pve-sdn-zone-id', {
		completion => \&PVE::Network::SDN::Zones::complete_sdn_zone,
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
		statusmsg => {
		    description => "Status details",
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

	my $zoneid = $param->{zone};

	my $res = [];

        my ($zone_status, $vnet_status) = PVE::Network::SDN::status();

	foreach my $id (keys %{$vnet_status}) {
	    if ($vnet_status->{$id}->{zone} eq $zoneid) {
		my $item->{vnet} = $id;
		$item->{status} = $vnet_status->{$id}->{'status'};
		$item->{statusmsg} = $vnet_status->{$id}->{'statusmsg'};
		push @$res,$item;
	    }
        }

	return $res;
    }});

1;
