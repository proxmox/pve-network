package PVE::Network::SDN::Controllers::Plugin;

use strict;
use warnings;

use PVE::Tools;
use PVE::JSONSchema;
use PVE::Cluster;

use Data::Dumper;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file('sdn/controllers.cfg',
				 sub { __PACKAGE__->parse_config(@_); });

PVE::Cluster::cfs_register_file('sdn/controllers.cfg.new',
				 sub { __PACKAGE__->parse_config(@_); },
				 sub { __PACKAGE__->write_config(@_); });

PVE::JSONSchema::register_standard_option('pve-sdn-controller-id', {
    description => "The SDN controller object identifier.",
    type => 'string', format => 'pve-sdn-controller-id',
});

PVE::JSONSchema::register_format('pve-sdn-controller-id', \&parse_sdn_controller_id);
sub parse_sdn_controller_id {
    my ($id, $noerr) = @_;

    if ($id !~ m/^[a-z][a-z0-9\-\_\.]*[a-z0-9]$/i) {
        return undef if $noerr;
        die "SDN controller object ID '$id' contains illegal characters\n";
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
        controller => get_standard_option('pve-sdn-controller-id',
            { completion => \&PVE::Network::SDN::complete_sdn_controller }),
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

sub generate_sdn_config {
    my ($class, $plugin_config, $node, $data, $ctime) = @_;

    die "please implement inside plugin";
}

sub generate_controller_config {
    my ($class, $plugin_config, $router, $id, $uplinks, $config) = @_;

    die "please implement inside plugin";
}

sub generate_controller_vnet_config {
    my ($class, $plugin_config, $controller, $transportid, $vnetid, $config) = @_;

}

sub write_controller_config {
    my ($class, $plugin_config, $config) = @_;

    die "please implement inside plugin";
}

sub controller_reload {
    my ($class) = @_;

    die "please implement inside plugin";
}

sub on_delete_hook {
    my ($class, $sndid, $scfg) = @_;

    # do nothing by default
}

sub on_update_hook {
    my ($class, $sdnid, $scfg) = @_;

    # do nothing by default
}

#helpers

#to be move to Network.pm helper
sub get_first_local_ipv4_from_interface {
    my ($interface) = @_;

    my $cmd = ['/sbin/ip', 'address', 'show', 'dev', $interface];

    my $IP = "";

    my $code = sub {
	my $line = shift;

	if ($line =~ m!^\s*inet\s+($PVE::Tools::IPRE)(?:/\d+|\s+peer\s+)!) {
	    $IP = $1;
	    return;
	}
    };

    PVE::Tools::run_command($cmd, outfunc => $code);

    return $IP;
}

1;
