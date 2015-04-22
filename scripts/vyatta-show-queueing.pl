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
# Copyright (C) 2010 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Stephen Hemminger
# Description: Script to display QoS information in pretty form
#
# **** End License ****
#

use strict;
use warnings;

use Getopt::Long;
use Tree::Simple;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Interface;
use Vyatta::Misc;

my $intf_type;

# Map from kernel qdisc names to configuration names
my %qdisc_types = (
    'pfifo_fast' => 'default',
    'fq_codel'   => 'fq-codel',
    'sfq'        => 'fair-queue',
    'tbf'        => 'rate-control',
    'htb'        => 'shaper',
    'pfifo'      => 'drop-tail',
    'red'        => 'random-detect',
    'drr'        => 'round-robin',
    'prio'       => 'priority-queue',
    'netem'      => 'network-emulator',
    'gred'       => 'weighted-random',
    'ingress'    => 'limiter',
);

# Convert from kernel to vyatta nams
sub shaper {
    my $qdisc  = shift;
    my $shaper = $qdisc_types{$qdisc};

    return $shaper ? $shaper : '[' . $qdisc . ']';
}

sub show_brief {
    my $fmt = "%-10s %-16s %12s %12s %12s\n";
    printf $fmt, 'Interface', 'Policy', 'Sent', 'Dropped', 'Overlimit';

    # Read qdisc info
    open( my $tc, '-|', '/sbin/tc -s qdisc ls' )
      or die 'tc qdisc command failed';

    my @lines;
    my ( $qdisc, $parent, $ifname, $id );
    my $root = 'root';

    while (<$tc>) {
        chomp;
        my @fields = split;
        if ( $fields[0] eq 'qdisc' ) {
            my ( $ptype, $pid );

            # Examples:
            # qdisc sfq 8003: dev eth1 root limit 127p quantum 1514b
            # qdisc gred 2: dev eth0 parent 1:
            ( undef, $qdisc, $id, undef, $ifname, $ptype, $pid ) = @fields;

            $parent = ( $ptype eq 'parent' ) ? $pid : $ptype;
            next;
        }

        # skip unwanted extra stats
        next if ( $fields[0] ne 'Sent' );

        #  Sent 13860 bytes 88 pkt (dropped 0, overlimits 0 requeues 0)
        my ( undef, $sent, undef, undef, undef, undef, $drop, undef, $over ) =
          @fields;

        # punctuation was never jamal's strong suit
        $drop =~ s/,$//;

        if ( $qdisc eq 'dsmark' ) {
            # dsmark is used as a top-level before htb or gred
            $root = $id;
        }
        elsif ( $parent eq $root ) {
            $root = 'root';
            if ($intf_type) {
                my $intf = new Vyatta::Interface($ifname);
                next unless ( $intf && ( $intf->type() eq $intf_type ) );
            }

            push @lines, sprintf $fmt, $ifname, shaper($qdisc), $sent, $drop,
              $over;
        }
    }
    close $tc;
    print sort @lines;
}

sub qmajor {
    my $id = shift;

    $id =~ s/:.*$//;
    return hex($id);
}

sub qminor {
    my $id = shift;

    $id =~ s/^.*://;
    return hex($id);
}

# This collects all the qdisc information into one hash
# reference to map of qdisc class to statistics
sub get_qdisc {
    my $interface = shift;
    my %qdisc;
    my $default = undef;

    open( my $tc, '-|', "/sbin/tc -s qdisc show dev $interface" )
      or die 'tc command failed: $!';

    my ($qid, $qinfo);

    while (<$tc>) {
        chomp;

        # qdisc htb 1: root r2q 10 default 20 direct_packets...
        # qdisc pfifo 8008: parent 1:2 limit 1000p
        # qdisc fq_codel 8001: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5.0ms interval 100.0ms
        /^qdisc (\S+) ([0-9a-f]+): / && do {
            # record last qdisc
            $qdisc{$qid} = $qinfo if (defined($qid));
            $qinfo = {};
            $qid   = 0;
            $qinfo->{name} = shaper($1);

            if (/ root /) {
                $qinfo->{qidname} = 'root';
            } elsif ( / parent (\S+)/ ) {
                my $parent = qminor($1);
                $qid = $parent;
                if (defined($default) && ($parent == $default)) {
                    $qinfo->{qidname} = 'default';
                } else {
                    $qinfo->{qidname} = qminor($1);
                }
            };

            if (/ default ([0-9a-f]+) / ) {
                $default = hex($1);
            };

            next;
        };

        /^ Sent (\d+) bytes (\d+) pkt/ && do {
            $qinfo->{sent} = $1;
        };

        / \(dropped (\d+), overlimits (\d+) requeues (\d+)\) / && do {
            $qinfo->{dropped} = $1;
            $qinfo->{overlimit} = $2;
            $qinfo->{requeues} = $3;
        };

        / rate (\S+)bit (\d+)pps / && do {
            $qinfo->{rate} = $1;
            $qinfo->{pps} = $2;
        };

        / backlog \d+b (\d+)p / && do {
            $qinfo->{backlog} = $1;
        }
    }
    close $tc;
    $qdisc{$qid} = $qinfo if (defined($qid));

    return \%qdisc;
}

my $CLASSFMT = "%-10s %-16s";
my @fields = qw(sent dropped overlimit backlog);

sub print_info {
    my $qinfo = shift;
    my $id   = $qinfo->{qidname};
    my $name = $qinfo->{name};

    # Class Policy
    printf $CLASSFMT, $id, $name;

    for (@fields) {
        my $qval = $qinfo->{$_};
        if (defined($qval)) {
            printf ' %12s', $qval;
        } else {
            print '             ';
        }
    }
    print "\n";
}

sub show_queues {
    my ( $interface, $qdisc ) = @_;

    print "\n$interface Queueing:\n";
    printf $CLASSFMT, 'Class', 'Policy';
    for (@fields) {
        printf " %12s", ucfirst($_);
    }
    print "\n";

    foreach my $qid ( sort {$a <=> $b} keys %{$qdisc} ) {
        my $qinfo = $qdisc->{$qid};
        print_info($qinfo);
    }
}

sub show {
    my $interface = shift;
    my $qdisc = get_qdisc($interface);
    show_queues($interface, $qdisc);
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
