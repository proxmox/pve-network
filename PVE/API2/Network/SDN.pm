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
	check => ['perm', '/', [ 'Sys.Audit' ]],
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


1;
