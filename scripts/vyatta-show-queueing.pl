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
use Tree::Simple;

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
    'gred'	 => 'weighted-random',
);

# Convert from kernel to vyatta nams
sub shaper {
    my $qdisc  = shift;
    my $shaper = $qdisc_types{$qdisc};

    return $shaper ? $shaper : '[' . $qdisc . ']';
}

sub show_brief {
    my %ingress;

    print "Output Queues:\n";
    my $fmt = "%-10s %-16s %10s %10s %10s\n";
    printf $fmt, 'Interface', 'Qos-Policy', 'Sent', 'Dropped', 'Overlimit';

    # Read qdisc info
    open( my $tc, '/sbin/tc -s qdisc ls |' ) or die 'tc command failed';

    my @lines;
    my ( $qdisc, $parent, $ifname, $id );
    my $root = 'root';

    while (<$tc>) {
        chomp;
        my @fields = split;
        if ( $fields[0] eq 'qdisc' ) {
	    my ($ptype, $pid);
	    # Examples:
            # qdisc sfq 8003: dev eth1 root limit 127p quantum 1514b
	    # qdisc gred 2: dev eth0 parent 1:
            ( undef, $qdisc, $id, undef, $ifname, $ptype, $pid ) = @fields;

	    $parent = ($ptype eq 'parent') ? $pid : $ptype;
            next;
        }

        # skip unwanted extra stats
        next if ( $fields[0] ne 'Sent' );

        #  Sent 13860 bytes 88 pkt (dropped 0, overlimits 0 requeues 0)
        my ( undef, $sent, undef, undef, undef, undef, $drop, undef, $over ) =
          @fields;

        # punctuation was never jamal's strong suit
        $drop =~ s/,$//;

        if ( $id eq 'ffff:' ) {
            $ingress{$ifname} =
              [ $ifname, shaper($qdisc), $sent, $drop, $over ];
        } elsif ( $qdisc eq 'dsmark' ) {
	    # dsmark is used as a top-level before htb or gred
	    $root = $id;
	} elsif ( $parent eq $root ) {
	    $root = 'root';
            if ($intf_type) {
                my $intf = new Vyatta::Interface($ifname);
                next unless ( $intf && ( $intf->type() eq $intf_type ) );
            }

	    push @lines, sprintf $fmt, $ifname, shaper($qdisc), $sent, $drop, $over;
        }
    }
    close $tc;
    print sort @lines;

    if (%ingress) {
        print "\nInput:\n";
        printf $fmt, 'Ifname', 'Qos-Policy', 'Received', 'Dropped', 'Overlimit';

        foreach my $name ( keys %ingress ) {
            my $args = $ingress{$name};
            printf $fmt, @$args;
        }
    }
}

# Sort by class id which is a string of form major:minor
# NB: numbers are hex
sub byclassid {
    my ($a1, $a2) = ($a =~ m/([0-9a-f]+):([0-9a-f]+)/);
    my ($b1, $b2) = ($b =~ m/([0-9a-f]+):([0-9a-f]+)/);

    return hex($a2) <=> hex($b2) if ($a1 == $b1);
    return hex($a1) <=> hex($b1);
}

sub class2tree {
    my ( $classes, $parentid, $parent ) = @_;

    foreach my $id ( sort byclassid keys %{$classes} ) {
        my $class = $classes->{$id};
        next unless ( $class->{parent} && $class->{parent} eq $parentid );
        my $node = Tree::Simple->new( $class->{info} );
	$parent->addChild($node);
        class2tree( $classes, $id, $node );
    }

    return $parent;
}

