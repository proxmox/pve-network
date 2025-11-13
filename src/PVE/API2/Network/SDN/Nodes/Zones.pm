package PVE::API2::Network::SDN::Nodes::Zones;

use PVE::API2::Network::SDN::Nodes::Zone;
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Network::SDN;
use PVE::RPCEnvironment;

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::Network::SDN::Nodes::Zone",
    path => '{zone}',
});

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Get status for all zones.",
    permissions => {
        description => "Only list entries where you have 'SDN.Audit'",
        user => 'all',
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                zone => get_standard_option('pve-sdn-zone-id'),
                status => {
                    description => "Status of zone",
                    type => 'string',
                    enum => ['available', 'pending', 'error'],
                },
            },
        },
        links => [{ rel => 'child', href => "{zone}" }],
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();

        my $localnode = PVE::INotify::nodename();

        my $res = [];

        my ($zone_status, $vnet_status) = PVE::Network::SDN::Zones::status();

        foreach my $id (sort keys %{$zone_status}) {
            my $item->{zone} = $id;
            $item->{status} = $zone_status->{$id}->{'status'};
            push @$res, $item;
        }

        return $res;
    },
});

1;
