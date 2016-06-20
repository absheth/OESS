#!/usr/bin/perl

use strict;
use warnings;

package OESS::MPLS::Device::Juniper::MX;

use Template;
use Net::Netconf::Manager;
use Data::Dumper;

use constant FWDCTL_WAITING     => 2;
use constant FWDCTL_SUCCESS     => 1;
use constant FWDCTL_FAILURE     => 0;
use constant FWDCTL_UNKNOWN     => 3;

use GRNOC::Config;

use base "OESS::MPLS::Device";

sub new{
    my $class = shift;
    my %args = (
        @_
	);
    
    my $self = \%args;

    $self->{'logger'} = Log::Log4perl->get_logger('OESS.MPLS.Device.Juniper.MX.' . $self->{'mgmt_addr'});
    $self->{'logger'}->debug("MPLS Juniper Switch Created!");
    bless $self, $class;

    #TODO: make this automatically figure out the right REV
    $self->{'template_dir'} = "juniper/13.3R8";

    $self->{'tt'} = Template->new(INCLUDE_PATH => "/usr/share/doc/perl-OESS-1.2.0/share/mpls/templates/") or die "Unable to create Template Toolkit!";

    return $self;

}

sub disconnect{
    my $self = shift;

    $self->{'jnx'}->disconnect();
    $self->{'connected'} = 0;
    return;
}

sub get_system_information{
    my $self = shift;

    my $reply = $self->{'jnx'}->get_system_information();

    if($self->{'jnx'}->has_error){
        $self->{'logger'}->error("Error fetching interface information: " . Data::Dumper::Dumper($self->{'jnx'}->get_first_error()));
        return;
    }

    my $system_info = $self->{'jnx'}->get_dom();
    my $xp = XML::LibXML::XPathContext->new( $system_info);
    $xp->registerNs('x',$system_info->documentElement->namespaceURI);
    
    my $model = $xp->findvalue('/x:rpc-reply/x:system-information/x:hardware-model');
    my $version = $xp->findvalue('/x:rpc-reply/x:system-information/x:os-version');
    my $host_name = $xp->findvalue('/x:rpc-reply/x:system-information/x:host-name');
            
    return {model => $model, version => $version, vendor => 'Juniper', host_name => $host_name};
}

sub get_interfaces{
    my $self = shift;

    my $reply = $self->{'jnx'}->get_interface_information();

    if($self->{'jnx'}->has_error){
	$self->set_error($self->{'jnx'}->get_first_error());
        $self->{'logger'}->error("Error fetching interface information: " . Data::Dumper::Dumper($self->{'jnx'}->get_first_error()));
        return;
    }

    my @interfaces;

    my $interfaces = $self->{'jnx'}->get_dom();
    my $xp = XML::LibXML::XPathContext->new( $interfaces);
    $xp->registerNs('x',$interfaces->documentElement->namespaceURI);
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-interface");
    my $ints = $xp->findnodes('/x:rpc-reply/j:interface-information/j:physical-interface');

    foreach my $int ($ints->get_nodelist){
	push(@interfaces, _process_interface($int));
    }

    return \@interfaces;
}

sub _process_interface{
    my $int = shift;
    
    my $obj = {};

    my $xp = XML::LibXML::XPathContext->new( $int );
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-interface");
    $obj->{'name'} = trim($xp->findvalue('./j:name'));
    $obj->{'admin_state'} = trim($xp->findvalue('./j:admin-status'));
    $obj->{'operational_state'} = trim($xp->findvalue('./j:oper-status'));
    $obj->{'description'} = trim($xp->findvalue('./j:description'));
    if(!defined($obj->{'description'}) || $obj->{'description'} eq ''){
	$obj->{'description'} = $obj->{'name'};
    } 

    return $obj;

}

sub remove_vlan{
    my $self = shift;
    my $ckt = shift;

    my $vars = {};
    $vars->{'circuit_name'} = $ckt->{'circuit_name'};
    $vars->{'interface'} = {};
    $vars->{'interface'}->{'name'} = $ckt->{'interface'};
    $vars->{'vlan_tag'} = $ckt->{'vlan_tag'};
    $vars->{'primary_path'} = $ckt->{'primary_path'};
    $vars->{'backup_path'} = $ckt->{'backup_path'};
    $vars->{'circuit_id'} = $ckt->{'circuit_id'};
    $vars->{'switch'} = {name => $self->{'name'}};
    $vars->{'site_id'} = $self->{'node_id'};

    my $output;
    my $remove_template = $self->{'tt'}->process( $self->{'template_dir'} . "/ep_config_delete.xml", $vars, \$output) or warn $self->{'tt'}->error();

    return $self->_edit_config( config => $output );
}

