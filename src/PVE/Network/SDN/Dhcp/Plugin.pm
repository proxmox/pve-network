package PVE::Network::SDN::Dhcp::Plugin;

use strict;
use warnings;

use PVE::Cluster;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::SectionConfig);

my $defaultData = {
    propertyList => {
       type => {
           description => "Plugin type.",
           format => 'pve-configid',
           type => 'string',
       },
    },
};

sub private {
    return $defaultData;
}

sub add_ip_mapping {
    my ($class, $dhcpid, $macdb, $mac, $ip4, $ip6) = @_;
    die 'implement in sub class';
}

sub configure_range {
    my ($class, $config, $dhcpid, $vnetid, $subnet_config, $range_config) = @_;
    die 'implement in sub class';
}

sub configure_subnet {
    my ($class, $config, $dhcpid, $vnetid, $subnet_config) = @_;
    die 'implement in sub class';
}

sub configure_vnet {
    my ($class, $config, $dhcpid, $vnetid, $vnet_config) = @_;
    die 'implement in sub class';
}

sub before_configure {
    my ($class, $dhcpid) = @_;
    die 'implement in sub class';
}

sub after_configure {
    my ($class, $dhcpid, $noerr) = @_;
    die 'implement in sub class';
}

sub before_regenerate {
    my ($class, $noerr) = @_;
    die 'implement in sub class';
}

sub after_regenerate {
    my ($class) = @_;
    die 'implement in sub class';
}

1;
