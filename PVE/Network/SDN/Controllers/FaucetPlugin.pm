package PVE::Network::SDN::Controllers::FaucetPlugin;

use strict;
use warnings;
use PVE::Network::SDN::Controllers::Plugin;
use PVE::Tools;
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use CPAN::Meta::YAML;
use Encode;

use base('PVE::Network::SDN::Controllers::Plugin');

sub type {
    return 'faucet';
}

sub properties {
    return {
    };
}

# Plugin implementation
sub generate_controller_config {
    my ($class, $plugin_config, $controller_cfg, $id, $uplinks, $config) = @_;

}

sub generate_controller_zone_config {
    my ($class, $plugin_config, $controller, $controller_cfg, $id, $uplinks, $config) = @_;

    my $dpid = $plugin_config->{'dp-id'};
    my $dphex = printf("%x",$dpid);

    my $zone_config = {
				dp_id => $dphex,
				hardware => "Open vSwitch",
			   };

    $config->{faucet}->{dps}->{$id} = $zone_config;

}


sub generate_controller_vnet_config {
    my ($class, $plugin_config, $controller, $zone, $zoneid, $vnetid, $config) = @_;

    my $mac = $plugin_config->{mac};
    my $ipv4 = $plugin_config->{ipv4};
    my $ipv6 = $plugin_config->{ipv6};
    my $tag = $plugin_config->{tag};
    my $alias = $plugin_config->{alias};

    my @ips = ();
    push @ips, $ipv4 if $ipv4;
    push @ips, $ipv6 if $ipv6;

    my $vlan_config = { vid => $tag };

    $vlan_config->{description} = $alias if $alias;
    $vlan_config->{faucet_mac} = $mac if $mac;
    $vlan_config->{faucet_vips} = \@ips if scalar @ips > 0;

    $config->{faucet}->{vlans}->{$vnetid} = $vlan_config;

    push(@{$config->{faucet}->{routers}->{$zoneid}->{vlans}} , $vnetid);

}

sub write_controller_config {
    my ($class, $plugin_config, $config) = @_;

    my $rawconfig = encode('UTF-8', CPAN::Meta::YAML::Dump($config->{faucet}));

    return if !$rawconfig;
    return if !-d "/etc/faucet";

    my $frr_config_file = "/etc/faucet/faucet.yaml";

    my $writefh = IO::File->new($frr_config_file,">");
    print $writefh $rawconfig;
    $writefh->close();
}

sub reload_controller {
    my ($class) = @_;

    my $conf_file = "/etc/faucet/faucet.yaml";
    my $bin_path = "/usr/bin/faucet";

    if (-e $conf_file && -e $bin_path) {
        PVE::Tools::run_command(['systemctl', 'reload', 'faucet']);
    }
}

1;

