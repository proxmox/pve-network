package PVE::Network::SDN::VnetPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Plugin;

use base('PVE::Network::SDN::Plugin');

use PVE::Cluster;

sub type {
    return 'vnet';
}

sub properties {
    return {
	transportzone => {
            type => 'string',
            description => "transportzone id",
	},
	tag => {
            type => 'integer',
            description => "vlan or vxlan id",
	},
        alias => {
            type => 'string',
            description => "alias name of the vnet",
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
        transportzone => { optional => 0},
        tag => { optional => 0},
        alias => { optional => 1 },
        ipv4 => { optional => 1 },
        ipv6 => { optional => 1 },
        mtu => { optional => 1 },
    };
}

sub on_delete_hook {
    my ($class, $networkid, $network_cfg) = @_;

    return;
}

sub on_update_hook {
    my ($class, $networkid, $network_cfg) = @_;
    # verify that tag is not already defined in another vnet
    if (defined($network_cfg->{ids}->{$networkid}->{tag})) {
	my $tag = $network_cfg->{ids}->{$networkid}->{tag};
	foreach my $id (keys %{$network_cfg->{ids}}) {
	    next if $id eq $networkid;
	    my $network = $network_cfg->{ids}->{$id};
	    if ($network->{type} eq 'vnet' && defined($network->{tag})) {
		die "tag $tag already exist in vnet $id" if $tag eq $network->{tag};
	    }
	}
    }
}

1;
