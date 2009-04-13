#!/usr/bin/perl
#
# Module: vyatta-show-queueing.pl
#
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Stephen Hemminger
# Date: July 2008
# Description: Script to display QoS information in pretty form
#
# **** End License ****
#

use strict;
use warnings;

use Getopt::Long;
use lib "/opt/vyatta/share/perl5/";
use Vyatta::Interface;
use Vyatta::Misc;

my $intf_type;

# Map from kernel qdisc names to configuration names
my %qdisc_types = (
    'pfifo_fast' => 'default',
    'sfq'        => 'fair-queue',
    'tbf'        => 'rate-limit',
    'htb'        => 'traffic-shaper',
    'pfifo'      => 'drop-tail',
    'red'        => 'random-detect',
    'ingress'    => 'traffic-limiter',
    'drr'        => 'round-robin',
    'prio'       => 'priority-queue',
    'netem'      => 'network-emulator',
);

# This is only partially true names can really be anything.
my %interface_types = (
    'ethernet'  => 'eth',
    'serial'    => 'wan',
    'tunnel'    => 'tun',
    'bridge'    => 'br',
    'loopback'  => 'lo',
    'pppoe'     => 'pppoe',
    'pppoa'     => 'pppoa',
    'adsl'      => 'adsl',
    'multilink' => 'ml',
    'wireless'  => 'wlan',
    'bonding'   => 'bond',
);

sub show_brief {
    my %ingress;

    print "Output Queues:\n";
    my $fmt = "%-10s %-16s %10s %10s %10s\n";
    printf $fmt, 'Interface', 'Qos-Policy', 'Sent', 'Dropped', 'Overlimit';

    # Read qdisc info
    open( my $tc, '/sbin/tc -s qdisc ls |' ) or die 'tc command failed';

    my ( $qdisc, $parent, $ifname, $id );
    while (<$tc>) {
        chomp;
        my @fields = split;
        if ( $fields[0] eq 'qdisc' ) {

            # qdisc sfq 8003: dev eth1 root limit 127p quantum 1514b
            ( undef, $qdisc, $id, undef, $ifname, $parent ) = @fields;
            next;
        }

        # skip unwanted extra stats
        next if ( $fields[0] ne 'Sent' );

        #  Sent 13860 bytes 88 pkt (dropped 0, overlimits 0 requeues 0)
        my ( undef, $sent, undef, undef, undef, undef, $drop, undef, $over ) =
          @fields;

        # punctuation was never jamal's strong suit
        $drop =~ s/,$//;

        my $shaper = $qdisc_types{$qdisc};
        defined $shaper or $shaper = '[' . $qdisc . ']';

        if ( $id eq 'ffff:' ) {
            my @args = ( $ifname, $shaper, $sent, $drop, $over );
            $ingress{$ifname} = \@args;
        }
        elsif ( $parent eq 'root' ) {
            if ($intf_type) {
                my $intf = new Vyatta::Interface($ifname);
                next unless ( $intf && ( $intf->type() eq $intf_type ) );
            }

            printf $fmt, $ifname, $shaper, $sent, $drop, $over;
        }
    }
    close $tc;

    if (%ingress) {
        print "\nInput:\n";
        printf $fmt, 'Ifname', 'Qos-Policy', 'Received', 'Dropped', 'Overlimit';

        foreach my $name ( keys %ingress ) {
            my $args = $ingress{$name};
            printf $fmt, @$args;
        }
    }
}

# FIXME This needs to change to deal with multi-level tree
sub show {
    my $interface = shift;
    my $fmt       = "%-10s  %-16s %-10s %-10s %-10s %-10s\n";

    print "\n";
    print "$interface Output Queueing:\n";
    printf $fmt, 'Class', 'Qos-Policy', 'Sent', 'Dropped', 'Overlimit',
      'Queued';

    my $tc;
    my %classmap = ();

    open( $tc, "/sbin/tc class show dev $interface |" )
      or die 'tc command failed: $!';
    while (<$tc>) {

       # class htb 1:1 root rate 1000Kbit ceil 1000Kbit burst 1600b cburst 1600b
       # class htb 1:2 parent 1:1 leaf 8001:
       # class ieee80211 :2 parent 8001:
        my ( undef, undef, $id, $parent, $pid, $leaf, $qid ) = split;
        if ( $parent eq 'parent' && $leaf eq 'leaf' ) {
            $classmap{$qid} = $id;
        }
    }
    close $tc;

    open( $tc, "/sbin/tc -s qdisc show dev $interface |" )
      or die 'tc command failed: $!';

    my ( $rootid, $qdisc, $parent, $qid );
    my @ingress;

    my ( $shaper, $id, $sent, $drop, $over, $backlog );
    while (<$tc>) {
        chomp;
        my @fields = split;
        if ( $fields[0] eq 'qdisc' ) {

            # qdisc htb 1: root r2q 10 default 20 direct_packets...
            ( undef, $qdisc, $qid, $parent ) = @fields;
            next;
        }

        # skip unwanted extra stats
        if ( $fields[0] eq 'Sent' ) {

            #  Sent 13860 bytes 88 pkt (dropped 0, overlimits 0 requeues 0)
            ( undef, $sent, undef, undef, undef, undef, $drop, undef, $over ) =
              @fields;

            # fix silly punctuation bug in tc
            $drop =~ s/,$//;

            $shaper = $qdisc_types{$qdisc};

            # this only happens if user uses some qdisc not in pretty print list
            defined $shaper or $shaper = '[' . $qdisc . ']';

            $id = $classmap{$qid};
            defined $id or $id = $qid;

            if ( $qid eq 'ffff:' ) {

                # print ingress later
                @ingress = ( $shaper, $sent, $drop, $over );
                next;
            }

            if ( $parent eq 'root' ) {
                $rootid = $id;
                $id     = 'root';
            }
            else {
                $id =~ s/$rootid//;
                $id = sprintf( "  %-8s", $id );
            }
        }
        elsif ( $fields[0] eq 'rate' ) {

            # rate 0bit 0pps backlog 0b 23p requeues 0
            ( undef, undef, undef, undef, undef, $backlog ) = @fields;

            printf $fmt, $id, $shaper, $sent, $drop, $over, $backlog;
        }
    }
    close $tc;

    if (@ingress) {
        print "\n$interface Input:\n";
        $fmt = "%-16s %-10s %-10s %-10s\n";
        printf $fmt, 'Qos-Policy', 'Received', 'Dropped', 'Overlimit';
        printf $fmt, @ingress;
    }
}

sub usage {
    print "Usage: $0 [--type={ethernet,serial}] --brief\n";
    print "       $0 interface(s)\n";
    exit 1;
}

GetOptions(
    'type=s' => \$intf_type,
    'brief'  => sub { show_brief(); exit 0; },
) or usage();

# if no arguments given, rebuild ARGV with list of all interfaces
if ( $#ARGV == -1 ) {
    foreach my $ifname ( getInterfaces() ) {
        if ($intf_type) {
            my $intf = new Vyatta::Interface($ifname);
            next unless ( $intf && $intf_type eq $intf->type() );
        }
        push @ARGV, $ifname;
    }
}

foreach my $interface ( sort @ARGV ) {
    show($interface);
}

