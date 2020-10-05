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
#	#cloudinit, dhcp options
#        routes => {
#            type => 'string',
#            description => "static routes [network=<network>:gateway=<ip>,network=<network>:gateway=<ip>,... ]",
#        },
        dns => {
            type => 'string',
            description => "dns api server",
        },
        reversedns => {
            type => 'string',
            description => "reverse dns api server",
        },
        dnszone => {
            type => 'string', format => 'dns-name',
            description => "dns domain zone  ex: mydomain.com",
        },
        reversednszone => {
            type => 'string', format => 'dns-name',
            description => "reverse dns zone ex: 0.168.192.in-addr.arpa",
        },
        dnszoneprefix => {
            type => 'string', format => 'dns-name',
            description => "dns domain zone prefix  ex: 'adm' -> <hostname>.adm.mydomain.com",
        },
        ipam => {
            type => 'string',
            description => "use a specific ipam",
        },
    };
}

sub options {
    return {
	vnet => { optional => 0 },
	gateway => { optional => 1 },
#	routes => { optional => 1 },
	snat => { optional => 1 },
	dns => { optional => 1 },
	reversedns => { optional => 1 },
	dnszone => { optional => 1 },
	reversednszone => { optional => 1 },
	dnszoneprefix => { optional => 1 },
	ipam => { optional => 1 },
    };
}

sub on_update_hook {
    my ($class, $subnetid, $subnet_cfg) = @_;

    my $cidr = $subnetid =~ s/-/\//r;
    my $subnet_matcher = subnet_matcher($cidr);

    my $subnet = $subnet_cfg->{ids}->{$subnetid};

    my $gateway = $subnet->{gateway};
    my $dns = $subnet->{dns};
    my $dnszone = $subnet->{dnszone};
    my $reversedns = $subnet->{reversedns};
    my $reversednszone = $subnet->{reversednszone};

    #to: for /32 pointotoping, allow gateway outside the subnet
    raise_param_exc({ gateway => "$gateway is not in subnet $subnet"}) if $gateway && !$subnet_matcher->($gateway);

    raise_param_exc({ dns => "missing dns provider"}) if $dnszone && !$dns;
    raise_param_exc({ dnszone => "missing dns zone"}) if $dns && !$dnszone;
    raise_param_exc({ reversedns => "missing dns provider"}) if $reversednszone && !$reversedns;
    raise_param_exc({ reversednszone => "missing dns zone"}) if $reversedns && !$reversednszone;
    raise_param_exc({ reversedns => "missing forward dns zone"}) if $reversednszone && !$dnszone;

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
