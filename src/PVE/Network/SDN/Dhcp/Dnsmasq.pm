package PVE::Network::SDN::Dhcp::Dnsmasq;

use strict;
use warnings;

use base qw(PVE::Network::SDN::Dhcp::Plugin);

use Net::IP qw(:PROC);
use PVE::Tools qw(file_set_contents run_command lock_file);

use File::Copy;
use Net::DBus;

use PVE::RESTEnvironment qw(log_warn);

my $DNSMASQ_CONFIG_ROOT = '/etc/dnsmasq.d';
my $DNSMASQ_DEFAULT_ROOT = '/etc/default';
my $DNSMASQ_LEASE_ROOT = '/var/lib/misc';

sub type {
    return 'dnsmasq';
}

my sub assert_dnsmasq_installed {
    my ($noerr) = @_;

    my $bin_path = "/usr/sbin/dnsmasq";
    if (!-e $bin_path) {
	return if $noerr; # just ignore, e.g., in case zone doesn't use DHCP at all
	log_warn("please install the 'dnsmasq' package in order to use the DHCP feature!");
	die "cannot reload with missing 'dnsmasq' package\n";
    }
    return 1;
}

sub ethers_file {
    my ($dhcpid) = @_;
    return "$DNSMASQ_CONFIG_ROOT/$dhcpid/ethers";
}

sub update_lease {
    my ($dhcpid, $ip4, $mac) = @_;
    #update lease as ip could still be associated to an old removed mac
    my $bus = Net::DBus->system();
    my $dnsmasq = $bus->get_service("uk.org.thekelleys.dnsmasq.$dhcpid");
    my $manager = $dnsmasq->get_object("/uk/org/thekelleys/dnsmasq","uk.org.thekelleys.dnsmasq.$dhcpid");

    my @hostname = unpack("C*", "*");
    $manager->AddDhcpLease($ip4, $mac, \@hostname, undef, 0, 0, 0) if $ip4;
}

sub add_ip_mapping {
    my ($class, $dhcpid, $macdb, $mac, $ip4, $ip6) = @_;

    my $ethers_file = ethers_file($dhcpid);
    my $ethers_tmp_file = "$ethers_file.tmp";

    my $reload = undef;

    my $appendFn = sub {
	open(my $in, '<', $ethers_file) or die "Could not open file '$ethers_file' $!\n";
	open(my $out, '>', $ethers_tmp_file) or die "Could not open file '$ethers_tmp_file' $!\n";

	my $match = undef;

 	while (my $line = <$in>) {
	    chomp($line);
	    my $parsed_ip4 = undef;
	    my $parsed_ip6 = undef;
	    my ($parsed_mac, $parsed_ip1, $parsed_ip2) = split(/,/, $line);

	    if ($parsed_ip2) {
		$parsed_ip4 = $parsed_ip1;
		$parsed_ip6 = $parsed_ip2;
	    } elsif (Net::IP::ip_is_ipv4($parsed_ip1)) {
		$parsed_ip4 = $parsed_ip1;
	    } else {
		$parsed_ip6 = $parsed_ip1;
	    }
	    $parsed_ip6 = $1 if $parsed_ip6 && $parsed_ip6 =~ m/\[(\S+)\]/;

	    #delete changed
	    if (!defined($macdb->{macs}->{$parsed_mac}) ||
		($parsed_ip4 && $macdb->{macs}->{$parsed_mac}->{'ip4'} && $macdb->{macs}->{$parsed_mac}->{'ip4'} ne $parsed_ip4) ||
		($parsed_ip6 && $macdb->{macs}->{$parsed_mac}->{'ip6'} && $macdb->{macs}->{$parsed_mac}->{'ip6'} ne $parsed_ip6)) {
                    $reload = 1;
		    next;
	    }

	    if ($parsed_mac eq $mac) {
		$match = 1 if $ip4 && $parsed_ip4 && $ip4;
		$match = 1 if $ip6 && $parsed_ip6 && $ip6;
	    }

	    print $out "$line\n";
	}

	if(!$match) {
	    my $reservation = $mac;
	    $reservation .= ",$ip4" if $ip4;
	    $reservation .= ",[$ip6]" if $ip6;
	    print $out "$reservation\n";
	    $reload = 1;
	}

	close $in;
	close $out;
	move $ethers_tmp_file, $ethers_file;
	chmod 0644, $ethers_file;
    };

    PVE::Tools::lock_file($ethers_file, 10, $appendFn);

    if ($@) {
	warn "Unable to add $mac to the dnsmasq configuration: $@\n";
	return;
    }

    my $service_name = "dnsmasq\@$dhcpid";
    systemctl_service('reload', $service_name) if $reload;
    update_lease($dhcpid, $ip4, $mac);
}