sub add_vlan{
    my $self = shift;
    my $ckt = shift;
    
    $self->{'logger'}->error("Adding circuit: " . Data::Dumper::Dumper($ckt));

    my $vars = {};
    $vars->{'circuit_name'} = $ckt->{'circuit_name'};
    $vars->{'interface'} = {};
    $vars->{'interface'}->{'name'} = $ckt->{'interface'};
    $vars->{'vlan_tag'} = $ckt->{'vlan_tag'};
    $vars->{'primary_path'} = $ckt->{'primary_path'};
    $vars->{'backup_path'} = $ckt->{'backup_path'};
    $vars->{'destination_ip'} = $ckt->{'destination_ip'};
    $vars->{'circuit_id'} = $ckt->{'circuit_id'};
    $vars->{'switch'} = {name => $self->{'name'}};
    $vars->{'site_id'} = $self->{'node_id'};
    
    my $output;
    my $remove_template = $self->{'tt'}->process( $self->{'template_dir'} . "/ep_config.xml", $vars, \$output) or warn $self->{'tt'}->error();
    
    return $self->_edit_config( config => $output );    
    
}

sub connect{
    my $self = shift;
    
    if($self->connected()){
	$self->{'logger'}->error("Already connected to device");
	return;
    }
    $self->{'logger'}->info("Connecting to device!");
    my $jnx = new Net::Netconf::Manager( 'access' => 'ssh',
					 'login' => $self->{'username'},
					 'password' => $self->{'password'},
					 'hostname' => $self->{'mgmt_addr'},
					 'port' => 22 );
    if(!$jnx){
	$self->{'connected'} = 0;
    }else{
	$self->{'logger'}->info("Connected!");
	$self->{'jnx'} = $jnx;
	$self->{'connected'} = 1;
    }


}

sub connected{
    my $self = shift;
    return $self->{'connected'};
}

sub get_isis_adjacencies{
    my $self = shift;

    if(!defined($self->{'jnx'}->{'methods'}->{'get_isis_adjacency_information'})){
	my $TOGGLE = bless { 1 => 1 }, 'TOGGLE';
	$self->{'jnx'}->{'methods'}->{'get_isis_adjacency_information'} = { detail => $TOGGLE};
    }

    $self->{'jnx'}->get_isis_adjacency_information( detail => 1 );

    my $xml = $self->{'jnx'}->get_dom();
    #warn Dumper($xml->toString());
    my $xp = XML::LibXML::XPathContext->new( $xml);
    $xp->registerNs('x',$xml->documentElement->namespaceURI);
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-routing");

    my $adjacencies = $xp->find('/x:rpc-reply/j:isis-adjacency-information/j:isis-adjacency');
    
    my @adj;
    foreach my $adjacency (@$adjacencies){
	push(@adj, _process_isis_adj($adjacency));
    }

    return \@adj;
}

sub _process_isis_adj{
    my $adj = shift;

    my $obj = {};

    my $xp = XML::LibXML::XPathContext->new( $adj );
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-routing");
    $obj->{'interface_name'} = trim($xp->findvalue('./j:interface-name'));
    $obj->{'operational_state'} = trim($xp->findvalue('./j:adjacency-state'));
    $obj->{'remote_system_name'} = trim($xp->findvalue('./j:system-name'));
    $obj->{'ip_address'} = trim($xp->findvalue('./j:ip-address'));
    $obj->{'ipv6_address'} = trim($xp->findvalue('./j:ipv6-address'));

    return $obj;
}

sub get_LSPs{
    my $self = shift;

    if(!defined($self->{'jnx'}->{'methods'}->{'get_mpls_lsp_information'})){
        my $TOGGLE = bless { 1 => 1 }, 'TOGGLE';
        $self->{'jnx'}->{'methods'}->{'get_mpls_lsp_information'} = { detail => $TOGGLE};
    }

    $self->{'jnx'}->get_mpls_lsp_information( detail => 1);
    my $xml = $self->{'jnx'}->get_dom();
    warn Dumper($xml->toString());
    my $xp = XML::LibXML::XPathContext->new( $xml);
    $xp->registerNs('x',$xml->documentElement->namespaceURI);
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-routing");
    my $rsvp_session_data = $xp->find('/x:rpc-reply/j:mpls-lsp-information/j:rsvp-session-data');
    
    my @LSPs;

    foreach my $rsvp_sd (@{$rsvp_session_data}){
	push(@LSPs,_process_rsvp_session_data($rsvp_sd));
    }

    return \@LSPs;
}

