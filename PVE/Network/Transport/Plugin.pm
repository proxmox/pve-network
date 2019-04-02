package PVE::Network::Transport::Plugin;

use strict;
use warnings;

use PVE::Tools;
use PVE::JSONSchema;
use PVE::Cluster;

use Data::Dumper;
use PVE::JSONSchema qw(get_standard_option);
use base qw(PVE::SectionConfig);

PVE::Cluster::cfs_register_file('network/transports.cfg',
				 sub { __PACKAGE__->parse_config(@_); },
				 sub { __PACKAGE__->write_config(@_); });

my $defaultData = {

    propertyList => {
	type => { 
	    description => "Plugin type.",
	    type => 'string', format => 'pve-configid',
	    type => 'string',
	},
        transport => get_standard_option('pve-transport-id',
            { completion => \&PVE::Network::Transport::complete_transport }),
    },
};

sub private {
    return $defaultData;
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
        my ($type, $transportid) = (lc($1), $2);
	my $errmsg = undef; # set if you want to skip whole section
	eval { PVE::JSONSchema::pve_verify_configid($type); };
	$errmsg = $@ if $@;
	my $config = {}; # to return additional attributes
	return ($type, $transportid, $errmsg, $config);
    }
    return undef;
}

sub generate_network_config {
    my ($class, $plugin_config, $node, $data, $ctime) = @_;

    die "please implement inside plugin";
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

1;
