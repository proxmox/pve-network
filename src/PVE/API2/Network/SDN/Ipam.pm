package PVE::API2::Network::SDN::Ipam;

use strict;
use warnings;

use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);

use PVE::Network::SDN;
use PVE::Network::SDN::Dhcp;
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Ipams::Plugin;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
    name => 'ipamindex',
    path => '',
    method => 'GET',
    description => 'List PVE IPAM Entries',
    protected => 1,
    permissions => {
	description => "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/sdn/zones/<zone>/<vnet>'",
	user => 'all',
    },
    parameters => {
	additionalProperties => 0,
    },
    returns => {
	type => 'array',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();
	my $privs = [ 'SDN.Audit', 'SDN.Allocate' ];

	my $ipam_plugin = PVE::Network::SDN::Ipams::Plugin->lookup('pve');
	my $ipam_db = $ipam_plugin->read_db();

	my $result = [];

	for my $zone_id (keys %{$ipam_db->{zones}}) {
	    my $zone_config = PVE::Network::SDN::Zones::get_zone($zone_id, 1);
            next if !$zone_config || $zone_config->{ipam} ne 'pve' || !$zone_config->{dhcp};

	    my $zone = $ipam_db->{zones}->{$zone_id};

	    my $vnets = PVE::Network::SDN::Zones::get_vnets($zone_id, 1);

	    for my $subnet_cidr (keys %{$zone->{subnets}}) {
		my $subnet = $zone->{subnets}->{$subnet_cidr};
		my $ip = new NetAddr::IP($subnet_cidr) or die 'Found invalid CIDR in IPAM';

		my $vnet = undef;
		for my $vnet_id (keys %$vnets) {
		    eval {
			my ($zone, $subnetid, $subnet_cfg, $ip) = PVE::Network::SDN::Vnets::get_subnet_from_vnet_ip(
			    $vnet_id,
			    $ip->addr,
			);

			$vnet = $subnet_cfg->{vnet};
		    };

		    last if $vnet;
		}

		next if !$vnet || !$rpcenv->check_any($authuser, "/sdn/zones/$zone_id/$vnet", $privs, 1);

		for my $ip (keys %{$subnet->{ips}}) {
		    my $entry = $subnet->{ips}->{$ip};
		    $entry->{zone} = $zone_id;
		    $entry->{subnet} = $subnet_cidr;
		    $entry->{ip} = $ip;
		    $entry->{vnet} = $vnet;

		    push @$result, $entry;
		}
	    }
	}

	return $result;
    },
});

__PACKAGE__->register_method ({
    name => 'dhcpdelete',
    path => '{zone}/{vnet}/{mac}',
    method => 'DELETE',
    description => 'Delete DHCP Mappings in a VNet for a MAC address',
    protected => 1,
    permissions => {
	check => ['perm', '/sdn/zones/{zone}/{vnet}', [ 'SDN.Allocate' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    zone => get_standard_option('pve-sdn-zone-id'),
	    vnet => get_standard_option('pve-sdn-vnet-id'),
	    mac => get_standard_option('mac-addr'),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $vnet = extract_param($param, 'vnet');
	my $mac = extract_param($param, 'mac');

	eval {
	    PVE::Network::SDN::Vnets::del_ips_from_mac($vnet, $mac);
	};
	my $error = $@;

	die "$error\n" if $error;

	return undef;
    },
});

__PACKAGE__->register_method ({
    name => 'dhcpcreate',
    path => '{zone}/{vnet}/{mac}',
    method => 'POST',
    description => 'Create DHCP Mapping',
    protected => 1,
    permissions => {
	check => ['perm', '/sdn/zones/{zone}/{vnet}', [ 'SDN.Allocate' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    zone => get_standard_option('pve-sdn-zone-id'),
	    vnet => get_standard_option('pve-sdn-vnet-id'),
	    mac => get_standard_option('mac-addr'),
	    ip => {
		type => 'string',
		format => 'ip',
		description => 'The IP address to associate with the given MAC address',
	    },
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $vnet = extract_param($param, 'vnet');
	my $mac = extract_param($param, 'mac');
	my $ip = extract_param($param, 'ip');

	PVE::Network::SDN::Vnets::add_ip($vnet, $ip, '', $mac, undef);

	return undef;
    },
});
__PACKAGE__->register_method ({
    name => 'dhcpupdate',
    path => '{zone}/{vnet}/{mac}',
    method => 'PUT',
    description => 'Update DHCP Mapping',
    protected => 1,
    permissions => {
	check => ['perm', '/sdn/zones/{zone}/{vnet}', [ 'SDN.Allocate' ]],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    zone => get_standard_option('pve-sdn-zone-id'),
	    vnet => get_standard_option('pve-sdn-vnet-id'),
	    vmid => get_standard_option('pve-vmid', {
		optional => 1,
	    }),
	    mac => get_standard_option('mac-addr'),
	    ip => {
		type => 'string',
		format => 'ip',
		description => 'The IP address to associate with the given MAC address',
	    },
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $vnet = extract_param($param, 'vnet');
	my $mac = extract_param($param, 'mac');
	my $vmid = extract_param($param, 'vmid');
	my $ip = extract_param($param, 'ip');

	my ($old_ip4, $old_ip6) = PVE::Network::SDN::Vnets::del_ips_from_mac($vnet, $mac, '');

	eval {
	    PVE::Network::SDN::Vnets::add_ip($vnet, $ip, '', $mac, $vmid);
	};
	my $error = $@;

	if ($error) {
	    PVE::Network::SDN::Vnets::add_ip($vnet, $old_ip4, '', $mac, $vmid) if $old_ip4;
	    PVE::Network::SDN::Vnets::add_ip($vnet, $old_ip6, '', $mac, $vmid) if $old_ip6;
	}

	die "$error\n" if $error;
	return undef;
    },
});

1;
