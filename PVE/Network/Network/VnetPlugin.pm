package PVE::Network::Network::VnetPlugin;

use strict;
use warnings;
use PVE::Network::Network::Plugin;

use base('PVE::Network::Network::Plugin');

sub type {
    return 'vnet';
}



sub properties {
    return {
	transportzone => {
            type => 'string',
            description => "transportzone id",
	    optional => 1,
	},
	tag => {
            type => 'integer',
            description => "vlan or vxlan id",
	    optional => 1,
	},
        name => {
            type => 'string',
            description => "name of the network",
	    optional => 1,
        },
        mtu => {
            type => 'integer',
            description => "mtu",
	    optional => 1,
        },
        ipv4 => {
            description => "Anycast router ipv4 address.",
            type => 'string', format => 'ipv4',
            optional => 1,
        },
	ipv6 => {
	    description => "Anycast router ipv6 address.",
	    type => 'string', format => 'ipv6',
	    optional => 1,
	},
        mac => {
            type => 'boolean',
            description => "Anycast router mac address",
	    optional => 1,
        }
    };
}

sub options {
    return {
        transportzone => { optional => 1 },
        tag => { optional => 1 },
        name => { optional => 1 },
        ipv4 => { optional => 1 },
        ipv6 => { optional => 1 },
        name => { optional => 1 },
        mtu => { optional => 1 },
    };
}


1;
