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

PVE::Cluster::cfs_register_file('sdn/ipams.cfg',
				 sub { __PACKAGE__->parse_config(@_); },
				 sub { __PACKAGE__->write_config(@_); });

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
        ipam => get_standard_option('pve-sdn-ipam-id',
            { completion => \&PVE::Network::SDN::Ipams::complete_sdn_ipam }),
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
    my ($class, $plugin_config, $subnetid, $subnet) = @_;
}

sub del_subnet {
    my ($class, $plugin_config, $subnetid, $subnet) = @_;
}

sub add_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip, $hostname, $mac, $description, $is_gateway) = @_;

}

sub add_next_freeip {
    my ($class, $plugin_config, $subnetid, $subnet, $hostname, $mac, $description) = @_;
}

sub del_ip {
    my ($class, $plugin_config, $subnetid, $subnet, $ip) = @_;
}

sub on_update_hook {
    my ($class, $plugin_config)  = @_;
}


#helpers
sub api_request {
    my ($method, $url, $headers, $data) = @_;

    my $encoded_data = to_json($data) if $data;

    my $req = HTTP::Request->new($method,$url, $headers, $encoded_data);

    my $ua = LWP::UserAgent->new(protocols_allowed => ['http', 'https'], timeout => 30);
    my $proxy = undef;

    if ($proxy) {
        $ua->proxy(['http', 'https'], $proxy);
    } else {
        $ua->env_proxy;
    }

    $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0x00);

    my $response = $ua->request($req);
    my $code = $response->code;

    if ($code !~ /^2(\d+)$/) {
        my $msg = $response->message || 'unknown';
        die "Invalid response from server: $code $msg\n";
    }

    my $raw = '';
    if (defined($response->decoded_content)) {
	$raw = $response->decoded_content;
    } else {
	$raw = $response->content;
    }
    return from_json($raw) if $raw ne '';
}

1;
