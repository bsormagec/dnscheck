#!/usr/bin/perl
#
# $Id$
#
# Copyright (c) 2007 .SE (The Internet Infrastructure Foundation).
#                    All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
# GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
# IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
# IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
######################################################################

package DNSCheck::Lookup::ASN;

require 5.010001;
use warnings;
use strict;
use utf8;

use Net::DNS;
use Net::IP;
use Carp;
use List::MoreUtils qw[all];
use List::Util qw[max];

sub new {
    my $proto = shift;
    my $class = ref( $proto ) || $proto;
    my $self  = {};
    bless $self, $class;

    $self->{parent} = shift;

    # hash of ASN indexed by IP
    $self->{asn}     = ();
    $self->{v4roots} = $self->{parent}->config->get( "net" )->{v4root};
    $self->{v6roots} = $self->{parent}->config->get( "net" )->{v6root};

    return $self;
}

sub parent {
    my $self = shift;

    return $self->{parent};
}

sub flush {
    my $self = shift;

    $self->{asn} = ();

    return;
}

sub asdata {
    my $self = shift;
    my $ip   = shift;
    my @r4   = @{ $self->{v4roots} };
    my @r6   = @{ $self->{v6roots} };

    if ( !ref( $ip ) ) {
        my $tmp = Net::IP->new( $ip );
        if (!$tmp) {
            $self->parent->logger->auto( "ASN:INVALID_ADDRESS", $ip );
            return;
        }

        $ip = $tmp;
    }
    if (defined($self->{asn}{$ip->ip})) {
        return @{$self->{asn}{$ip->ip}}
    }

  AGAIN:
    if ( @r4 == 0 or @r6 == 0 ) {    # No more roots to try
        $self->parent->logger->auto( "ASN:LOOKUP_ERROR", $ip->ip );
        return;
    }

    my $rev = $ip->reverse_ip;
    if ( $ip->version == 6 ) {
        my $r = shift @r6;
        $rev =~ s/ip6\.arpa/$r/e;
    }
    elsif ( $ip->version == 4 ) {
        my $r = shift @r4;
        $rev =~ s/in-addr\.arpa/$r/e;
    }
    else {
        croak "Strange IP version: " . $ip->version;
    }

    my $packet = $self->parent->dns->query_resolver( $rev, 'IN', 'TXT' );
    goto AGAIN unless $packet;

    my @asdata;
    foreach my $rr ( $packet->answer ) {
        next unless $rr->type eq 'TXT';
        foreach my $txt ( $rr->char_str_list ) {
            $self->parent->logger->auto('ASN:RAW', $ip->ip, $rr->txtdata);
            my ( $numbers, $prefix ) = split( / \| /, $txt );
            my @as_set = split( /\s+/, $numbers );
            my $pref = Net::IP->new( $prefix );

            croak "broken AS set: @as_set" unless all { /^\d+$/ } @as_set;
            croak "broken prefix: $prefix" unless $pref;
            $self->parent->logger->auto( "ASN:ANNOUNCE_BY", $ip->ip, join( ",", @as_set ) );
            $self->parent->logger->auto( "ASN:ANNOUNCE_IN", $ip->ip, $pref->prefix );

            push @asdata, [ \@as_set, $pref ];
        }
    }

    my $max_len = max map { $_->[1]->prefixlen } @asdata;

    my @tmp = grep { $_->[1]->prefixlen == $max_len } @asdata;

    if (scalar(@tmp)==0) {
        $self->parent->logger->auto( "ASN:NOT_ANNOUNCE", $ip->ip );
    }

    $self->{asn}{$ip->ip} = \@tmp;

    return @tmp;
}

1;

__END__


=head1 NAME

DNSCheck::Lookup::ASN - AS Number Lookup

=head1 DESCRIPTION

Helper functions for looking up AS (Autonomous System) numbers using 
B<asn.cymru.com>.

=head1 METHODS

=head2 asdata($ip)

Looks up the AS annoucement information for the given IP address. IPv4 and IPv6 are supported. The return value is a list with zero or more entries, which
are in turn references to two-element arrays. The first element is another array reference, to a list of AS numbers. The second element is a Net::IP object
specifying the largest prefix in which the request IP was announced (and which the given AS numbers refer to).

=head2 flush()

Discard all cached lookups.

=head2 new($parent)

This is not meant to be called directly. Get an object by calling the 
L<DNSCheck::asn()> method instead;

=head2 parent()

Returns a reference to the current parent object.

=head1 EXAMPLES

    use DNSCheck;

    my $asn    = DNSCheck->new->asn;

    $asn->lookup("64.233.183.99");

=head1 SEE ALSO

L<DNSCheck>

=cut
