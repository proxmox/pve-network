package PVE::Network::SDN::Dhcp::Dnsmasq;

use strict;
use warnings;

use base qw(PVE::Network::SDN::Dhcp::Plugin);

use Net::IP qw(:PROC);
use PVE::Tools qw(file_set_contents run_command lock_file);

use File::Copy;

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

    my $change = undef;
    my $match4 = undef;
    my $match6 = undef;

    my $appendFn = sub {
	open(my $in, '<', $ethers_file) or die "Could not open file '$ethers_file' $!\n";
	open(my $out, '>', $ethers_tmp_file) or die "Could not open file '$ethers_tmp_file' $!\n";

        while (my $line = <$in>) {
	    chomp($line);
	    my ($parsed_mac, $parsed_ip) = split(/,/, $line);
	    #delete removed mac
	    if (!defined($macdb->{macs}->{$parsed_mac})) {
		$change = 1;
		next;
	    }

	    #delete changed ip
	    my $ipversion = Net::IP::ip_is_ipv4($parsed_ip) ? "ip4" : "ip6";
	    if ($macdb->{macs}->{$parsed_mac}->{$ipversion} && $macdb->{macs}->{$parsed_mac}->{$ipversion} ne $parsed_ip) {
		$change = 1;
		next;
	    }
	    print $out "$parsed_mac,$parsed_ip\n";
	    #check if mac/ip already exist
	    $match4 = 1 if $parsed_mac eq $mac && $macdb->{macs}->{$mac}->{'ip4'} && $macdb->{macs}->{$mac}->{'ip4'} eq $ip4;
	    $match6 = 1 if $parsed_mac eq $mac && $macdb->{macs}->{$mac}->{'ip6'} && $macdb->{macs}->{$mac}->{'ip6'} eq $ip6;
	}

	if(!$match4 && $ip4) {
	    print $out "$mac,$ip4\n";
	    $change = 1;
	}

	if(!$match6 && $ip6) {
	    print $out "$mac,$ip6\n";
	    $change = 1;
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
    PVE::Tools::run_command(['systemctl', 'reload', $service_name]) if $change;
}

sub configure_subnet {
    my ($class, $dhcpid, $subnet_config) = @_;

    die "No gateway defined for subnet $subnet_config->{id}"
	if !$subnet_config->{gateway};

    my $tag = $subnet_config->{id};

    my @dnsmasq_config = (
	"listen-address=$subnet_config->{gateway}",
    );

    my $option_string;
    if (ip_is_ipv6($subnet_config->{network})) {
	$option_string = 'option6';
	push @dnsmasq_config, "enable-ra";
    } else {
	$option_string = 'option';
	push @dnsmasq_config, "dhcp-option=tag:$tag,$option_string:router,$subnet_config->{gateway}";
    }

    push @dnsmasq_config, "dhcp-option=tag:$tag,$option_string:dns-server,$subnet_config->{'dhcp-dns-server'}"
	if $subnet_config->{'dhcp-dns-server'};

    PVE::Tools::file_set_contents(
	"$DNSMASQ_CONFIG_ROOT/$dhcpid/10-$subnet_config->{id}.conf",
	join("\n", @dnsmasq_config) . "\n"
    );
}

sub configure_range {
    my ($class, $dhcpid, $subnet_config, $range_config) = @_;

    my $range_file = "$DNSMASQ_CONFIG_ROOT/$dhcpid/10-$subnet_config->{id}.ranges.conf",
    my $tag = $subnet_config->{id};

    open(my $fh, '>>', $range_file) or die "Could not open file '$range_file' $!\n";
    print $fh "dhcp-range=set:$tag,$range_config->{'start-address'},$range_config->{'end-address'}\n";
    close $fh;
}

sub before_configure {
    my ($class, $dhcpid) = @_;

    my $config_directory = "$DNSMASQ_CONFIG_ROOT/$dhcpid";

    mkdir($config_directory, 755) if !-d $config_directory;

    my $default_config = <<CFG;
CONFIG_DIR='$config_directory,\*.conf'
DNSMASQ_OPTS="--conf-file=/dev/null"
CFG

    PVE::Tools::file_set_contents(
	"$DNSMASQ_DEFAULT_ROOT/dnsmasq.$dhcpid",
	$default_config
    );

    my $default_dnsmasq_config = <<CFG;
except-interface=lo
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
