package PVE::API2::Network::SDN::Subnets;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Exception qw(raise raise_param_exc);
use PVE::Network::SDN;
use PVE::Network::SDN::Subnets;
use PVE::Network::SDN::SubnetPlugin;
use PVE::Network::SDN::Vnets;
use PVE::Network::SDN::Ipams;
use PVE::Network::SDN::Ipams::Plugin;

use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $api_sdn_subnets_config = sub {
    my ($cfg, $id) = @_;

    my $scfg = dclone(PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $id));
    $scfg->{subnet} = $id;
    $scfg->{cidr} = $id =~ s/-/\//r;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SDN subnets index.",
    permissions => {
	description => "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/sdn/subnets/<subnet>'",
	user => 'all',
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    vnet => get_standard_option('pve-sdn-vnet-id'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {},
	},
	links => [ { rel => 'child', href => "{subnet}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

        my $vnetid = $param->{vnet};

	my $cfg = PVE::Network::SDN::Subnets::config();

	my @sids = PVE::Network::SDN::Subnets::sdn_subnets_ids($cfg);
	my $res = [];
	foreach my $id (@sids) {
	    my $privs = [ 'SDN.Audit', 'SDN.Allocate' ];
	    next if !$rpcenv->check_any($authuser, "/sdn/vnets/$vnetid/subnets/$id", $privs, 1);

	    my $scfg = &$api_sdn_subnets_config($cfg, $id);
	    next if !$scfg->{vnet} || $scfg->{vnet} ne $vnetid;
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{subnet}',
    method => 'GET',
    description => "Read sdn subnet configuration.",
    permissions => {
	check => ['perm', '/sdn/vnets/{vnet}/subnets/{subnet}', ['SDN.Allocate']],
   },

    parameters => {
	additionalProperties => 0,
	properties => {
	    vnet => get_standard_option('pve-sdn-vnet-id'),
	    subnet => get_standard_option('pve-sdn-subnet-id', {
		completion => \&PVE::Network::SDN::Subnets::complete_sdn_subnets,
	    }),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Network::SDN::Subnets::config();
        my $scfg = &$api_sdn_subnets_config($cfg, $param->{subnet});

	raise_param_exc({ vnet => "wrong vnet"}) if $param->{vnet} ne $scfg->{vnet};

	return $scfg;
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new sdn subnet object.",
    permissions => {
	check => ['perm', '/sdn/vnets/{vnet}/subnets', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::SubnetPlugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $cidr = extract_param($param, 'subnet');
	my $id = $cidr =~ s/\//-/r;

	# create /etc/pve/sdn directory
	PVE::Cluster::check_cfs_quorum();
	mkdir("/etc/pve/sdn") if ! -d '/etc/pve/sdn';

        PVE::Network::SDN::lock_sdn_config(
	    sub {

		my $cfg = PVE::Network::SDN::Subnets::config();
		my $opts = PVE::Network::SDN::SubnetPlugin->check_config($id, $param, 1, 1);

		my $scfg = undef;
		if ($scfg = PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $id, 1)) {
		    die "sdn subnet object ID '$id' already defined\n";
		}

		$cfg->{ids}->{$id} = $opts;
		PVE::Network::SDN::SubnetPlugin->on_update_hook($id, $opts);

		PVE::Network::SDN::Subnets::write_config($cfg);
		PVE::Network::SDN::increase_version();

	    }, "create sdn subnet object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{subnet}',
    method => 'PUT',
    description => "Update sdn subnet object configuration.",
    permissions => {
	check => ['perm', '/sdn/vnets/{vnet}/subnets', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::SubnetPlugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'subnet');
	my $digest = extract_param($param, 'digest');

        PVE::Network::SDN::lock_sdn_config(
	 sub {

	    my $cfg = PVE::Network::SDN::Subnets::config();
	    my $scfg = &$api_sdn_subnets_config($cfg, $id);

	    PVE::SectionConfig::assert_if_modified($cfg, $digest);

	    my $opts = PVE::Network::SDN::SubnetPlugin->check_config($id, $param, 0, 1);
	    $cfg->{ids}->{$id} = $opts;

	    PVE::Network::SDN::SubnetPlugin->on_update_hook($id, $opts, $scfg);

	    PVE::Network::SDN::Subnets::write_config($cfg);
	    PVE::Network::SDN::increase_version();

	    }, "update sdn subnet object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{subnet}',
    method => 'DELETE',
    description => "Delete sdn subnet object configuration.",
    permissions => {
	check => ['perm', '/sdn/vnets/{vnet}/subnets', ['SDN.Allocate']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
            vnet => get_standard_option('pve-sdn-vnet-id'),
	    subnet => get_standard_option('pve-sdn-subnet-id', {
                completion => \&PVE::Network::SDN::Subnets::complete_sdn_subnets,
            }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'subnet');

        PVE::Network::SDN::lock_sdn_config(
	    sub {
		my $cfg = PVE::Network::SDN::Subnets::config();

		my $scfg = PVE::Network::SDN::Subnets::sdn_subnets_config($cfg, $id);

		my $subnets_cfg = PVE::Network::SDN::Subnets::config();
		my $vnets_cfg = PVE::Network::SDN::Vnets::config();

		PVE::Network::SDN::SubnetPlugin->on_delete_hook($id, $subnets_cfg, $vnets_cfg);

		my $ipam_cfg = PVE::Network::SDN::Ipams::config();
		my $ipam = $cfg->{ids}->{$id}->{ipam};
		if ($ipam) {
		    raise_param_exc({ ipam => "$ipam not existing"}) if !$ipam_cfg->{ids}->{$ipam};
		    my $plugin_config = $ipam_cfg->{ids}->{$ipam};
		    my $plugin = PVE::Network::SDN::Ipams::Plugin->lookup($plugin_config->{type});
		    $plugin->del_subnet($plugin_config, $id, $scfg);
		}

		delete $cfg->{ids}->{$id};

		PVE::Network::SDN::Subnets::write_config($cfg);
		PVE::Network::SDN::increase_version();

	    }, "delete sdn subnet object failed");


	return undef;
    }});

1;