sub _process_rsvp_session_data{
    my $rsvp_sd = shift;
    
    my $obj = {};

    my $xp = XML::LibXML::XPathContext->new( $rsvp_sd);
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-routing");
    $obj->{'session_type'} = trim($xp->findvalue('./j:session-type'));
    $obj->{'count'} = trim($xp->findvalue('./j:count'));
    $obj->{'sessions'} = ();

    my $rsvp_sessions = $xp->find('./j:rsvp-session');

    if($obj->{'session_type'} eq 'Ingress'){
	
	foreach my $session (@{$rsvp_sessions}){
	    push(@{$obj->{'sessions'}}, _process_rsvp_session_ingress($session));
	}
	
    }elsif($obj->{'session_type'} eq 'Egress'){

	foreach my $session (@{$rsvp_sessions}){
            push(@{$obj->{'sessions'}}, _process_rsvp_session_egress($session));
        }

    }else{
	
	foreach my $session (@{$rsvp_sessions}){
            push(@{$obj->{'sessions'}}, _process_rsvp_session_transit($session));
        }

    }
    return $obj;

}

sub _process_rsvp_session_transit{
    my $session = shift;

    my $obj = {};

    my $xp = XML::LibXML::XPathContext->new( $session );
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-routing");
    $obj->{'name'} = trim($xp->findvalue('./j:name'));
    $obj->{'route-count'} = trim($xp->findvalue('./j:route-count'));
    $obj->{'description'} = trim($xp->findvalue('./j:description'));
    $obj->{'destination-address'} = trim($xp->findvalue('./j:destination-address'));
    $obj->{'source-address'} = trim($xp->findvalue('./j:source-address'));
    $obj->{'lsp-state'} = trim($xp->findvalue('./j:lsp-state'));
    $obj->{'lsp-path-type'} = trim($xp->findvalue('./j:lsp-path-type'));
    $obj->{'suggested-lable-in'} = trim($xp->findvalue('./j:suggested-label-in'));
    $obj->{'suggested-label-out'} = trim($xp->findvalue('./j:suggested-label-out'));
    $obj->{'recovery-label-in'} = trim($xp->findvalue('./j:recovery-label-in'));
    $obj->{'recovery-label-out'} = trim($xp->findvalue('./j:recovery-label-out'));
    $obj->{'rsb-count'} = trim($xp->findvalue('./j:rsb-count'));
    $obj->{'resv-style'} = trim($xp->findvalue('./j:resv-style'));
    $obj->{'label-in'} = trim($xp->findvalue('./j:label-in'));
    $obj->{'label-out'} = trim($xp->findvalue('./j:label-out'));
    $obj->{'psb-lifetime'} = trim($xp->findvalue('./j:psb-lifetime'));
    $obj->{'psb-creation-time'} = trim($xp->findvalue('./j:psb-creation-time'));
    $obj->{'lsp-id'} = trim($xp->findvalue('./j:lsp-id'));
    $obj->{'tunnel-id'} = trim($xp->findvalue('./j:tunnel-id'));
    $obj->{'proto-id'} = trim($xp->findvalue('./j:proto-id'));
    $obj->{'adspec'} = trim($xp->findvalue('./j:adspec'));

    my $pkt_infos = $xp->find('./j:packet-information');
    $obj->{'packet-information'} = ();
    foreach my $pkt_info (@$pkt_infos){
	push(@{$obj->{'packet-information'}}, _process_packet_info($pkt_info));
    }


    my $record_routes = trim($xp->find('./j:record-route/j:address'));
    $obj->{'record-route'} = ();
    foreach my $rr (@$record_routes){
	push(@{$obj->{'record-route'}}, $rr->textContent);
    }


    return $obj;
}

