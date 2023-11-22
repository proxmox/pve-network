package PVE::API2::Network::SDN::Dns;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Network::SDN;
use PVE::Network::SDN::Dns;
use PVE::Network::SDN::Dns::Plugin;
use PVE::Network::SDN::Dns::PowerdnsPlugin;

use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my $sdn_dns_type_enum = PVE::Network::SDN::Dns::Plugin->lookup_types();

my $api_sdn_dns_config = sub {
    my ($cfg, $id) = @_;

    my $scfg = dclone(PVE::Network::SDN::Dns::sdn_dns_config($cfg, $id));
    $scfg->{dns} = $id;
    $scfg->{digest} = $cfg->{digest};

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "SDN dns index.",
    permissions => {
	description => "Only list entries where you have 'SDN.Audit' or 'SDN.Allocate' permissions on '/sdn/dns/<dns>'",
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    type => {
		description => "Only list sdn dns of specific type",
		type => 'string',
		enum => $sdn_dns_type_enum,
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { dns => { type => 'string'},
			    type => { type => 'string'},
			  },
	},
	links => [ { rel => 'child', href => "{dns}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();


	my $cfg = PVE::Network::SDN::Dns::config();

	my @sids = PVE::Network::SDN::Dns::sdn_dns_ids($cfg);
	my $res = [];
	foreach my $id (@sids) {
	    my $privs = [ 'SDN.Audit', 'SDN.Allocate' ];
	    next if !$rpcenv->check_any($authuser, "/sdn/dns/$id", $privs, 1);

	    my $scfg = &$api_sdn_dns_config($cfg, $id);
	    next if $param->{type} && $param->{type} ne $scfg->{type};

	    my $plugin_config = $cfg->{ids}->{$id};
	    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($plugin_config->{type});
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{dns}',
    method => 'GET',
    description => "Read sdn dns configuration.",
    permissions => {
	check => ['perm', '/sdn/dns/{dns}', ['SDN.Allocate']],
   },

    parameters => {
    	additionalProperties => 0,
	properties => {
	    dns => get_standard_option('pve-sdn-dns-id'),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Network::SDN::Dns::config();

	return &$api_sdn_dns_config($cfg, $param->{dns});
    }});

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new sdn dns object.",
    permissions => {
	check => ['perm', '/sdn/dns', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::Dns::Plugin->createSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $id = extract_param($param, 'dns');

	my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($type);
	my $opts = $plugin->check_config($id, $param, 1, 1);

        # create /etc/pve/sdn directory
        PVE::Cluster::check_cfs_quorum();
        mkdir("/etc/pve/sdn");

        PVE::Network::SDN::lock_sdn_config(
	    sub {

		my $dns_cfg = PVE::Network::SDN::Dns::config();

		my $scfg = undef;
		if ($scfg = PVE::Network::SDN::Dns::sdn_dns_config($dns_cfg, $id, 1)) {
		    die "sdn dns object ID '$id' already defined\n";
		}

		$dns_cfg->{ids}->{$id} = $opts;

		my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($opts->{type});
		$plugin->on_update_hook($opts);

		PVE::Network::SDN::Dns::write_config($dns_cfg);

	    }, "create sdn dns object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{dns}',
    method => 'PUT',
    description => "Update sdn dns object configuration.",
    permissions => {
	check => ['perm', '/sdn/dns', ['SDN.Allocate']],
    },
    parameters => PVE::Network::SDN::Dns::Plugin->updateSchema(),
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'dns');
	my $digest = extract_param($param, 'digest');
	my $delete = extract_param($param, 'delete');

        PVE::Network::SDN::lock_sdn_config(
	 sub {

	    my $dns_cfg = PVE::Network::SDN::Dns::config();

	    PVE::SectionConfig::assert_if_modified($dns_cfg, $digest);

	    my $scfg = PVE::Network::SDN::Dns::sdn_dns_config($dns_cfg, $id);

	    my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($scfg->{type});
	    my $opts = $plugin->check_config($id, $param, 0, 1);

	    if ($delete) {
		$delete = [ PVE::Tools::split_list($delete) ];
		my $options = $plugin->private()->{options}->{$scfg->{type}};
		PVE::SectionConfig::delete_from_config($scfg, $options, $opts, $delete);
	    }

	    foreach my $k (%$opts) {
		$scfg->{$k} = $opts->{$k};
	    }

	    $plugin->on_update_hook($scfg);

	    PVE::Network::SDN::Dns::write_config($dns_cfg);

	    }, "update sdn dns object failed");

	return undef;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{dns}',
    method => 'DELETE',
    description => "Delete sdn dns object configuration.",
    permissions => {
	check => ['perm', '/sdn/dns', ['SDN.Allocate']],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    dns => get_standard_option('pve-sdn-dns-id', {
                completion => \&PVE::Network::SDN::Dns::complete_sdn_dns,
            }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $id = extract_param($param, 'dns');

        PVE::Network::SDN::lock_sdn_config(
	    sub {

		my $cfg = PVE::Network::SDN::Dns::config();

		my $scfg = PVE::Network::SDN::Dns::sdn_dns_config($cfg, $id);

		my $plugin = PVE::Network::SDN::Dns::Plugin->lookup($scfg->{type});

		delete $cfg->{ids}->{$id};
		PVE::Network::SDN::Dns::write_config($cfg);

	    }, "delete sdn dns object failed");

	return undef;
    }});

1;
