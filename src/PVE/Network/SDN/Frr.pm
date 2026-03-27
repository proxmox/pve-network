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

    $frr_config->{'frr'}->{'custom_frr_config'} //= [];
    my $section = \$frr_config->{''};
    my $isis_router_name = undef;
    my $bgp_router_asn = undef;
    my $bgp_router_vrf = undef;
    my $custom_router_name = undef;
    my $routemap = undef;
    my $interface = undef;
    my $vrf = undef;
    my $new_block = 0;
    my $new_af_block = 0;

    while ($local_config =~ /^(.+?)\s*$/gm) {
        my $line = $1;
        $line =~ s/\s+$//g;

        if ($line =~ m/^router isis (.+)$/) {
            $isis_router_name = $1;
            if (defined($frr_config->{'frr'}->{'isis'}->{'router'}->{$isis_router_name})) {
                $section =
                    \($frr_config->{'frr'}->{'isis'}->{'router'}->{$isis_router_name}
                        ->{'custom_frr_config'} //= []);
            } else {
                $new_block = 1;
                push(
                    $frr_config->{'frr'}->{'custom_frr_config'}->@*,
                    "router isis $isis_router_name",
                );
                $section = \$frr_config->{'frr'}->{'custom_frr_config'};
            }
            next;
        } elsif ($line =~ m/^router bgp (\S+)(?: vrf (.+))?$/) {
            $bgp_router_asn = $1;
            $bgp_router_vrf = $2 // 'default';

            if (
                defined($frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf})
                and $frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf}->{'asn'}
                eq $bgp_router_asn
            ) {
                $section =
                    \($frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf}
                        ->{'custom_frr_config'} //= []);
            } else {
                $new_block = 1;

                my $config_line =
                    defined($2)
                    ? "router bgp $bgp_router_asn vrf $bgp_router_vrf"
                    : "router bgp $bgp_router_asn";

                push(
                    $frr_config->{'frr'}->{'custom_frr_config'}->@*, $config_line,
                );
                $section = \$frr_config->{'frr'}->{'custom_frr_config'};
            }
            next;
        } elsif ($line =~ m/^router (.+)$/) {
            $custom_router_name = $1;
            $new_block = 1;
            push(
                $frr_config->{'frr'}->{'custom_frr_config'}->@*, "router $custom_router_name",
            );
            $section = \$frr_config->{'frr'}->{'custom_frr_config'};
            next;
        } elsif ($line =~ m/^vrf (.+)$/) {
            $vrf = $1;
            if (defined($frr_config->{'frr'}->{'bgp'}->{'vrfs'}->{$vrf})) {
                $section = \$frr_config->{'frr'}->{'bgp'}->{'vrfs'}->{$vrf}->{'custom_frr_config'};
            } else {
                $new_block = 1;
                push($frr_config->{'frr'}->{'custom_frr_config'}->@*, "vrf $vrf");
                $section = \$frr_config->{'frr'}->{'custom_frr_config'};
            }
            next;
        } elsif ($line =~ m/^interface (.+)$/) {
            $interface = $1;
            if (defined($frr_config->{'frr'}->{'isis'}->{'interfaces'}->{$interface})) {
                $section = \($frr_config->{'frr'}->{'isis'}->{'interfaces'}->{$interface}
                    ->{'custom_frr_config'} //= []);
            } else {
                $new_block = 1;
                push(
                    $frr_config->{'frr'}->{'custom_frr_config'}->@*, "interface $interface",
                );
                $section = \$frr_config->{'frr'}->{'custom_frr_config'};
            }
            next;
        } elsif ($line =~ m/^bgp community-list (.+)$/) {
            push(@{ $frr_config->{'frr'}->{'custom_frr_config'} }, $line);
            next;
        } elsif ($line =~ m/address-family (.+)$/) {
            # convert the address family from frr (e.g. l2vpn evpn) into the rust property (e.g. l2vpn_evpn)
            my $address_family_unchanged = $1;
            my $address_family = $1 =~ s/ /_/gr;

            if (
                defined($frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf})
                and $frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf}->{'asn'}
                eq $bgp_router_asn
            ) {
                if (defined(
                    $frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf}
                        ->{'address_families'}->{$address_family}
                )) {
                    $section =
                        \($frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf}
                            ->{'address_families'}->{$address_family}->{'custom_frr_config'} //=
                            []);
                } else {
                    $new_af_block = 1;
                    push(
                        $frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf}
                            ->{'custom_frr_config'}->@*,
                        " address-family $address_family_unchanged",
                    );
                    $section = \$frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf}
                        ->{'custom_frr_config'};
                }
            } else {
                $new_af_block = 1;
                push(
                    $frr_config->{'frr'}->{'custom_frr_config'}->@*,
                    " address-family $address_family_unchanged",
                );
                $section = \$frr_config->{'frr'}->{'custom_frr_config'};
            }
            next;
        } elsif ($line =~ m/^route-map (.+) (permit|deny) (\d+)/) {
            $routemap = $1;
            my $routemap_action = $2;
            my $seq_number = $3;
            # NEVER merge the route-maps, we always just add them to the
            # custom_routemaps map so that we can push them at the very end.
            $new_block = 1;
            push(
                $custom_routemaps->{$routemap}->@*,
                "route-map $routemap $routemap_action $seq_number",
            );
            $section = \$custom_routemaps->{$routemap};
            next;
        } elsif ($line =~ m/^access-list (.+) seq (\d+) (.+)$/) {
            push($frr_config->{'frr'}->{'custom_frr_config'}->@*, $line);
            next;
        } elsif ($line =~ m/^ip prefix-list (.+) seq (\d+) (.*)$/) {
            push($frr_config->{'frr'}->{'custom_frr_config'}->@*, $line);
            next;
        } elsif ($line =~ m/^ipv6 prefix-list (.+) seq (\d+) (.*)$/) {
            push($frr_config->{'frr'}->{'custom_frr_config'}->@*, $line);
            next;
        } elsif ($line =~ m/exit-address-family$/) {
            if ($new_af_block) {
                push(@{$$section}, $line);
                $section = \$frr_config->{'frr'}->{'custom_frr_config'};
            } else {
                $section =
                    \($frr_config->{'frr'}->{'bgp'}->{'vrf_router'}->{$bgp_router_vrf}
                        ->{'custom_frr_config'} //= []);
            }
            $new_af_block = 0;
            next;
        } elsif ($line =~ m/^exit/) {
            # this means we just added a new router/vrf/interface/routemap
            if ($new_block) {
                push(@{$$section}, $line);
                push(@{$$section}, "!");
            }
            $section = \$frr_config->{''};
            # we can't stack these, so exit out of all of them (technically we can have a vrf inside of a router bgp block, but we don't support that)
            $isis_router_name = undef;
            $bgp_router_vrf = undef;
            $bgp_router_asn = undef;
            $custom_router_name = undef;
            $vrf = undef;
            $interface = undef;
            $routemap = undef;
            $new_block = 0;
            next;
        } elsif ($line =~ m/!/) {
            next;
        }

        next if !$section;
        push(@{$$section}, $line);
    }

    # go through custom_routemaps, which holds generated and override routemaps.
    # We need to sort by name and then give each rule in the route-map name a
    # ascending seq number. If we have a routemap generated by the perl code, we
    # get an object and need to change the seq property (this is rendered using
    # the templates). If we have a override route-map (from frr.conf.local), then
    # we just get the strings of the lines and we need to parse it again and write
    # with the correct seq.
    for my $rm (sort keys %{$custom_routemaps}) {
        my $seq = 1;
        my $entry = $custom_routemaps->{$rm};
        for my $rm_line (@{$entry}) {
            if (!ref($rm_line)) {
                if ($rm_line =~ m/^route-map (.+) (permit|deny) (\d+)/) {
                    my $name = $1;
                    my $action = $2;
                    push(
                        $frr_config->{'frr'}->{'custom_frr_config'}->@*,
                        "route-map $name $action $seq",
                    );
                    $seq++;
                } else {
                    push($frr_config->{'frr'}->{'custom_frr_config'}->@*, $rm_line);
                }
            } else {
                for my $rm_obj_entry (@{$$rm_line}) {
                    $rm_obj_entry->{seq} = $seq;
                    $seq++;
                }
            }
        }
    }
}

1;
