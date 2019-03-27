package PVE::Network::Vnet;

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::SectionConfig;

use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file('network/vnet.cfg',
                                 sub { __PACKAGE__->parse_config(@_); },
                                 sub { __PACKAGE__->write_config(@_); });


sub options {
    return {
        transportzone => { fixed => 1 },
        tag => { fixed => 1 },
        name => { optional => 1 },
        ipv4 => { optional => 1 },
        ipv6 => { optional => 1 },
        name => { optional => 1 },
        mtu => { optional => 1 },
    };
}

my $defaultData = {
    propertyList => {
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
    },
};

sub type {
    return 'vnet';
}

sub private {
    return $defaultData;
}


sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(vnet(\d+)):$/) {
        my $type = 'vnet';
        my $errmsg = undef; # set if you want to skip whole section
        eval { PVE::JSONSchema::pve_verify_configid($type); };
        $errmsg = $@ if $@;
        my $config = {}; # to return additional attributes
        return ($type, $1, $errmsg, $config);
    }
    return undef;
}

__PACKAGE__->register();
__PACKAGE__->init();

1;
