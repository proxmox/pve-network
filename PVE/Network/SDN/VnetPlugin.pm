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
            type => 'string', format => 'CIDRv4',
            optional => 1,
        },
	ipv6 => {
	    description => "Anycast router ipv6 address.",
	    type => 'string', format => 'CIDRv6',
	    optional => 1,
	},
        mac => {
            type => 'string',
            description => "Anycast router mac address",
	    optional => 1, format => 'mac-addr'
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
        mac => { optional => 1 },
    };
}

sub on_delete_hook {
    my ($class, $sdnid, $sdn_cfg) = @_;

    return;
}

sub on_update_hook {
    my ($class, $sdnid, $sdn_cfg) = @_;
    # verify that tag is not already defined in another vnet
    if (defined($sdn_cfg->{ids}->{$sdnid}->{tag})) {
	my $tag = $sdn_cfg->{ids}->{$sdnid}->{tag};
	foreach my $id (keys %{$sdn_cfg->{ids}}) {
	    next if $id eq $sdnid;
	    my $sdn = $sdn_cfg->{ids}->{$id};
	    if ($sdn->{type} eq 'vnet' && defined($sdn->{tag})) {
		die "tag $tag already exist in vnet $id" if $tag eq $sdn->{tag};
	    }
	}
    }
}

1;
