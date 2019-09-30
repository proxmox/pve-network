package PVE::API2::Network::SDN;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Network::SDN;
use PVE::Network::SDN::Plugin;
use PVE::Network::SDN::VlanPlugin;
use PVE::Network::SDN::VxlanPlugin;
use PVE::Network::SDN::VnetPlugin;
use PVE::Network::SDN::FrrPlugin;
use PVE::Network::SDN::OVSFaucetPlugin;
use PVE::Network::SDN::FaucetPlugin;

use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $sdn_type_enum = PVE::Network::SDN::Plugin->lookup_types();

my $api_sdn_config = sub {
    my ($cfg, $sdnid) = @_;

    my $scfg = dclone(PVE::Network::SDN::sdn_config($cfg, $sdnid));
    $scfg->{sdn} = $sdnid;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SDN index.",
    permissions => {
	description => "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/cluster/sdn/<sdn>'",
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    type => {
		description => "Only list sdn of specific type",
		type => 'string',
		enum => $sdn_type_enum,
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { sdn => { type => 'string'} },
	},
	links => [ { rel => 'child', href => "{sdn}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();


	my $cfg = PVE::Network::SDN::config();

	my @sids = PVE::Network::SDN::sdn_ids($cfg);
	my $res = [];
	foreach my $sdnid (@sids) {
#	    my $privs = [ 'SDN.Audit', 'SDN.Allocate' ];
#	    next if !$rpcenv->check_any($authuser, "/cluster/sdn/$sdnid", $privs, 1);

	    my $scfg = &$api_sdn_config($cfg, $sdnid);
	    next if $param->{type} && $param->{type} ne $scfg->{type};
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{sdn}',
    method => 'GET',
    description => "Read sdn configuration.",
#    permissions => {
#	check => ['perm', '/cluster/sdn/{sdn}', ['SDN.Allocate']],
#   },

    parameters => {
    	additionalProperties => 0,
	properties => {
	    sdn => get_standard_option('pve-sdn-id'),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Network::SDN::config();

	return &$api_sdn_config($cfg, $param->{sdn});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new sdn object.",
#    permissions => {
#	check => ['perm', '/cluster/sdn', ['SDN.Allocate']],
#    },
    parameters => PVE::Network::SDN::Plugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $sdnid = extract_param($param, 'sdn');

	my $plugin = PVE::Network::SDN::Plugin->lookup($type);
	my $opts = $plugin->check_config($sdnid, $param, 1, 1);

        PVE::Network::SDN::lock_sdn_config(
	    sub {

		my $cfg = PVE::Network::SDN::config();

		my $scfg = undef;
		if ($scfg = PVE::Network::SDN::sdn_config($cfg, $sdnid, 1)) {
		    die "sdn object ID '$sdnid' already defined\n";
		}

		$cfg->{ids}->{$sdnid} = $opts;
		$plugin->on_update_hook($sdnid, $cfg);
		#also verify transport associated to vnet
		if($scfg && $scfg->{type} eq 'vnet') {
		    my $transportid = $scfg->{transportzone};
		    die "missing transportzone" if !$transportid;
		    my $transport_cfg = $cfg->{ids}->{$transportid};
		    my $transport_plugin = PVE::Network::SDN::Plugin->lookup($transport_cfg->{type});
		    $transport_plugin->on_update_hook($transportid, $cfg);
		}

		PVE::Network::SDN::write_config($cfg);

	    }, "create sdn object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'apply_configuration',
    protected => 1,
    path => '',
    method => 'PUT',
    description => "Apply sdn changes.",
#    permissions => {
#	check => ['perm', '/cluster/sdn', ['SDN.Allocate']],
#    },
    parameters => {
	additionalProperties => 0,
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	die "no sdn changes to apply" if !-e "/etc/pve/sdn.cfg.new";
	rename("/etc/pve/sdn.cfg.new", "/etc/pve/sdn.cfg")
	    || die "applying sdn.cfg changes failed - $!\n";


	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'revert_configuration',
    protected => 1,
    path => '',
    method => 'DELETE',
    description => "Revert sdn changes.",
#    permissions => {
#	check => ['perm', '/cluster/sdn', ['SDN.Allocate']],
#    },
    parameters => {
	additionalProperties => 0,
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	die "no sdn changes to revert" if !-e "/etc/pve/sdn.cfg.new";
	unlink "/etc/pve/sdn.cfg.new";

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{sdn}',
    method => 'PUT',
    description => "Update sdn object configuration.",
#    permissions => {
#	check => ['perm', '/cluster/sdn', ['SDN.Allocate']],
#    },
    parameters => PVE::Network::SDN::Plugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $sdnid = extract_param($param, 'sdn');
	my $digest = extract_param($param, 'digest');

        PVE::Network::SDN::lock_sdn_config(
	 sub {

	    my $cfg = PVE::Network::SDN::config();

	    PVE::SectionConfig::assert_if_modified($cfg, $digest);

	    my $scfg = PVE::Network::SDN::sdn_config($cfg, $sdnid);

	    my $plugin = PVE::Network::SDN::Plugin->lookup($scfg->{type});
	    my $opts = $plugin->check_config($sdnid, $param, 0, 1);

	    foreach my $k (%$opts) {
		$scfg->{$k} = $opts->{$k};
	    }

	    $plugin->on_update_hook($sdnid, $cfg);
	    #also verify transport associated to vnet
            if($scfg->{type} eq 'vnet') {
                my $transportid = $scfg->{transportzone};
                die "missing transportzone" if !$transportid;
                my $transport_cfg = $cfg->{ids}->{$transportid};
                my $transport_plugin = PVE::Network::SDN::Plugin->lookup($transport_cfg->{type});
                $transport_plugin->on_update_hook($transportid, $cfg);
            }
	    PVE::Network::SDN::write_config($cfg);

	    }, "update sdn object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{sdn}',
    method => 'DELETE',
    description => "Delete sdn object configuration.",
#    permissions => {
#	check => ['perm', '/cluster/sdn', ['SDN.Allocate']],
#    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    sdn => get_standard_option('pve-sdn-id', {
                completion => \&PVE::Network::SDN::complete_sdn,
            }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $sdnid = extract_param($param, 'sdn');

        PVE::Network::SDN::lock_sdn_config(
	    sub {

		my $cfg = PVE::Network::SDN::config();

		my $scfg = PVE::Network::SDN::sdn_config($cfg, $sdnid);

		my $plugin = PVE::Network::SDN::Plugin->lookup($scfg->{type});
		$plugin->on_delete_hook($sdnid, $cfg);

		delete $cfg->{ids}->{$sdnid};
		PVE::Network::SDN::write_config($cfg);

	    }, "delete sdn object failed");


	return undef;
    }});

1;
