#!/usr/bin/perl

# cron script for pulling down aws virtual interface addresses

use strict;
use warnings;

use Data::Dumper;
use JSON;
use Log::Log4perl;
use Paws;
use XML::Simple;
use GRNOC::WebService::Client;

#use MooseX::Storage;
#    with Storage('format' => 'JSON');
    #with Storage('format' => 'JSON', 'io' => 'File');


my $self;
my $client;
my $jsonObj = JSON->new->allow_nonref->convert_blessed->allow_blessed;


sub new {
    #my $class = shift;
    $self  = {
        config => '/etc/oess/database.xml',
        logger => Log::Log4perl->get_logger('OESS.Cloud.AWS'),
        @_
    };
    #bless $self, $class;
    my $creds = XML::Simple::XMLin($self->{config});
    $self->{creds} = $creds;
    #warn "config " . Dumper $self->{creds};
    #warn "url " .  Dumper $creds->{'wsc'}->{'url'};
    $client = GRNOC::WebService::Client->new(
        url     => $self->{creds}->{'wsc'}->{'url'} . "/vrf.cgi",
        uid     => $self->{creds}->{'wsc'}->{'username'},
        passwd  => $self->{creds}->{'wsc'}->{'password'},
        verify_hostname => 0,
        #usePost => 1,
        debug   => 1
    ) or die "Cannot connect to webservice";
    #warn "client after creating " . Dumper $client;
}

new();

# Get VRFs from OESS db
my $workgroup_id = 3; # TODO: make this configurable

my $oess_res;
if ( defined $client ) {
    $oess_res = $client->get_vrfs( workgroup_id => $workgroup_id );
    warn "oess_res: " . Dumper $oess_res;
#my $data = $oess_res->data();
    #warn "data " . Dumper $data;
} else {
    warn "client not defined";
}


$self->{connections} = {};

my %aws_matches = ();

foreach my $conn (@{$self->{creds}->{cloud}->{connection}}) {
    $self->{connections}->{$conn->{interconnect_id}} = $conn;
}

#warn "self-connections " . Dumper $self->{connections};
#warn "self-creds " . Dumper $self->{creds};

my $dc = Paws->service(
    'DirectConnect',
    region => "us-east-1"
);

# DescribeVirtualInterfaces

my $aws_res = $dc->DescribeVirtualInterfaces();
#$aws_res->{'VirtualInterfaces'} =  [ map { $_->delete_custom_field('CustomerRouterConfig') } @{$aws_res->{'VirtualInterfaces'}} ];

#warn "aws_res " . Dumper $aws_res;

#die;

my $vrf_id_filter = 609;

my $oess_updates = [];
foreach my $vrf (@$oess_res) {
    #warn "vrf " . Dumper $vrf;
    foreach my $endpoint ( @{$vrf->{'endpoints'}} ) {
        next if ( not defined( $endpoint->{'cloud_connection_id'} ) );
        next if ( defined ( $vrf_id_filter ) && $vrf_id_filter != $endpoint->{'tag'} );
        #warn "endpoint " . Dumper $endpoint;
        #my $interconnect_id = $endpoint->{'interface'}->{'cloud_interconnect_id'};
        my $connection_id = $endpoint->{'cloud_connection_id'};
        my $vlan_id = $endpoint->{'tag'};
        #my $vlan_id = $endpoint->{'cloud_connection_id'};
        warn "VLAN_ID " . Dumper $vlan_id;
        warn "NUMBER OF PEERS " . @{$endpoint->{'peers'}};
        my $aws_vrfs = get_vrf_aws_details( $connection_id, $vlan_id );
        update_endpoint_values( $endpoint, $aws_vrfs );
        push @$oess_updates, $vrf;
    }
}

warn "OESS_UPDATES " . Dumper $oess_updates;

my $update_requests = reformat( $oess_updates );

sub reformat {
    my ( $updates ) = @_;

    my @top_level_fields = ( 'local_asn', 'prefix_limit', 'name', 'vrf_id', 'description' );


    my $update = {};
    foreach my $row (@$updates) {
        $update->{'workgroup_id'} = $workgroup_id;
        $update->{'endpoint'} = $jsonObj->encode( $row->{'endpoints'} );
        foreach my $field( @top_level_fields ) {
            $update->{ $field } = $row->{ $field };
        }

    }

    warn "UPDATE " . Dumper $update;

    return $update;



}

