package PVE::Network::Vnet::Plugin;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::JSONSchema qw(get_standard_option);
use PVE::SectionConfig;

use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file('network/vnet.cfg',
                                 sub { __PACKAGE__->parse_config(@_); },
                                 sub { __PACKAGE__->write_config(@_); });


sub options {
    return {
        vnet => { optional => 1 },
        transportzone => { optional => 1 },
        tag => { optional => 1 },
        name => { optional => 1 },
        ipv4 => { optional => 1 },
        ipv6 => { optional => 1 },
        name => { optional => 1 },
        mtu => { optional => 1 },
    };
}

my $defaultData = {
    propertyList => {
        vnet => get_standard_option('pve-vnet-id',
            { completion => \&PVE::Network::Vnet::complete_vnet }),

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

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
        my ($type, $vnetid) = (lc($1), $2);
        my $errmsg = undef; # set if you want to skip whole section
        eval { PVE::JSONSchema::pve_verify_configid($type); };
        $errmsg = $@ if $@;
        my $config = {}; # to return additional attributes
        return ($type, $vnetid, $errmsg, $config);
    }
    return undef;
}

__PACKAGE__->register();
__PACKAGE__->init();

1;
