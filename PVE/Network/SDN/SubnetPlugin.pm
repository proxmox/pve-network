package PVE::Network::SDN::SubnetPlugin;

use strict;
use warnings;

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use base qw(PVE::SectionConfig);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Exception qw(raise raise_param_exc);
use Net::Subnet qw(subnet_matcher);
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Ipams;

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
        vnet => {
            type => 'string',
            description => "associated vnet",
        },
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
    my ($class, $subnetid, $subnet, $old_subnet) = @_;

    my $cidr = $subnetid =~ s/-/\//r;
    my $subnet_matcher = subnet_matcher($cidr);

    my $vnetid = $subnet->{vnet};
    my $gateway = $subnet->{gateway};
    my $ipam = $subnet->{ipam};
    my $dns = $subnet->{dns};
    my $dnszone = $subnet->{dnszone};
    my $reversedns = $subnet->{reversedns};
    my $reversednszone = $subnet->{reversednszone};

    my $old_gateway = $old_subnet->{gateway} if $old_subnet;

    if($vnetid) {
	my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
	raise_param_exc({ vnet => "$vnetid don't exist"}) if !$vnet;
    }

    my ($ip, $mask) = split(/\//, $cidr);
    #for /32 pointopoint, we allow gateway outside the subnet
    raise_param_exc({ gateway => "$gateway is not in subnet $subnetid"}) if $gateway && !$subnet_matcher->($gateway) && $mask != 32;

    raise_param_exc({ dns => "missing dns provider"}) if $dnszone && !$dns;
    raise_param_exc({ dnszone => "missing dns zone"}) if $dns && !$dnszone;
    raise_param_exc({ reversedns => "missing dns provider"}) if $reversednszone && !$reversedns;
    raise_param_exc({ reversednszone => "missing dns zone"}) if $reversedns && !$reversednszone;
    raise_param_exc({ reversedns => "missing forward dns zone"}) if $reversednszone && !$dnszone;

    if ($ipam) {
	my $ipam_cfg = PVE::Network::SDN::Ipams::config();
	my $plugin_config = $ipam_cfg->{ids}->{$ipam};
	raise_param_exc({ ipam => "$ipam not existing"}) if !$plugin_config;
	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	$plugin->add_subnet($plugin_config, $subnetid, $subnet);

	#delete on removal
	if (!defined($gateway) && $old_gateway) {
	    eval {
		PVE::Network::SDN::Subnets::del_ip($subnetid, $old_subnet, $old_gateway);
	    };
	    warn if $@;
	}
        if(!$old_gateway || $gateway && $gateway ne $old_gateway) {
	    PVE::Network::SDN::Subnets::add_ip($subnetid, $subnet, $gateway);
	}

	#delete old ip after update
	if($gateway && $old_gateway && $gateway ne $old_gateway) {
	    eval {
		PVE::Network::SDN::Subnets::del_ip($subnetid, $old_subnet, $old_gateway);
	    };
	    warn if $@;
	}
    }
}

sub on_delete_hook {
    my ($class, $subnetid, $subnet_cfg, $vnet_cfg) = @_;

    return;
}

1;