sub update_endpoint_values {
    my ( $endpoint, $aws_vrfs ) = @_;
    return if ( not (defined $aws_vrfs) || @$aws_vrfs == 0);

    foreach my $aws (@$aws_vrfs ) {
        warn "updating aws " . $aws->VirtualInterfaceId;
        #warn "aws values " . Dumper $aws;
        $endpoint->{'interface'}->{'cloud_interconnect_id'} = $aws->ConnectionId if  $aws->ConnectionId;
        $endpoint->{'cloud_account_id'} = $aws->OwnerAccount if $aws->OwnerAccount;
        # TODO: handle more than one set of peers. currently we assume one
        my $peer = $endpoint->{'peers'}->[0];
        warn "PEER " . Dumper $peer;
        $peer->{'peer_ip'} = $aws->AmazonAddress if $aws->AmazonAddress;
        $peer->{'peer_asn'} = $aws->AmazonSideAsn if $aws->AmazonSideAsn;
        $peer->{'md5_key'} = $aws->AuthKey if $aws->AuthKey;
        $peer->{'local_ip'} = $aws->CustomerAddress if $aws->CustomerAddress;
        warn "PEER AFTER CHANGES " . Dumper $peer;
        $endpoint->{'peers'}->[0] = $peer;


    }

    warn "ENDPOINT AFTER UPDATES vlan " . $endpoint->{'tag'} . "!!\n"  . Dumper $endpoint;
}

# Updates a value, but only if the new value is defined
# Assumes that $old is a scalar, but ...
# if $key is provided then $old->{ $key } is used for the old value

sub _update_value {
    my ( $old, $new, $key ) = @_;
    # by default, return the "old" (existing) value
    my $ret = $old;

    if ( defined $new ) {
        if ( $key ) {
            my $oldval = $old->{ $key };
        }
        $ret = $new;
    }
    return $ret;
}

warn "aws_matches " . Dumper \%aws_matches;

die;

#get_vrf_aws_details( "dxcon-fgm77851", "" );

sub get_vrf_aws_details { 
    my ( $cloud_connection_id, $vlan_id ) = @_;

    #warn "aws_res: $aws_res";
    
    #my @ret = grep { $_->ConnectionId eq $cloud_interconnect_id } @{$aws_res->{'VirtualInterfaces'}};
    #warn "RET \n" . Dumper @ret;
    
    my @aws_details = (); 

    foreach my $aws (@{$aws_res->{'VirtualInterfaces'}}) {

        if ( $aws->VirtualInterfaceId ne $cloud_connection_id ) {
            next;
        }
        # key off cloud_connection_id
        warn "INTF ConnectionId matches $cloud_connection_id on vlan " . $vlan_id;
        my $key = $cloud_connection_id . "_" . $vlan_id;
        $aws_matches{$key} = 0 if ( not defined ( $aws_matches{ $key } ) );
        $aws_matches{$key}++;
        push @aws_details, $aws;
    }


    warn "AWS_DETAILS " . @aws_details;
    #warn "AWS_DETAILS " . Dumper @aws_details;

    return \@aws_details;

}

sub output_aws_details {
    my ( $details ) = @_;
    my @fields_to_ignore = ( 'CustomerRouterConfig' );
    foreach my $row (@$details) {
        while ( my ($k, $v ) = each %$row ) {


        }


    }

}

my $virtual_interfaces = $aws_res->{'VirtualInterfaces'};
warn "interfaces \n";
#my $json = $aws_res->freeze();
#warn $json->encode( $virtual_interfaces );

warn "aws aws_res " . Dumper ( $aws_res );

for my $intf ( @$virtual_interfaces ) {
    my $bgp_peers = $intf->BgpPeers;
    #warn "bgp peers " . Dumper @{ $interface->BgpPeers }[0]->AddressFamily;

    my @fields = (
        'Vlan', 
        'VirtualInterfaceState', 
        'ConnectionId',
        'AmazonAddress',
        'Asn',
        'OwnerAccount',
        'CustomerAddress',
        'Location',
        'AmazonSideAsn',
        'DirectConnectGatewayId',
        'VirtualInterfaceType',
        'VirtualInterfaceName',
        'VirtualInterfaceId',
        'AddressFamily',
        #'AuthKey',
        'VirtualGatewayId',

    );

    my $results = {};
    for my $field ( @fields ) {
        $results->{$field} = $intf->{$field};

    }
    warn "RESULTS\n" . Dumper $results;



}


