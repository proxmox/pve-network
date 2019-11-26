package PVE::Network::SDN::Zones::Plugin;

use strict;
use warnings;

use PVE::Tools;
use PVE::JSONSchema;
use PVE::Cluster;

use Data::Dumper;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file('sdn/zones.cfg',
				 sub { __PACKAGE__->parse_config(@_); });

PVE::Cluster::cfs_register_file('sdn/zones.cfg.new',
				 sub { __PACKAGE__->parse_config(@_); },
				 sub { __PACKAGE__->write_config(@_); });

PVE::JSONSchema::register_standard_option('pve-sdn-zone-id', {
    description => "The SDN zone object identifier.",
    type => 'string', format => 'pve-sdn-zone-id',
});

PVE::JSONSchema::register_format('pve-sdn-zone-id', \&parse_sdn_zone_id);
sub parse_sdn_zone_id {
    my ($id, $noerr) = @_;

    if ($id !~ m/^[a-z][a-z0-9]*[a-z0-9]$/i) {
	return undef if $noerr;
	die "zone ID '$id' contains illegal characters\n";
    }
    die "zone ID '$id' can't be more length than 10 characters\n" if length($id) > 10;
    return $id;
}

my $defaultData = {

    propertyList => {
	type => {
	    description => "Plugin type.",
	    type => 'string', format => 'pve-configid',
	    type => 'string',
	},
        nodes => get_standard_option('pve-node-list', { optional => 1 }),
        zone => get_standard_option('pve-sdn-zone-id',
            { completion => \&PVE::Network::SDN::Zones::complete_sdn_zone }),
    },
};

sub private {
    return $defaultData;
}

sub decode_value {
    my ($class, $type, $key, $value) = @_;

    if ($key eq 'nodes') {
        my $res = {};

        foreach my $node (PVE::Tools::split_list($value)) {
            if (PVE::JSONSchema::pve_verify_node_name($node)) {
                $res->{$node} = 1;
            }
        }

        return $res;
    } 

   return $value;
}

sub encode_value {
    my ($class, $type, $key, $value) = @_;

    if ($key eq 'nodes') {
        return join(',', keys(%$value));
    }

    return $value;
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
    my ($class, $plugin_config, $controller, $id, $uplinks, $config) = @_;

    die "please implement inside plugin";
}

sub generate_controller_vnet_config {
    my ($class, $plugin_config, $controller, $zoneid, $vnetid, $config) = @_;

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
    my ($class, $zoneid, $vnet_cfg) = @_;

    # verify that no vnet are associated to this zone
    foreach my $id (keys %{$vnet_cfg->{ids}}) {
	my $vnet = $vnet_cfg->{ids}->{$id};
	die "zone $zoneid is used by vnet $id"
	    if ($vnet->{type} eq 'vnet' && defined($vnet->{zone}) && $vnet->{zone} eq $zoneid);
    }
}

sub on_update_hook {
    my ($class, $zoneid, $zone_cfg, $controller_cfg) = @_;

    # do nothing by default
}

#helpers
sub parse_tag_number_or_range {
    my ($str, $max, $tag) = @_;

    my @elements = split(/,/, $str);
    my $count = 0;
    my $allowed = undef;

    die "extraneous commas in list\n" if $str ne join(',', @elements);
    foreach my $item (@elements) {
	if ($item =~ m/^([0-9]+)-([0-9]+)$/) {
	    $count += 2;
	    my ($port1, $port2) = ($1, $2);
	    die "invalid port '$port1'\n" if $port1 > $max;
	    die "invalid port '$port2'\n" if $port2 > $max;
	    die "backwards range '$port1:$port2' not allowed, did you mean '$port2:$port1'?\n" if $port1 > $port2;

	    if ($tag && $tag >= $port1 && $tag <= $port2){
		$allowed = 1;
		last;
	    }

	} elsif ($item =~ m/^([0-9]+)$/) {
	    $count += 1;
	    my $port = $1;
	    die "invalid port '$port'\n" if $port > $max;

	    if ($tag && $tag == $port){
		$allowed = 1;
		last;
	    }
	}
    }
    die "tag $tag is not allowed" if $tag && !$allowed;

    return (scalar(@elements) > 1);
}

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
