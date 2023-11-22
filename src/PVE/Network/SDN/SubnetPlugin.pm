package PVE::Network::SDN::SubnetPlugin;

use strict;
use warnings;

use Net::IP;
use Net::Subnet qw(subnet_matcher);

use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::Exception qw(raise raise_param_exc);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN::Ipams;
use PVE::Network::SDN::Vnets;

use base qw(PVE::SectionConfig);

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

    my $cidr = "";
    if($id =~ /\//) {
	$cidr = $id;
    } else {
	my ($zone, $ip, $mask) = split(/-/, $id);
	$cidr = "$ip/$mask";
    }

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

my $dhcp_range_fmt = {
    'start-address' => {
	type => 'ip',
	description => 'Start address for the DHCP IP range',
    },
    'end-address' => {
	type => 'ip',
	description => 'End address for the DHCP IP range',
    },
};

PVE::JSONSchema::register_format('pve-sdn-dhcp-range', $dhcp_range_fmt);

sub validate_dhcp_ranges {
    my ($subnet) = @_;

    my $cidr = $subnet->{cidr};
    my $subnet_matcher = subnet_matcher($cidr);

    my $dhcp_ranges = PVE::Network::SDN::Subnets::get_dhcp_ranges($subnet);

    foreach my $dhcp_range (@$dhcp_ranges) {
	my $dhcp_start = $dhcp_range->{'start-address'};
	my $dhcp_end = $dhcp_range->{'end-address'};

	my $start_ip = new Net::IP($dhcp_start);
	raise_param_exc({ 'dhcp-range' => "start-adress is not a valid IP $dhcp_start" }) if !$start_ip;

	my $end_ip = new Net::IP($dhcp_end);
	raise_param_exc({ 'dhcp-range' => "end-adress is not a valid IP $dhcp_end" }) if !$end_ip;

	if (Net::IP::ip_bincomp($end_ip->binip(), 'lt', $start_ip->binip()) == 1) {
	    raise_param_exc({ 'dhcp-range' => "start-address $dhcp_start must be smaller than end-address $dhcp_end" })
	}

	raise_param_exc({ 'dhcp-range' => "start-address $dhcp_start is not in subnet $cidr" }) if !$subnet_matcher->($dhcp_start);
	raise_param_exc({ 'dhcp-range' => "end-address $dhcp_end is not in subnet $cidr" }) if !$subnet_matcher->($dhcp_end);
    }
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
        dnszoneprefix => {
            type => 'string', format => 'dns-name',
            description => "dns domain zone prefix  ex: 'adm' -> <hostname>.adm.mydomain.com",
        },
	'dhcp-range' => {
	    type => 'array',
	    description => 'A list of DHCP ranges for this subnet',
	    optional => 1,
	    items => {
		type => 'string',
		format => 'pve-sdn-dhcp-range',
	    }
	},
	'dhcp-dns-server' => {
	    type => 'string', format => 'ip',
	    description => 'IP address for the DNS server',
	    optional => 1,
	},
    };
}

sub options {
    return {
	vnet => { optional => 0 },
	gateway => { optional => 1 },
#	routes => { optional => 1 },
	snat => { optional => 1 },
	dnszoneprefix => { optional => 1 },
	'dhcp-range' => { optional => 1 },
	'dhcp-dns-server' => { optional => 1 },
    };
}

sub on_update_hook {
    my ($class, $zone, $subnetid, $subnet, $old_subnet) = @_;

    my $cidr = $subnet->{cidr};
    my $mask = $subnet->{mask};

    my $subnet_matcher = subnet_matcher($cidr);

    my $vnetid = $subnet->{vnet};
    my $gateway = $subnet->{gateway};
    my $ipam = $zone->{ipam};
    my $dns = $zone->{dns};
    my $dnszone = $zone->{dnszone};
    my $reversedns = $zone->{reversedns};

    my $old_gateway = $old_subnet->{gateway} if $old_subnet;
    my $mac = undef;

    if($vnetid) {
	my $vnet = PVE::Network::SDN::Vnets::get_vnet($vnetid);
	raise_param_exc({ vnet => "$vnetid don't exist"}) if !$vnet;
	raise_param_exc({ vnet => "you can't add a subnet on a vlanaware vnet"}) if $vnet->{vlanaware};
	$mac = $vnet->{mac};
    }

    my $pointopoint = 1 if Net::IP::ip_is_ipv4($gateway) && $mask == 32;

    #for /32 pointopoint, we allow gateway outside the subnet
    raise_param_exc({ gateway => "$gateway is not in subnet $cidr"}) if $gateway && !$subnet_matcher->($gateway) && !$pointopoint;

    validate_dhcp_ranges($subnet);

    if ($ipam) {
	PVE::Network::SDN::Subnets::add_subnet($zone, $subnetid, $subnet);

	#don't register gateway for pointopoint
	return if $pointopoint;

	#delete gateway on removal
	if (!defined($gateway) && $old_gateway) {
	    eval {
		PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $old_subnet, $old_gateway);
	    };
	    warn if $@;
	}
        if(!$old_gateway || $gateway && $gateway ne $old_gateway) {
	    my $hostname = "$vnetid-gw";
	    PVE::Network::SDN::Subnets::add_ip($zone, $subnetid, $subnet, $gateway, $hostname, $mac, undef, 1);
	}

	#delete old gateway after update
	if($gateway && $old_gateway && $gateway ne $old_gateway) {
	    eval {
		PVE::Network::SDN::Subnets::del_ip($zone, $subnetid, $old_subnet, $old_gateway);
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
