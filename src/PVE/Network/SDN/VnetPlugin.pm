package PVE::Network::SDN::VnetPlugin;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Exception qw(raise raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);

use PVE::SectionConfig;
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file('sdn/vnets.cfg',
                                 sub { __PACKAGE__->parse_config(@_); },
                                 sub { __PACKAGE__->write_config(@_); });

PVE::JSONSchema::register_standard_option('pve-sdn-vnet-id', {
    description => "The SDN vnet object identifier.",
    type => 'string', format => 'pve-sdn-vnet-id',
});

PVE::JSONSchema::register_format('pve-sdn-vnet-id', \&parse_sdn_vnet_id);
sub parse_sdn_vnet_id {
    my ($id, $noerr) = @_;

    if ($id !~ m/^[a-z][a-z0-9]*[a-z0-9]$/i) {
        return undef if $noerr;
        die "vnet ID '$id' contains illegal characters\n";
    }
    die "vnet ID '$id' can't be more length than 8 characters\n" if length($id) > 8;
    return $id;
}

my $defaultData = {

    propertyList => {
        vnet => get_standard_option('pve-sdn-vnet-id',
            { completion => \&PVE::Network::SDN::Vnets::complete_sdn_vnet }),
    },
};

sub type {
    return 'vnet';
}

sub private {
    return $defaultData;
}

sub properties {
    return {
	zone => {
            type => 'string',
            description => "zone id",
	},
        type => {
            description => "Type",
            optional => 1,
        },
	tag => {
            type => 'integer',
            description => "vlan or vxlan id",
	},
	vlanaware => {
	    type => 'boolean',
	    description => 'Allow vm VLANs to pass through this vnet.',
	},
        alias => {
            type => 'string',
            description => "alias name of the vnet",
            pattern => qr/[\(\)-_.\w\d\s]{0,256}/i,
            maxLength => 256,
	    optional => 1,
        },
	'isolate-ports' => {
	    type => 'boolean',
	    description => "If true, sets the isolated property for all members of this VNet",
	}
    };
}

sub options {
    return {
        zone => { optional => 0},
        tag => { optional => 1},
        alias => { optional => 1 },
        vlanaware => { optional => 1 },
	'isolate-ports' => { optional => 1 },
    };
}

sub on_delete_hook {
    my ($class, $vnetid, $vnet_cfg) = @_;

    #verify if subnets are associated
    my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid);
    raise_param_exc({ vnet => "Can't delete vnet if subnets exists"}) if $subnets;
}

sub on_update_hook {
    my ($class, $vnetid, $vnet_cfg) = @_;

    my $vnet = $vnet_cfg->{ids}->{$vnetid};
    my $tag = $vnet->{tag};
    my $vlanaware = $vnet->{vlanaware};

    #don't allow vlanaware change if subnets are defined
    if($vnet->{vlanaware}) {
	my $subnets = PVE::Network::SDN::Vnets::get_subnets($vnetid);
	raise_param_exc({ vlanaware => "vlanaware vnet is not compatible with subnets"}) if $subnets;
    }
}

1;
