package PVE::API2::Network::SDN::Vnets;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::VnetPlugin;

use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $api_sdn_vnets_config = sub {
    my ($cfg, $id) = @_;

    my $scfg = dclone(PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $id));
    $scfg->{vnet} = $id;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SDN vnets index.",
    permissions => {
	description => "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/cluster/sdn/vnets/<vnet>'",
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {},
	},
	links => [ { rel => 'child', href => "{vnet}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();


	my $cfg = PVE::Network::SDN::Vnets::config();

	my @sids = PVE::Network::SDN::Vnets::sdn_vnets_ids($cfg);
	my $res = [];
	foreach my $id (@sids) {
#	    my $privs = [ 'SDN.Audit', 'SDN.Allocate' ];
#	    next if !$rpcenv->check_any($authuser, "/cluster/sdn/vnets/$id", $privs, 1);

	    my $scfg = &$api_sdn_vnets_config($cfg, $id);
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{vnet}',
    method => 'GET',
    description => "Read sdn vnet configuration.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/vnets/{vnet}', ['SDN.Allocate']],
#   },

    parameters => {
        additionalProperties => 0,
        properties => {
            vnet => get_standard_option('pve-sdn-vnet-id', {
                completion => \&PVE::Network::SDN::Vnets::complete_sdn_vnets,
            }),
        },
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Network::SDN::Vnets::config();

	return &$api_sdn_vnets_config($cfg, $param->{vnet});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new sdn vnet object.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/vnets', ['SDN.Allocate']],
#    },
    parameters => PVE::Network::SDN::VnetPlugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $id = extract_param($param, 'vnet');

        PVE::Network::SDN::Vnets::lock_sdn_vnets_config(
	    sub {

		my $cfg = PVE::Network::SDN::Vnets::config();
		my $opts = PVE::Network::SDN::VnetPlugin->check_config($id, $param, 1, 1);

		my $scfg = undef;
		if ($scfg = PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $id, 1)) {
		    die "sdn vnet object ID '$id' already defined\n";
		}

		$cfg->{ids}->{$id} = $opts;
		PVE::Network::SDN::VnetPlugin->on_update_hook($id, $cfg);

		PVE::Network::SDN::Vnets::write_config($cfg);

	    }, "create sdn vnet object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'apply_configuration',
    protected => 1,
    path => '',
    method => 'PUT',
    description => "Apply sdn vnet changes.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/vnets', ['SDN.Allocate']],
#    },
    parameters => {
	additionalProperties => 0,
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	die "no sdn vnet changes to apply" if !-e "/etc/pve/sdn/vnets.cfg.new";
	rename("/etc/pve/sdn/vnets.cfg.new", "/etc/pve/sdn/vnets.cfg")
	    || die "applying sdn/vnets.cfg changes failed - $!\n";


	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'revert_configuration',
    protected => 1,
    path => '',
    method => 'DELETE',
    description => "Revert sdn vnet changes.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/vnets', ['SDN.Allocate']],
#    },
    parameters => {
	additionalProperties => 0,
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	die "no sdn vnets changes to revert" if !-e "/etc/pve/sdn/vnets.cfg.new";
	unlink "/etc/pve/sdn/vnets.cfg.new";

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{vnet}',
    method => 'PUT',
    description => "Update sdn vnet object configuration.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/vnets', ['SDN.Allocate']],
#    },
    parameters => PVE::Network::SDN::VnetPlugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'vnet');
	my $digest = extract_param($param, 'digest');

        PVE::Network::SDN::Vnets::lock_sdn_vnets_config(
	 sub {

	    my $cfg = PVE::Network::SDN::Vnets::config();

	    PVE::SectionConfig::assert_if_modified($cfg, $digest);

	    my $scfg = PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $id);
	    my $opts = PVE::Network::SDN::VnetPlugin->check_config($id, $param, 0, 1);

	    foreach my $k (%$opts) {
		$scfg->{$k} = $opts->{$k};
	    }

	    PVE::Network::SDN::VnetPlugin->on_update_hook($id, $cfg);

	    PVE::Network::SDN::Vnets::write_config($cfg);

	    }, "update sdn vnet object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{vnet}',
    method => 'DELETE',
    description => "Delete sdn vnet object configuration.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/vnets', ['SDN.Allocate']],
#    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    vnet => get_standard_option('pve-sdn-vnet-id', {
                completion => \&PVE::Network::SDN::Vnets::complete_sdn_vnets,
            }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'vnet');

        PVE::Network::SDN::Vnets::lock_sdn_vnets_config(
	    sub {

		my $cfg = PVE::Network::SDN::Vnets::config();

		my $scfg = PVE::Network::SDN::Vnets::sdn_vnets_config($cfg, $id);

		my $vnet_cfg = PVE::Network::SDN::Vnets::config();

		PVE::Network::SDN::VnetPlugin->on_delete_hook($id, $vnet_cfg);

		delete $cfg->{ids}->{$id};
		PVE::Network::SDN::Vnets::write_config($cfg);

	    }, "delete sdn vnet object failed");


	return undef;
    }});

1;
