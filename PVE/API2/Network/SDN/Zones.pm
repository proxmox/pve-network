package PVE::API2::Network::SDN::Zones;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Zones;
use PVE::Network::SDN::Zones::Plugin;
use PVE::Network::SDN::Zones::VlanPlugin;
use PVE::Network::SDN::Zones::QinQPlugin;
use PVE::Network::SDN::Zones::VxlanPlugin;
use PVE::Network::SDN::Zones::EvpnPlugin;
use PVE::Network::SDN::Zones::FaucetPlugin;

use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $sdn_zones_type_enum = PVE::Network::SDN::Zones::Plugin->lookup_types();

my $api_sdn_zones_config = sub {
    my ($cfg, $id) = @_;

    my $scfg = dclone(PVE::Network::SDN::Zones::sdn_zones_config($cfg, $id));
    $scfg->{zone} = $id;
    $scfg->{digest} = $cfg->{digest};

    if ($scfg->{nodes}) {
        $scfg->{nodes} = PVE::Storage::Plugin->encode_value($scfg->{type}, 'nodes', $scfg->{nodes});
    }

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SDN zones index.",
    permissions => {
	description => "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/cluster/sdn/zones/<zone>'",
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    type => {
		description => "Only list sdn zones of specific type",
		type => 'string',
		enum => $sdn_zones_type_enum,
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { zone => { type => 'string'}, 
			    type => { type => 'string'},
			  },
	},
	links => [ { rel => 'child', href => "{zone}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();


	my $cfg = PVE::Network::SDN::Zones::config();

	my @sids = PVE::Network::SDN::Zones::sdn_zones_ids($cfg);
	my $res = [];
	foreach my $id (@sids) {
#	    my $privs = [ 'SDN.Audit', 'SDN.Allocate' ];
#	    next if !$rpcenv->check_any($authuser, "/cluster/sdn/zones/$id", $privs, 1);

	    my $scfg = &$api_sdn_zones_config($cfg, $id);
	    next if $param->{type} && $param->{type} ne $scfg->{type};

	    my $plugin_config = $cfg->{ids}->{$id};
	    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($plugin_config->{type});
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{zone}',
    method => 'GET',
    description => "Read sdn zone configuration.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/zones/{zone}', ['SDN.Allocate']],
#   },

    parameters => {
    	additionalProperties => 0,
	properties => {
	    zone => get_standard_option('pve-sdn-zone-id'),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Network::SDN::Zones::config();

	return &$api_sdn_zones_config($cfg, $param->{zone});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new sdn zone object.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/zones', ['SDN.Allocate']],
#    },
    parameters => PVE::Network::SDN::Zones::Plugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $id = extract_param($param, 'zone');

	my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($type);
	my $opts = $plugin->check_config($id, $param, 1, 1);

        PVE::Network::SDN::Zones::lock_sdn_zones_config(
	    sub {

		my $zone_cfg = PVE::Network::SDN::Zones::config();
		my $controller_cfg = PVE::Network::SDN::Controllers::config();

		my $scfg = undef;
		if ($scfg = PVE::Network::SDN::Zones::sdn_zones_config($zone_cfg, $id, 1)) {
		    die "sdn zone object ID '$id' already defined\n";
		}

		$zone_cfg->{ids}->{$id} = $opts;
		$plugin->on_update_hook($id, $zone_cfg, $controller_cfg);

		PVE::Network::SDN::Zones::write_config($zone_cfg);

	    }, "create sdn zone object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'revert_configuration',
    protected => 1,
    path => '',
    method => 'DELETE',
    description => "Revert sdn zone changes.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/zones', ['SDN.Allocate']],
#    },
    parameters => {
	additionalProperties => 0,
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	die "no sdn zones changes to revert" if !-e "/etc/pve/sdn/zones.cfg.new";
	unlink "/etc/pve/sdn/zones.cfg.new";

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{zone}',
    method => 'PUT',
    description => "Update sdn zone object configuration.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/zones', ['SDN.Allocate']],
#    },
    parameters => PVE::Network::SDN::Zones::Plugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'zone');
	my $digest = extract_param($param, 'digest');

        PVE::Network::SDN::Zones::lock_sdn_zones_config(
	 sub {

	    my $zone_cfg = PVE::Network::SDN::Zones::config();
	    my $controller_cfg = PVE::Network::SDN::Controllers::config();

	    PVE::SectionConfig::assert_if_modified($zone_cfg, $digest);

	    my $scfg = PVE::Network::SDN::Zones::sdn_zones_config($zone_cfg, $id);

	    my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($scfg->{type});
	    my $opts = $plugin->check_config($id, $param, 0, 1);

	    foreach my $k (%$opts) {
		$scfg->{$k} = $opts->{$k};
	    }

	    $plugin->on_update_hook($id, $zone_cfg, $controller_cfg);

	    PVE::Network::SDN::Zones::write_config($zone_cfg);

	    }, "update sdn zone object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{zone}',
    method => 'DELETE',
    description => "Delete sdn zone object configuration.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/zones', ['SDN.Allocate']],
#    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    zone => get_standard_option('pve-sdn-zone-id', {
                completion => \&PVE::Network::SDN::Zones::complete_sdn_zones,
            }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'zone');

        PVE::Network::SDN::Zones::lock_sdn_zones_config(
	    sub {

		my $cfg = PVE::Network::SDN::Zones::config();

		my $scfg = PVE::Network::SDN::Zones::sdn_zones_config($cfg, $id);

		my $plugin = PVE::Network::SDN::Zones::Plugin->lookup($scfg->{type});

		my $vnet_cfg = PVE::Network::SDN::Vnets::config();

		$plugin->on_delete_hook($id, $vnet_cfg);

		delete $cfg->{ids}->{$id};
		PVE::Network::SDN::Zones::write_config($cfg);

	    }, "delete sdn zone object failed");


	return undef;
    }});

1;
