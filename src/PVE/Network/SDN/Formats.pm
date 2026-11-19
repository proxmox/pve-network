package PVE::Network::SDN::Formats;

# JSON schema formats shared by SDN modules. This module must not use other SDN
# modules, so that it can be loaded by all of them without circular imports.

use strict;
use warnings;

use PVE::JSONSchema;
use PVE::Tools;

PVE::JSONSchema::register_format('FullRangeCIDRv6', \&pve_verify_fullrangecidrv6);

sub pve_verify_fullrangecidrv6 {
    my ($cidr, $noerr) = @_;

    if ($cidr =~ m!^(?:$PVE::Tools::IPV6RE)(?:/(\d+))\z! && ($1 >= 0) && ($1 <= 128)) {
        return $cidr;
    }

    return undef if $noerr;
    die "value does not look like a valid IPv6 CIDR network\n";
}

PVE::JSONSchema::register_format('FullRangeCIDRv4', \&pve_verify_fullrangecidrv4);

sub pve_verify_fullrangecidrv4 {
    my ($cidr, $noerr) = @_;

    if ($cidr =~ m!^(?:$PVE::Tools::IPV4RE)(?:/(\d+))\z! && ($1 >= 0) && ($1 <= 32)) {
        return $cidr;
    }

    return undef if $noerr;
    die "value does not look like a valid IPv4 CIDR network\n";
}

PVE::JSONSchema::register_format('FullRangeCIDR', \&pve_verify_fullrangecidr);

sub pve_verify_fullrangecidr {
    my ($cidr, $noerr) = @_;

    if (!(pve_verify_fullrangecidrv4($cidr, 1) || pve_verify_fullrangecidrv6($cidr, 1))) {
        return undef if $noerr;
        die "value does not look like a valid CIDR network\n";
    }

    return $cidr;
}

1;
