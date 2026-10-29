package PVE::API2::Network::SDN::Ips;

use strict;
use warnings;

use PVE::Tools qw(extract_param);

use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Dhcp;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'ipdelete',
    path => '',
    method => 'DELETE',
    description => 'Delete IP Mappings in a VNet',
    protected => 1,
    permissions => {
        description => "Requires 'SDN.Allocate' on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            # FIXME: Remove with PVE 10 as it is unused.
            zone => get_standard_option(
                'pve-sdn-zone-id',
                {
                    description =>
                        'DEPRECATED: value is ignored and parameter will be removed with PVE 10',
                    optional => 1,
                },
            ),
            vnet => get_standard_option('pve-sdn-vnet-id'),
            mac => get_standard_option('mac-addr'),
            ip => {
                type => 'string',
                format => 'ip',
                description => 'The IP address to delete',
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $vnet = extract_param($param, 'vnet');
        my $privs = ['SDN.Allocate'];
        PVE::Network::SDN::Vnets::api_get_vnet_checked($vnet, $privs);

        my $mac = extract_param($param, 'mac');
        my $ip = extract_param($param, 'ip');

        eval { PVE::Network::SDN::Vnets::del_ip($vnet, $ip, '', $mac); };
        die "$@\n" if $@;

        return undef;
    },
});

__PACKAGE__->register_method({
    name => 'ipcreate',
    path => '',
    method => 'POST',
    description => 'Create IP Mapping in a VNet',
    protected => 1,
    permissions => {
        description => "Requires 'SDN.Allocate' on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            # FIXME: Remove with PVE 10 as it is unused.
            zone => get_standard_option(
                'pve-sdn-zone-id',
                {
                    description =>
                        'DEPRECATED: value is ignored and parameter will be removed with PVE 10',
                    optional => 1,
                },
            ),
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
        my $privs = ['SDN.Allocate'];
        PVE::Network::SDN::Vnets::api_get_vnet_checked($vnet, $privs);

        my $mac = extract_param($param, 'mac');
        my $ip = extract_param($param, 'ip');

        PVE::Network::SDN::Vnets::add_ip($vnet, $ip, '', $mac, undef);

        return undef;
    },
});
__PACKAGE__->register_method({
    name => 'ipupdate',
    path => '',
    method => 'PUT',
    description => 'Update IP Mapping in a VNet',
    protected => 1,
    permissions => {
        description => "Requires 'SDN.Allocate' on '/sdn/zones/<zone>/<vnet>'",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            # FIXME: Remove with PVE 10 as it is unused.
            zone => get_standard_option(
                'pve-sdn-zone-id',
                {
                    description =>
                        'DEPRECATED: value is ignored and parameter will be removed with PVE 10',
                    optional => 1,
                },
            ),
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
        my $privs = ['SDN.Allocate'];
        PVE::Network::SDN::Vnets::api_get_vnet_checked($vnet, $privs);

        my $mac = extract_param($param, 'mac');
        my $vmid = extract_param($param, 'vmid');
        my $ip = extract_param($param, 'ip');

        my ($old_ip4, $old_ip6) = PVE::Network::SDN::Vnets::get_ips_from_mac($vnet, $mac);
        my $old_ip = (Net::IP::ip_get_version($ip) == 4) ? $old_ip4 : $old_ip6;

        PVE::Network::SDN::Vnets::del_ip($vnet, $old_ip, '', $mac);

        eval { PVE::Network::SDN::Vnets::add_ip($vnet, $ip, '', $mac, $vmid); };
        my $error = $@;

        if ($error) {
            PVE::Network::SDN::Vnets::add_ip($vnet, $old_ip, '', $mac, $vmid);
        }

        die "$error\n" if $error;
        return undef;
    },
});

1;