sub _process_packet_info{
    my $pkt_info = shift;
    my $obj = {};

    my $xp = XML::LibXML::XPathContext->new( $pkt_info );
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-routing");

    my $prev_hops = $xp->find('./j:previous-hop');
    if($prev_hops->size() > 0){
	$obj->{'previous-hop'} = ();
	foreach my $pre_hop (@$prev_hops){
	    push(@{$obj->{'previous-hop'}}, $pre_hop->textContent);
	}
    }

    my $next_hops = $xp->find('./j:next-hop');
    if($next_hops->size() > 0){
        $obj->{'next-hop'} = ();
        foreach my $next_hop (@$next_hops){
            push(@{$obj->{'next-hop'}}, $next_hop->textContent);
        }
    }

    my $interfaces = $xp->find('./j:interface-name');
    if($interfaces->size() > 0){
        $obj->{'interface-name'} = ();
        foreach my $int (@$interfaces){
            push(@{$obj->{'interface-name'}}, $int->textContent);
        }
    }


    return $obj;
}

sub _process_rsvp_session_egress{
    my $session = shift;

    my $obj = {};

    my $xp = XML::LibXML::XPathContext->new( $session );
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-routing");
    $obj->{'name'} = trim($xp->findvalue('./j:name'));
    $obj->{'route-count'} = trim($xp->findvalue('./j:route-count'));
    $obj->{'description'} = trim($xp->findvalue('./j:description'));
    $obj->{'destination-address'} = trim($xp->findvalue('./j:destination-address'));
    $obj->{'source-address'} = trim($xp->findvalue('./j:source-address'));
    $obj->{'lsp-state'} = trim($xp->findvalue('./j:lsp-state'));
    $obj->{'lsp-path-type'} = trim($xp->findvalue('./j:lsp-path-type'));
    $obj->{'suggested-lable-in'} = trim($xp->findvalue('./j:suggested-label-in'));
    $obj->{'suggested-label-out'} = trim($xp->findvalue('./j:suggested-label-out'));
    $obj->{'recovery-label-in'} = trim($xp->findvalue('./j:recovery-label-in'));
    $obj->{'recovery-label-out'} = trim($xp->findvalue('./j:recovery-label-out'));
    $obj->{'rsb-count'} = trim($xp->findvalue('./j:rsb-count'));
    $obj->{'resv-style'} = trim($xp->findvalue('./j:resv-style'));
    $obj->{'label-in'} = trim($xp->findvalue('./j:label-in'));
    $obj->{'label-out'} = trim($xp->findvalue('./j:label-out'));
    $obj->{'psb-lifetime'} = trim($xp->findvalue('./j:psb-lifetime'));
    $obj->{'psb-creation-time'} = trim($xp->findvalue('./j:psb-creation-time'));
    $obj->{'lsp-id'} = trim($xp->findvalue('./j:lsp-id'));
    $obj->{'tunnel-id'} = trim($xp->findvalue('./j:tunnel-id'));
    $obj->{'proto-id'} = trim($xp->findvalue('./j:proto-id'));
    $obj->{'adspec'} = trim($xp->findvalue('./j:adspec'));

    my $pkt_infos = $xp->find('./j:packet-information');
    $obj->{'packet-information'} = ();
    foreach my $pkt_info (@$pkt_infos){
        push(@{$obj->{'packet-information'}}, _process_packet_info($pkt_info));
    }

    my $record_routes = trim($xp->find('./j:record-route/j:address'));
    $obj->{'record-route'} = ();
    foreach my $rr (@$record_routes){
        push(@{$obj->{'record-route'}}, $rr->textContent);
    }    

    
    
    return $obj;
}


sub _process_rsvp_session_ingress{
    my $session = shift;
    
    my $obj = {};

    my $xp = XML::LibXML::XPathContext->new( $session );
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-routing");
    $obj->{'name'} = trim($xp->findvalue('./j:mpls-lsp/j:name'));
    $obj->{'description'} = trim($xp->findvalue('./j:mpls-lsp/j:description'));
    $obj->{'destination-address'} = trim($xp->findvalue('./j:mpls-lsp/j:destination-address'));
    $obj->{'source-address'} = trim($xp->findvalue('./j:mpls-lsp/j:source-address'));
    $obj->{'lsp-state'} = trim($xp->findvalue('./j:mpls-lsp/j:lsp-state'));
    $obj->{'route-count'} = trim($xp->findvalue('./j:mpls-lsp/j:route-count'));
    $obj->{'active-path'} = trim($xp->findvalue('./j:mpls-lsp/j:active-path'));
    $obj->{'lsp-type'} = trim($xp->findvalue('./j:mpls-lsp/j:lsp-type'));
    $obj->{'egress-label-operation'} = trim($xp->findvalue('./j:mpls-lsp/j:egress-label-operation'));
    $obj->{'load-balance'} = trim($xp->findvalue('./j:mpls-lsp/j:load-balance'));
    $obj->{'attributes'} = { 'encoding-type' => trim($xp->findvalue('./j:mpls-lsp/j:mpls-lsp-attributes/j:encoding-type')),
			     'switching-type' => trim($xp->findvalue('./mpls-lsp/j:mpls-lsp-attributes/j:switching-type')),
			     'gpid' => trim($xp->findvalue('./mpls-lsp/j:mpls-lsp-attributes/j:gpid'))},
    $obj->{'revert-timer'} = trim($xp->findvalue('./j:mpls-lsp/j:revert-timer'));
    
    $obj->{'paths'} = ();

    my $paths = $xp->find('./j:mpls-lsp/j:mpls-lsp-path');
    
    foreach my $path (@$paths){
	push(@{$obj->{'paths'}}, _process_lsp_path($path));
    }

    return $obj;
}