sub configure_subnet {
    my ($class, $config, $dhcpid, $vnetid, $subnet_config) = @_;

    die "No gateway defined for subnet $subnet_config->{id}"
	if !$subnet_config->{gateway};

    my $tag = $subnet_config->{id};

    my ($zone, $network, $mask) = split(/-/, $tag);

    if (Net::IP::ip_is_ipv4($network)) {
	$mask = (2 ** $mask - 1) << (32 - $mask);
	$mask = join( '.', unpack( "C4", pack( "N", $mask ) ) );
    }

    push @{$config}, "dhcp-range=set:$tag,$network,static,$mask,infinite";

    my $option_string;
    if (ip_is_ipv6($subnet_config->{network})) {
	$option_string = 'option6';
    } else {
	$option_string = 'option';
	push @{$config}, "dhcp-option=tag:$tag,$option_string:router,$subnet_config->{gateway}";
    }

    push @{$config}, "dhcp-option=tag:$tag,$option_string:dns-server,$subnet_config->{'dhcp-dns-server'}"
	if $subnet_config->{'dhcp-dns-server'};
}

sub configure_range {
    # noop, everything is done within configure_subnet
}

sub configure_vnet {
    my ($class, $config, $dhcpid, $vnetid, $vnet_config) = @_;

    return if @{$config} < 1;

    push @{$config}, "interface=$vnetid";

    PVE::Tools::file_set_contents(
	"$DNSMASQ_CONFIG_ROOT/$dhcpid/10-$vnetid.conf",
	join("\n", @{$config}) . "\n"
    );
}

sub systemctl_service {
    my ($action, $service) = @_;

    PVE::Tools::run_command(['systemctl', $action, $service]);
}

sub before_configure {
    my ($class, $dhcpid, $zone_cfg) = @_;

    my $dbus_config = <<DBUSCFG;
<!DOCTYPE busconfig PUBLIC
 "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
        <policy user="root">
                <allow own="uk.org.thekelleys.dnsmasq.$dhcpid"/>
                <allow send_destination="uk.org.thekelleys.dnsmasq.$dhcpid"/>
        </policy>
        <policy user="dnsmasq">
                <allow own="uk.org.thekelleys.dnsmasq.$dhcpid"/>
                <allow send_destination="uk.org.thekelleys.dnsmasq.$dhcpid"/>
        </policy>
        <policy context="default">
                <deny own="uk.org.thekelleys.dnsmasq.$dhcpid"/>
                <deny send_destination="uk.org.thekelleys.dnsmasq.$dhcpid"/>
        </policy>
</busconfig>
DBUSCFG

    PVE::Tools::file_set_contents(
	"/etc/dbus-1/system.d/dnsmasq.$dhcpid.conf",
	$dbus_config
    );

    my $config_directory = "$DNSMASQ_CONFIG_ROOT/$dhcpid";

    mkdir($config_directory, 0755) if !-d $config_directory;

    my $default_config = <<CFG;
CONFIG_DIR='$config_directory,\*.conf'
DNSMASQ_OPTS="--conf-file=/dev/null --enable-dbus=uk.org.thekelleys.dnsmasq.$dhcpid"
CFG

    PVE::Tools::file_set_contents(
	"$DNSMASQ_DEFAULT_ROOT/dnsmasq.$dhcpid",
	$default_config
    );

    my $mtu = PVE::Network::SDN::Zones::get_mtu($zone_cfg);

    my $default_dnsmasq_config = <<CFG;
except-interface=lo
enable-ra
quiet-ra
bind-dynamic
no-hosts
dhcp-leasefile=$DNSMASQ_LEASE_ROOT/dnsmasq.$dhcpid.leases
dhcp-hostsfile=$config_directory/ethers
dhcp-ignore=tag:!known

dhcp-option=26,$mtu
ra-param=*,mtu:$mtu,0

# Send an empty WPAD option. This may be REQUIRED to get windows 7 to behave.
dhcp-option=252,"\\n"

# Send microsoft-specific option to tell windows to release the DHCP lease
# when it shuts down. Note the "i" flag, to tell dnsmasq to send the
# value as a four-byte integer - that's what microsoft wants.
dhcp-option=vendor:MSFT,2,1i

# If a DHCP client claims that its name is "wpad", ignore that.
# This fixes a security hole. see CERT Vulnerability VU#598349
dhcp-name-match=set:wpad-ignore,wpad
dhcp-ignore-names=tag:wpad-ignore
CFG

    PVE::Tools::file_set_contents(
	"$config_directory/00-default.conf",
	$default_dnsmasq_config
    );

    my @config_files = ();
    PVE::Tools::dir_glob_foreach($config_directory, '10-.*\.conf', sub {
	my ($file) = @_;
	push @config_files, "$config_directory/$file";
    });

    unlink @config_files;
}

sub after_configure {
    my ($class, $dhcpid, $noerr) = @_;

    return if !assert_dnsmasq_installed($noerr);

    my $service_name = "dnsmasq\@$dhcpid";

    systemctl_service('reload', 'dbus');
    systemctl_service('enable', $service_name);
    systemctl_service('restart', $service_name);
}

sub before_regenerate {
    my ($class, $noerr) = @_;

    return if !assert_dnsmasq_installed($noerr);

    systemctl_service('stop', "dnsmasq@*");
    systemctl_service('disable', 'dnsmasq@');
}

sub after_regenerate {
    my ($class) = @_;
    # noop
}

1;
