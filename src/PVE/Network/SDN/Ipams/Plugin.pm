package PVE::Network::SDN::Ipams::Plugin;

use strict;
use warnings;

use PVE::Tools qw(run_command);
use PVE::JSONSchema;
use PVE::Cluster;
use HTTP::Request;
use LWP::UserAgent;
use JSON;

use Data::Dumper;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file(
    'sdn/ipams.cfg',
     sub { __PACKAGE__->parse_config(@_); },
     sub { __PACKAGE__->write_config(@_); },
 );

PVE::JSONSchema::register_standard_option('pve-sdn-ipam-id', {
    description => "The SDN ipam object identifier.",
    type => 'string', format => 'pve-sdn-ipam-id',
});

PVE::JSONSchema::register_format('pve-sdn-ipam-id', \&parse_sdn_ipam_id);
sub parse_sdn_ipam_id {
    my ($id, $noerr) = @_;

    if ($id !~ m/^[a-z][a-z0-9]*[a-z0-9]$/i) {
	return undef if $noerr;
	die "ipam ID '$id' contains illegal characters\n";
    }
    return $id;
}

my $defaultData = {

    propertyList => {
	type => {
	    description => "Plugin type.",
	    type => 'string', format => 'pve-configid',
	    type => 'string',
	},
	ipam => get_standard_option('pve-sdn-ipam-id', {
	    completion => \&PVE::Network::SDN::Ipams::complete_sdn_ipam,
	}),
    },
};

sub private {
    return $defaultData;
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
        my ($type, $id) = (lc($1), $2);
	my $errmsg = undef; # set if you want to skip whole section
	eval { PVE::JSONSchema::pve_verify_configid($type); };
	$errmsg = $@ if $@;
	my $config = {}; # to return additional attributes
	return ($type, $id, $errmsg, $config);
    }
    return undef;
}


sub add_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    die "please implement inside plugin";
}

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet, $noerr) = @_;

    die "please implement inside plugin";
}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;

    die "please implement inside plugin";
}

sub update_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $vmid, $is_gateway, $noerr) = @_;
    # only update ip attributes (mac,hostname,..). Don't change the ip addresses itself, as some ipam
    # don't allow ip address change without del/add

    die "please implement inside plugin";
}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $vmid, $noerr) = @_;

    die "please implement inside plugin";
}


sub add_range_next_freeip {
    my ($class, $plugin_config, $subnet, $range, $data, $noerr) = @_;

    die "please implement inside plugin";
}

sub del_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $noerr) = @_;

    die "please implement inside plugin";
}

sub get_ips_from_mac {
    my ($class, $plugin_config, $mac, $zone) = @_;

    die "please implement inside plugin";
}

sub on_update_hook {
    my ($class, $plugin_config)  = @_;
}

1;
