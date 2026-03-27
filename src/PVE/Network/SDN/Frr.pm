package PVE::Network::SDN::Frr;

use strict;
use warnings;

=head1 NAME

C<PVE::Network::SDN::Frr> - Helper module for FRR

=head1 DESCRIPTION

This module contains helpers for handling the various intermediate FRR
configuration formats.

We currently mainly use two different intermediate formats throughout the SDN
module:

=head2 frr config

An frr config represented as a perl hash. The controller plugins generate their
frr configuration in this format. This format is also used for merging the local
FRR config (a user-defined configuration file) with the controller-generated
configuration.

=head2 raw config

This is generated from the frr config. It is an array where every entry is a
string that is a FRR configuration line.

=cut

use PVE::RESTEnvironment qw(log_warn);
use PVE::Tools qw(file_get_contents file_set_contents run_command);

my $FRR_CONF_LOCAL_FILE = "/etc/frr/frr.conf.local";

=head3 local_frr_config_exists

Checks if the `/etc/frr/frr.conf.local` file exists.

=cut

sub local_frr_config_exists {
    return -e $FRR_CONF_LOCAL_FILE;
}

=head3 read_local_frr_config

Returns the contents of `/etc/frr/frr.conf.local` as a string if it exists, otherwise undef.

=cut

sub read_local_frr_config {
    if (local_frr_config_exists()) {
        return file_get_contents($FRR_CONF_LOCAL_FILE);
    }
    return; # undef
}

my $FRR_CONFIG_FILE = "/etc/frr/frr.conf";

=head3 apply()

Tries to reload FRR with the frr-reload.py script from frr-pythontools. If that
isn't installed or doesn't work it falls back to restarting the systemd frr
service. If C<$force_restart> is set, then the FRR daemon will be restarted,
without trying to reload it first.

=cut

sub apply {
    my ($force_restart) = @_;

    if (!-e $FRR_CONFIG_FILE) {
        log_warn("$FRR_CONFIG_FILE is not present.");
        return;
    }

    run_command(['systemctl', 'enable', '--now', 'frr'])
        if !-e "/etc/systemd/system/multi-user.target.wants/frr.service";

    if (!$force_restart) {
        eval { reload() };
        return if !$@;

        log_warn("reloading frr configuration failed: $@");
        warn "trying to restart frr instead";
    }

    eval { restart() };
    warn "restarting frr failed: $@" if $@;
}

sub reload {
    my $bin_path = "/usr/lib/frr/frr-reload.py";

    if (!-e $bin_path) {
        die "missing $bin_path. Please install the frr-pythontools package";
    }

    my $err = sub {
        my $line = shift;
        warn "$line \n";
    };

    run_command([$bin_path, '--stdout', '--reload', $FRR_CONFIG_FILE], errfunc => $err);
}

sub restart {
    # script invoked by the frr systemd service
    my $bin_path = "/usr/lib/frr/frrinit.sh";

    if (!-e $bin_path) {
        die "missing $bin_path. Please install the frr package";
    }

    my $err = sub {
        my $line = shift;
        warn "$line \n";
    };

    run_command(['systemctl', 'restart', 'frr'], errfunc => $err);
}

my $SDN_DAEMONS_DEFAULT = {
    ospfd => 0,
    fabricd => 0,
};

=head3 set_daemon_status(\%daemons, $set_default)

Sets the status of all daemons supplied in C<\%daemons>. This only works for
daemons managed by SDN, as indicated in the C<$SDN_DAEMONS_DEFAULT> constant. If
a daemon is supplied that isn't managed by SDN then this command will fail. If
C<$set_default> is set, then additionally all sdn-managed daemons that are
missing in C<\%daemons> are reset to their default value. It returns whether the
status of any daemons has changed, which indicates that a restart of the daemon
is required, rather than only a reload.

=cut

sub set_daemon_status {
    my ($daemon_status, $set_default) = @_;

    my $daemons_file = "/etc/frr/daemons";
    die "/etc/frr/daemons file does not exist; is the frr package installed?\n"
        if !-e $daemons_file;

    for my $daemon (keys %$daemon_status) {
        die "$daemon is not SDN managed" if !defined $SDN_DAEMONS_DEFAULT->{$daemon};
    }

    if ($set_default) {
        for my $daemon (keys %$SDN_DAEMONS_DEFAULT) {
            $daemon_status->{$daemon} = $SDN_DAEMONS_DEFAULT->{$daemon}
                if !defined($daemon_status->{$daemon});
        }
    }

    my $old_config = PVE::Tools::file_get_contents($daemons_file);
    my $new_config = "";

    my $changed = 0;

    my @lines = split(/\n/, $old_config);

    for my $line (@lines) {
        if ($line =~ m/^([a-z_]+)=/) {
            my $key = $1;
            my $status = $daemon_status->{$key};

            if (defined $status) {
                my $value = $status ? "yes" : "no";
                my $new_line = "$key=$value";

                $changed = 1 if $new_line ne $line;

                $line = $new_line;
            }
        }

        $new_config .= "$line\n";
    }

    PVE::Tools::file_set_contents($daemons_file, $new_config);

    return $changed;
}