sub _process_lsp_path{
    my $path = shift;

    my $xp = XML::LibXML::XPathContext->new( $path );
    $xp->registerNs('j',"http://xml.juniper.net/junos/13.3R1/junos-routing");
    
    my $obj = {};

    $obj->{'name'} = trim($xp->findvalue('./j:name'));
    $obj->{'title'} = trim($xp->findvalue('./j:title'));
    $obj->{'path-state'} = trim($xp->findvalue('./j:path-state'));
    $obj->{'path-active'} = trim($xp->findvalue('./j:path-active'));
    $obj->{'setup-priority'} = trim($xp->findvalue('./j:setup-priority'));

    $obj->{'hold-priority'} = trim($xp->findvalue('./j:hold-priority'));
    $obj->{'smart-optimize-timer'} = trim($xp->findvalue('./j:smart-optimize-timer'));

    #what is cspf-status
    #$obj->{'title'} = trim($xp->find('./j:cspf-status'));
    $obj->{'explicit-route'} = { 'addresses' => () };
    my $addresses = $xp->find('./j:explicit-route/j:address');

    foreach my $address (@$addresses){
	push(@{$obj->{'explicit-route'}->{'addresses'}}, $address->textContent);
    }

    $obj->{'explicit-route'}->{'explicit-route-type'} = trim($xp->findvalue('./j:explicit-route/j:explict-route-type'));

    $obj->{'received-rro'} = trim($xp->findvalue('./j:received-rro'));
    
    return $obj;
}


sub _edit_config{
    my $self = shift;
    my %params = @_;

    $self->{'logger'}->debug("Sending the following config: " . $params{'config'});

    if(!defined($params{'config'})){
	$self->{'logger'}->error("No Configuration specified!");
	return FWDCTL_FAILURE;
    }

    if(!$self->{'connected'}){
	$self->{'logger'}->error("Not currently connected to the switch");
	return FWDCTL_FAILURE;
    }
    
    my %queryargs = ( 'target' => 'candidate' );
    my $res = $self->{'jnx'}->lock_config(%queryargs);

    if($self->{'jnx'}->has_error){
	$self->{'logger'}->error("Error attempting to lock config: " . Dumper($self->{'jnx'}->get_first_error()));
	return FWDCTL_FAILURE;
    }

    %queryargs = (
        'target' => 'candidate'
        );

    $queryargs{'config'} = $params{'config'};
    
    $res = $self->{'jnx'}->edit_config(%queryargs);
    if($self->{'jnx'}->has_error){
	$self->{'logger'}->error("Error attempting to modify config: " . Dumper($self->{'jnx'}->get_first_error()));
	my %queryargs = ( 'target' => 'candidate' );
	$res = $self->{'jnx'}->unlock_config(%queryargs);
	return FWDCTL_FAILURE;
    }

    $self->{'jnx'}->commit();
    if($self->{'jnx'}->has_error){
	$self->{'logger'}->error("Error attempting to commit the config: " . Dumper($self->{'jnx'}->get_first_error()));
	my %queryargs = ( 'target' => 'candidate' );
        $res = $self->{'jnx'}->unlock_config(%queryargs);
	return;
    }

    my %queryargs = ( 'target' => 'candidate' );
    $res = $self->{'jnx'}->unlock_config(%queryargs);

    return FWDCTL_SUCCESS;
}

sub trim{
    my $s = shift; 
    $s =~ s/^\s+|\s+$//g;
    return $s
}

1;
