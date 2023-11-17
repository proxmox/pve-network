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
    my ($class, $dhcp_config, $mac, $ip) = @_;
    die 'implement in sub class';
}

sub del_ip_mapping {
    my ($class, $dhcp_config, $mac) = @_;
    die 'implement in sub class';
}

sub configure_range {
    my ($class, $dhcp_config, $subnet_config, $range_config) = @_;
    die 'implement in sub class';
}

sub configure_subnet {
    my ($class, $dhcp_config, $subnet_config) = @_;
    die 'implement in sub class';
}

sub before_configure {
    my ($class, $dhcp_config) = @_;
    die 'implement in sub class';
}

sub after_configure {
    my ($class, $dhcp_config) = @_;
    die 'implement in sub class';
}

sub before_regenerate {
    my ($class) = @_;
    die 'implement in sub class';
}

sub after_regenerate {
    my ($class, $dhcp_config) = @_;
    die 'implement in sub class';
}

1;
