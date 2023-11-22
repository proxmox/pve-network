package PVE::Network::SDN::Dhcp::Dnsmasq;

use strict;
use warnings;

use base qw(PVE::Network::SDN::Dhcp::Plugin);

use Net::IP qw(:PROC);
use PVE::Tools qw(file_set_contents run_command lock_file);

use File::Copy;
use Net::DBus;

my $DNSMASQ_CONFIG_ROOT = '/etc/dnsmasq.d';
my $DNSMASQ_DEFAULT_ROOT = '/etc/default';
my $DNSMASQ_LEASE_ROOT = '/var/lib/misc';

sub type {
    return 'dnsmasq';
}

sub add_ip_mapping {
    my ($class, $dhcpid, $macdb, $mac, $ip4, $ip6) = @_;

    my $ethers_file = "$DNSMASQ_CONFIG_ROOT/$dhcpid/ethers";
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
    PVE::Tools::run_command(['systemctl', 'reload', $service_name]) if $reload;

    #update lease as ip could still be associated to an old removed mac
    my $bus = Net::DBus->system();
    my $dnsmasq = $bus->get_service("uk.org.thekelleys.dnsmasq.$dhcpid");
    my $manager = $dnsmasq->get_object("/uk/org/thekelleys/dnsmasq","uk.org.thekelleys.dnsmasq.$dhcpid");

    my @hostname = unpack("C*", "*");
    $manager->AddDhcpLease($ip4, $mac, \@hostname, undef, 0, 0, 0) if $ip4;
#    $manager->AddDhcpLease($ip6, $mac, \@hostname, undef, 0, 0, 0) if $ip6;

}

sub configure_subnet {
    my ($class, $config, $dhcpid, $vnetid, $subnet_config) = @_;

    die "No gateway defined for subnet $subnet_config->{id}"
	if !$subnet_config->{gateway};

    my $tag = $subnet_config->{id};

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
    my ($class, $config, $dhcpid, $vnetid, $subnet_config, $range_config) = @_;

    my $tag = $subnet_config->{id};

    my ($zone, $network, $mask) = split(/-/, $tag);

    if (Net::IP::ip_is_ipv4($network)) {
	$mask = (2 ** $mask - 1) << (32 - $mask);
	$mask = join( '.', unpack( "C4", pack( "N", $mask ) ) );
    }

    push @{$config}, "dhcp-range=set:$tag,$network,static,$mask,infinite";
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

sub before_configure {
    my ($class, $dhcpid) = @_;

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

    my $default_dnsmasq_config = <<CFG;
except-interface=lo
enable-ra
quiet-ra
bind-dynamic
no-resolv
no-hosts
dhcp-leasefile=$DNSMASQ_LEASE_ROOT/dnsmasq.$dhcpid.leases
dhcp-hostsfile=$config_directory/ethers
dhcp-ignore=tag:!known

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

    unlink glob "$config_directory/10-*.conf";
}

sub after_configure {
    my ($class, $dhcpid) = @_;

    my $service_name = "dnsmasq\@$dhcpid";

    PVE::Tools::run_command(['systemctl', 'reload', 'dbus']);
    PVE::Tools::run_command(['systemctl', 'enable', $service_name]);
    PVE::Tools::run_command(['systemctl', 'restart', $service_name]);
}

sub before_regenerate {
    my ($class) = @_;

    PVE::Tools::run_command(['systemctl', 'stop', "dnsmasq@*"]);
    PVE::Tools::run_command(['systemctl', 'disable', 'dnsmasq@']);
}

sub after_regenerate {
    my ($class) = @_;
    # noop
}

1;