# Build a tree of output information
# (This is N^2 but not a big issue)
sub get_class {
    my ( $interface, $rootq, $qdisc ) = @_;
    my %classes;

    open( my $tc, "/sbin/tc -s class show dev $interface |" )
      or die 'tc command failed: $!';

    my ( $id, $name, $sent, $drop, $over, $root, $leaf, $parent );

    while (<$tc>) {
        chomp;
        /^class/ && do {
	    # class htb 1:1 root rate 1000Kbit ceil 1000Kbit burst 1600b cburst 1600b
	    # class htb 1:2 parent 1:1 leaf 8001:
	    # class ieee80211 :2 parent 8001:
            my ( $l, $q, $t );
            ( undef, $name, $id, $t, $parent, $l, $q ) = split;
	    $leaf = undef;
	    if ($t eq 'root') {
		$parent = undef;
	    } elsif ($t eq 'parent') {
		if ($l eq 'leaf') {
		    $q =~ s/:$//;
		    $leaf = hex($q);
		}
	    } else {
		die "confused by tc class output for type 'class $name $id $t'";
	    }
            next;
        };

        /^ Sent/ && do {
            #  Sent 13860 bytes 88 pkt (dropped 0, overlimits 0 requeues 0)
            ( undef, $sent, undef, undef, undef, undef, $drop, undef, $over ) =
              split;

            # fix silly punctuation bug in tc
            $drop =~ s/,$//;
            next;
        };

        /^ rate/ && do {
            #  rate 0bit 0pps backlog 0b 23p requeues 0
            my ( undef, $rate, undef, undef, undef, $backlog ) = split;
            $backlog =~ s/p$//;
            $rate    =~ s/bit$//;

	    # split $id of form 1:10 into parent, child id
	    my ($maj, $min) = ($id =~ m/([0-9a-f]+):([0-9a-f]+)/);

	    # TODO handle nested classes??
	    next if (hex($maj) != $rootq);

	    # record info for display
            my @args = ( hex($min) );
            if ($leaf) {
		my $qdisc_info = $qdisc->{$leaf};
		die "info for $leaf is unknown" unless $qdisc_info;
                push @args, @{ $qdisc_info };
            } else {
                push @args, shaper($name), $sent, $drop, $over, $rate, $backlog;
            }

            $classes{$id} = {
                id     => $id,
                parent => $parent,
                info   => \@args,
            };

            $root = $classes{$id} unless $parent;
            next;
          }
    }
    close $tc;
    return unless $root;

    return class2tree( \%classes, $root->{id},
        Tree::Simple->new( $root->{info}, Tree::Simple->ROOT ) );
}

sub qmajor {
    my $id = shift;

    $id =~ s/:.*$//;
    return hex($id);
}

# This collects all the qdisc information into one hash
# and root queue id and reference to map of qdisc to statistics
sub get_qdisc {
    my $interface = shift;
    my %qdisc;
    my ($root, $dsmark);

    open( my $tc, "/sbin/tc -s qdisc show dev $interface |" )
      or die 'tc command failed: $!';

    my ( $qid, $name, $sent, $drop, $over );
    while (<$tc>) {
        chomp;
        /^qdisc/ && do {
            # qdisc htb 1: root r2q 10 default 20 direct_packets...
	    my ($t, $pqid);

            ( undef, $name, $qid, $t, $pqid ) = split;
	    $qid = qmajor($qid);
	    
	    if ( $name eq 'dsmark' ) {
		$dsmark = $qid;
	    } elsif ( $t eq 'parent' && defined($dsmark) 
		      && qmajor($pqid) == $dsmark ) {
		$root = $qid;
	    } elsif ( $t eq 'root' ) {
		$root = $qid;
	    }
            next;
        };

        /^ Sent/ && do {
            #  Sent 13860 bytes 88 pkt (dropped 0, overlimits 0 requeues 0)
            ( undef, $sent, undef, undef, undef, undef, $drop, undef, $over ) =
              split;

            # fix silly punctuation bug in tc
            $drop =~ s/,$//;
            next;
        };

        /^ rate/ && do {
            # rate 0bit 0pps backlog 0b 23p requeues 0
            my ( undef, $rate, undef, undef, undef, $backlog ) = split;

            $backlog =~ s/p$//;
            $rate    =~ s/bit$//;

            $qdisc{$qid} = [ shaper($name), $sent, $drop, $over, $rate, $backlog ];
          }
    }
    close $tc;

    return ( $root, \%qdisc );
}

my $INGRESS = 0xffff;

sub show_queues {
    my ( $interface, $root, $qdisc ) = @_;
    my $args = $qdisc->{$root};
    return unless $args;

    my $fmt     = "%-10s %-16s %-10s %-9s %-9s %-9s %s\n";
    print "\n$interface ", ( ( $root eq $INGRESS ) ? 'Input' : 'Output' ),
      " Queueing:\n";
    printf $fmt, 'Class', 'Qos-Policy',
      ( ( $root eq $INGRESS ) ? 'Received' : 'Sent' ),
      'Dropped', 'Overlimit', 'Rate', 'Queued';

    printf $fmt, 'root', @{$args};

    my $tree = get_class( $interface, $root, $qdisc );
    return unless $tree;

    $tree->traverse( sub { my $_tree = shift;
			   my @args = @{ $_tree->getNodeValue() };
			   my $id = shift @args;
			   printf $fmt, ('  ' x $_tree->getDepth() . $id ), @args;
		     });
}

sub show {
    my $interface = shift;
    my ( $root, $qdisc ) = get_qdisc($interface);

    show_queues( $interface, $root,    $qdisc ) if $root;
    show_queues( $interface, $INGRESS, $qdisc );
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