=head3 raw_config_to_string(\@raw_config)

Converts a given C<\@raw_config> to a string representing a complete frr
configuration, ready to be written to /etc/frr/frr.conf. If raw_config is empty,
returns only the FRR config skeleton.

=cut

sub raw_config_to_string {
    my ($raw_config) = @_;

    my $nodename = PVE::INotify::nodename();

    my @final_config = (
        "frr version 10.4.1",
        "frr defaults datacenter",
        "hostname $nodename",
        "log syslog informational",
        "service integrated-vtysh-config",
        "!",
    );

    push @final_config, @$raw_config;

    push @final_config, (
        "!", "line vty", "!",
    );

    return join("\n", @final_config) . "\n";
}

=head3 raw_config_to_string(\@raw_config)

Writes a given C<\@raw_config> to /etc/frr/frr.conf.

=cut

sub write_raw_config {
    my ($raw_config) = @_;

    return if !-d "/etc/frr";
    return if !$raw_config;

    file_set_contents("/etc/frr/frr.conf", raw_config_to_string($raw_config));

}

=head3 append_local_config(\%frr_config, $local_config)

Takes an existing C<\%frr_config> and C<$local_config> (as a string). It parses
the local configuration and appends the values to the existing C<\%frr_config>
in-place.

=cut

sub append_local_config {
    my ($frr_config, $local_config) = @_;

    # store the generated and override routemaps here, so that we can write them
    # at the very end. We need to do this because we need to have all the
    # routemaps, to then sort them and set the seq for every routemap correctly.
    my $custom_routemaps = {};

    $local_config = read_local_frr_config() if !$local_config;

    # add already generated frr routemaps (from the evpn controller) to the
    # custom_routemaps map. by adding them here early the generated routemaps
    # are inserted BEFORE the frr.conf.local ones.
    for my $rm (sort keys %{ $frr_config->{'frr'}->{'routemaps'} }) {
        push(@{ $custom_routemaps->{$rm} }, \$frr_config->{'frr'}->{'routemaps'}->{$rm});
    }

    if (!$local_config) {
        # if we exit early because there is no frr.conf.local, we still need to
        # adjust the routemap seqs
        for my $rm (sort keys %{$custom_routemaps}) {
            my $seq = 1;
            my $entry = $custom_routemaps->{$rm};
            for my $rm_line (@{$entry}) {
                for my $rm_obj_entry (@{$$rm_line}) {
                    $rm_obj_entry->{seq} = $seq;
                    $seq++;
                }
            }
        }
        return;
    }

    my $section = \$frr_config->{""};
    my $router = undef;
    my $routemap = undef;
    my $routemap_config = ();
    my $routemap_action = undef;

    while ($local_config =~ /^\s*(.+?)\s*$/gm) {
        my $line = $1;
        $line =~ s/^\s+|\s+$//g;

        if ($line =~ m/^router (.+)$/) {
            $router = $1;
            $section = \$frr_config->{'frr'}->{'router'}->{$router}->{""};
            next;
        } elsif ($line =~ m/^vrf (.+)$/) {
            $section = \$frr_config->{'frr'}->{'vrf'}->{$1};
            next;
        } elsif ($line =~ m/^interface (.+)$/) {
            $section = \$frr_config->{'frr_interfaces'}->{$1};
            next;
        } elsif ($line =~ m/^bgp community-list (.+)$/) {
            push(@{ $frr_config->{'frr_bgp_community_list'} }, $line);
            next;
        } elsif ($line =~ m/address-family (.+)$/) {
            $section = \$frr_config->{'frr'}->{'router'}->{$router}->{'address-family'}->{$1};
            next;
        } elsif ($line =~ m/^route-map (.+) (permit|deny) (\d+)/) {
            $routemap = $1;
            $routemap_config = ();
            $routemap_action = $2;
            $section = \$frr_config->{'frr_routemap'}->{$routemap};
            next;
        } elsif ($line =~ m/^access-list (.+) seq (\d+) (.+)$/) {
            $frr_config->{'frr_access_list'}->{$1}->{$2} = $3;
            next;
        } elsif ($line =~ m/^ip prefix-list (.+) seq (\d+) (.*)$/) {
            $frr_config->{'frr_prefix_list'}->{$1}->{$2} = $3;
            next;
        } elsif ($line =~ m/^ipv6 prefix-list (.+) seq (\d+) (.*)$/) {
            $frr_config->{'frr_prefix_list_v6'}->{$1}->{$2} = $3;
            next;
        } elsif ($line =~ m/^exit-address-family$/) {
            next;
        } elsif ($line =~ m/^exit$/) {
            if ($router) {
                $section = \$frr_config->{''};
                $router = undef;
            } elsif ($routemap) {
                push(@{$$section}, { rule => $routemap_config, action => $routemap_action });
                $section = \$frr_config->{''};
                $routemap = undef;
                $routemap_action = undef;
                $routemap_config = ();
            }
            next;
        } elsif ($line =~ m/!/) {
            next;
        }

        next if !$section;
        if ($routemap) {
            push(@{$routemap_config}, $line);
        } else {
            push(@{$$section}, $line);
        }
    }
}

1;
