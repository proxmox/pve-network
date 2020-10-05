package PVE::Network::SDN::SubnetPlugin;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use base qw(PVE::SectionConfig);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Exception qw(raise raise_param_exc);
use Net::Subnet qw(subnet_matcher);

PVE::Cluster::cfs_register_file('sdn/subnets.cfg',
                                 sub { __PACKAGE__->parse_config(@_); },
                                 sub { __PACKAGE__->write_config(@_); });

PVE::JSONSchema::register_standard_option('pve-sdn-subnet-id', {
    description => "The SDN subnet object identifier.",
    type => 'string', format => 'pve-sdn-subnet-id',
    type => 'string'
});

PVE::JSONSchema::register_format('pve-sdn-subnet-id', \&parse_sdn_subnet_id);
sub parse_sdn_subnet_id {
    my ($id, $noerr) = @_;

    my $cidr = $id =~ s/-/\//r;

    if (!(PVE::JSONSchema::pve_verify_cidrv4($cidr, 1) ||
          PVE::JSONSchema::pve_verify_cidrv6($cidr, 1)))
    {
        return undef if $noerr;
        die "value does not look like a valid CIDR network\n";
    }
    return $id;
}

my $defaultData = {

    propertyList => {
        subnet => get_standard_option('pve-sdn-subnet-id',
            { completion => \&PVE::Network::SDN::Subnets::complete_sdn_subnet }),
    },
};

sub type {
    return 'subnet';
}

sub private {
    return $defaultData;
}

sub properties {
    return {
        gateway => {
            type => 'string', format => 'ip',
            description => "Subnet Gateway: Will be assign on vnet for layer3 zones",
        },
        snat => {
            type => 'boolean',
            description => "enable masquerade for this subnet if pve-firewall",
        },
	#cloudinit, dhcp options
        routes => {
            type => 'string',
            description => "static routes [network=<network>:gateway=<ip>,network=<network>:gateway=<ip>,... ]",
        },
	#cloudinit, dhcp options
        nameservers => {
            type => 'string', format => 'address-list',
            description => " dns nameserver",
        },
	#cloudinit, dhcp options
        searchdomain => {
            type => 'string',
        },
        dhcp => {
            type => 'boolean',
            description => "enable dhcp for this subnet",
        },
        dns_driver => {
            type => 'string',
            description => "Develop some dns registrations plugins (powerdns,...)",
        },
        ipam => {
            type => 'string',
            description => "use a specific ipam",
        },
    };
}

sub options {
    return {
	gateway => { optional => 1 },
	routes => { optional => 1 },
	nameservers => { optional => 1 },
	searchdomain => { optional => 1 },
	snat => { optional => 1 },
	dhcp => { optional => 1 },
	dns_driver => { optional => 1 },
	ipam => { optional => 1 },
    };
}

sub on_update_hook {
    my ($class, $subnetid, $subnet_cfg) = @_;

    my $subnet = $subnetid =~ s/-/\//r;
    my $subnet_matcher = subnet_matcher($subnet);

    my $gateway = $subnet_cfg->{ids}->{$subnetid}->{gateway};
    raise_param_exc({ gateway => "$gateway is not in subnet $subnet"}) if $gateway && !$subnet_matcher->($gateway);

}

sub on_delete_hook {
    my ($class, $subnetid, $subnet_cfg, $vnet_cfg) = @_;

    #verify if vnets have subnet
    foreach my $vnetid (keys %{$vnet_cfg->{ids}}) {
	my $vnet = $vnet_cfg->{ids}->{$vnetid};
	my @subnets = PVE::Tools::split_list($vnet->{subnets}) if $vnet->{subnets};
	foreach my $subnet (@subnets) {
	    my $id = $subnet =~ s/\//-/r;
	    raise_param_exc({ subnet => "$subnet is attached to vnet $vnetid"}) if $id eq $subnetid;
	}
    }

    return;
}

1;
