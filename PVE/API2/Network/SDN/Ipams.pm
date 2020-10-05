package PVE::API2::Network::SDN::Ipams;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Network::SDN;
use PVE::Network::SDN::Ipams;
use PVE::Network::SDN::Ipams::Plugin;
use PVE::Network::SDN::Ipams::PVEPlugin;
use PVE::Network::SDN::Ipams::PhpIpamPlugin;
use PVE::Network::SDN::Ipams::NetboxPlugin;

use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $sdn_ipams_type_enum = PVE::Network::SDN::Ipams::Plugin->lookup_types();

my $api_sdn_ipams_config = sub {
    my ($cfg, $id) = @_;

    my $scfg = dclone(PVE::Network::SDN::Ipams::sdn_ipams_config($cfg, $id));
    $scfg->{ipam} = $id;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SDN ipams index.",
    permissions => {
	description => "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/sdn/ipams/<ipam>'",
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    type => {
		description => "Only list sdn ipams of specific type",
		type => 'string',
		enum => $sdn_ipams_type_enum,
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { ipam => { type => 'string'},
			    type => { type => 'string'},
			  },
	},
	links => [ { rel => 'child', href => "{ipam}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();


	my $cfg = PVE::Network::SDN::Ipams::config();

	my @sids = PVE::Network::SDN::Ipams::sdn_ipams_ids($cfg);
	my $res = [];
	foreach my $id (@sids) {
	    my $privs = [ 'SDN.Audit', 'SDN.Allocate' ];
	    next if !$rpcenv->check_any($authuser, "/sdn/ipams/$id", $privs, 1);

	    my $scfg = &$api_sdn_ipams_config($cfg, $id);
	    next if $param->{type} && $param->{type} ne $scfg->{type};

	    my $plugin_config = $cfg->{ids}->{$id};
	    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{ipam}',
    method => 'GET',
    description => "Read sdn ipam configuration.",
    permissions => {
	check => ['perm', '/sdn/ipams/{ipam}', ['SDN.Allocate']],
   },

    parameters => {
    	additionalProperties => 0,
	properties => {
	    ipam => get_standard_option('pve-sdn-ipam-id'),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Network::SDN::Ipams::config();

	return &$api_sdn_ipams_config($cfg, $param->{ipam});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new sdn ipam object.",
    permissions => {
	check => ['perm', '/sdn/ipams', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::Ipams::Plugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $id = extract_param($param, 'ipam');

	my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($type);
	my $opts = $plugin->check_config($id, $param, 1, 1);

        # create /etc/pve/sdn directory
        PVE::Cluster::check_cfs_quorum();
        mkdir("/etc/pve/sdn");

        PVE::Network::SDN::lock_sdn_config(
	    sub {

		my $ipam_cfg = PVE::Network::SDN::Ipams::config();
		my $controller_cfg = PVE::Network::SDN::Controllers::config();

		my $scfg = undef;
		if ($scfg = PVE::Network::SDN::Ipams::sdn_ipams_config($ipam_cfg, $id, 1)) {
		    die "sdn ipam object ID '$id' already defined\n";
		}

		$ipam_cfg->{ids}->{$id} = $opts;

		my $plugin_config = $opts;
		my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
		$plugin->on_update_hook($plugin_config);

		PVE::Network::SDN::Ipams::write_config($ipam_cfg);

	    }, "create sdn ipam object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{ipam}',
    method => 'PUT',
    description => "Update sdn ipam object configuration.",
    permissions => {
	check => ['perm', '/sdn/ipams', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::Ipams::Plugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'ipam');
	my $digest = extract_param($param, 'digest');

        PVE::Network::SDN::lock_sdn_config(
	 sub {

	    my $ipam_cfg = PVE::Network::SDN::Ipams::config();

	    PVE::SectionConfig::assert_if_modified($ipam_cfg, $digest);

	    my $scfg = PVE::Network::SDN::Ipams::sdn_ipams_config($ipam_cfg, $id);

	    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($scfg->{type});
	    my $opts = $plugin->check_config($id, $param, 0, 1);

	    foreach my $k (%$opts) {
		$scfg->{$k} = $opts->{$k};
	    }

            $plugin->on_update_hook($scfg);

	    PVE::Network::SDN::Ipams::write_config($ipam_cfg);

	    }, "update sdn ipam object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{ipam}',
    method => 'DELETE',
    description => "Delete sdn ipam object configuration.",
    permissions => {
	check => ['perm', '/sdn/ipams', ['SDN.Allocate']],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    ipam => get_standard_option('pve-sdn-ipam-id', {
                completion => \&PVE::Network::SDN::Ipams::complete_sdn_ipams,
            }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'ipam');

        PVE::Network::SDN::lock_sdn_config(
	    sub {

		my $cfg = PVE::Network::SDN::Ipams::config();

		my $scfg = PVE::Network::SDN::Ipams::sdn_ipams_config($cfg, $id);

		my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($scfg->{type});

		my $vnet_cfg = PVE::Network::SDN::Vnets::config();

		delete $cfg->{ids}->{$id};
		PVE::Network::SDN::Ipams::write_config($cfg);

	    }, "delete sdn zone object failed");

	return undef;
    }});

1;
