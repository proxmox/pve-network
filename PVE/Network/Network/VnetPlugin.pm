package PVE::Network::Network::VnetPlugin;

use strict;
use warnings;
use PVE::Network::Network::Plugin;

use base('PVE::Network::Network::Plugin');

use PVE::Cluster;

# dynamically include PVE::QemuServer and PVE::LXC
# to avoid dependency problems
my $have_qemu_server;
eval {
    require PVE::QemuServer;
    require PVE::QemuConfig;
    $have_qemu_server = 1;
};

my $have_lxc;
eval {
    require PVE::LXC;
    require PVE::LXC::Config;

    $have_lxc = 1;
};

sub type {
    return 'vnet';
}



sub properties {
    return {
	transportzone => {
            type => 'string',
            description => "transportzone id",
	},
	tag => {
            type => 'integer',
            description => "vlan or vxlan id",
	},
        alias => {
            type => 'string',
            description => "alias name of the vnet",
	    optional => 1,
        },
        mtu => {
            type => 'integer',
            description => "mtu",
	    optional => 1,
        },
        ipv4 => {
            description => "Anycast router ipv4 address.",
            type => 'string', format => 'ipv4',
            optional => 1,
        },
	ipv6 => {
	    description => "Anycast router ipv6 address.",
	    type => 'string', format => 'ipv6',
	    optional => 1,
	},
        mac => {
            type => 'boolean',
            description => "Anycast router mac address",
	    optional => 1,
        }
    };
}

sub options {
    return {
        transportzone => { optional => 0},
        tag => { optional => 0},
        alias => { optional => 1 },
        ipv4 => { optional => 1 },
        ipv6 => { optional => 1 },
        mtu => { optional => 1 },
    };
}

sub on_delete_hook {
    my ($class, $networkid, $scfg) = @_;

    # verify than no vm or ct have interfaces in this bridge
    my $vmdata = read_cluster_vm_config();

    foreach my $vmid (sort keys %{$vmdata->{qemu}}) {
	my $conf = $vmdata->{qemu}->{$vmid};
	foreach my $netid (sort keys %$conf) {
	    next if $netid !~ m/^net(\d+)$/;
	    my $net = PVE::QemuServer::parse_net($conf->{$netid});
	    die "vnet $networkid is used by vm $vmid" if $net->{bridge} eq $networkid;
	}
    }

    foreach my $vmid (sort keys %{$vmdata->{lxc}}) {
	my $conf = $vmdata->{lxc}->{$vmid};
	foreach my $netid (sort keys %$conf) {
	    next if $netid !~ m/^net(\d+)$/;
	    my $net = PVE::LXC::Config->parse_lxc_network($conf->{$netid});
	    die "vnet $networkid is used by ct $vmid" if $net->{bridge} eq $networkid;
	}
    }

}

sub on_update_hook {
    my ($class, $networkid, $network_cfg) = @_;
    # verify that tag is not already defined in another vnet
    if (defined($network_cfg->{ids}->{$networkid}->{tag})) {
	my $tag = $network_cfg->{ids}->{$networkid}->{tag};
	foreach my $id (keys %{$network_cfg->{ids}}) {
	    next if $id eq $networkid;
	    my $network = $network_cfg->{ids}->{$id};
	    if ($network->{type} eq 'vnet' && defined($network->{tag})) {
		die "tag $tag already exist in vnet $id" if $tag eq $network->{tag};
	    }
	}
    }
}

sub read_cluster_vm_config {

    my $qemu = {};
    my $lxc = {};

    my $vmdata = { qemu => $qemu, lxc => $lxc };

    my $vmlist = PVE::Cluster::get_vmlist();
    return $vmdata if !$vmlist || !$vmlist->{ids};
    my $ids = $vmlist->{ids};

    foreach my $vmid (keys %$ids) {
	next if !$vmid;
	my $d = $ids->{$vmid};
	next if !$d->{type};
	if ($d->{type} eq 'qemu' && $have_qemu_server) {
	    my $cfspath = PVE::QemuConfig->cfs_config_path($vmid);
	    if (my $conf = PVE::Cluster::cfs_read_file($cfspath)) {
		$qemu->{$vmid} = $conf;
	    }
	} elsif ($d->{type} eq 'lxc' && $have_lxc) {
	    my $cfspath = PVE::LXC::Config->cfs_config_path($vmid);
	    if (my $conf = PVE::Cluster::cfs_read_file($cfspath)) {
		$lxc->{$vmid} = $conf;
	    }
	}
    }

    return $vmdata;
};

1;
