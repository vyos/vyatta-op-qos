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
    'sfq'        => 'fair-queue',
    'tbf'        => 'rate-control',
    'htb'        => 'shaper',
    'pfifo'      => 'drop-tail',
    'red'        => 'random-detect',
    'drr'        => 'round-robin',
    'prio'       => 'priority-queue',
    'netem'      => 'network-emulator',
    'gred'       => 'weighted-random',
    'prio'       => 'priority-queue',
    'ingress'	 => 'limiter',
);

# Convert from kernel to vyatta nams
sub shaper {
    my $qdisc  = shift;
    my $shaper = $qdisc_types{$qdisc};

    return $shaper ? $shaper : '[' . $qdisc . ']';
}

sub show_brief {
    my $fmt = "%-10s %-16s %10s %10s %10s\n";
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

# Sort by class id which is a string of form major:minor
# NB: numbers are hex
sub byclassid {
    my ( $a1, $a2 ) = ( $a =~ m/([0-9a-f]+):([0-9a-f]+)/ );
    my ( $b1, $b2 ) = ( $b =~ m/([0-9a-f]+):([0-9a-f]+)/ );

    if ($a1 eq $b1) {
	return hex($a2) <=> hex($b2);
    } else {
	return hex($a1) <=> hex($b1);
    }
}

# Recursively add classes to parent tree
sub class2tree {
    my ( $classes, $parent_id, $parent_tree ) = @_;

    foreach my $id ( sort byclassid keys %{$classes} ) {
        my $class = $classes->{$id};
        next unless ( $class->{parent} && $class->{parent} eq $parent_id );

        my $node = Tree::Simple->new( $class );
        $parent_tree->addChild($node);

        class2tree( $classes, $id, $node );
    }
}

# Build a tree of output information
# (This is N^2 but not a big issue)
sub get_class {
    my ( $interface, $rootq ) = @_;
    my %classes;

    open( my $tc, '-|', "/sbin/tc -s class show dev $interface" )
      or die 'tc class command failed: $!';

    my ($id, $info, $root);
    while (<$tc>) {
        chomp;
        /^class \S+ (\S+) / && do {
	    # class htb 1:1 root rate 1000Kbit ceil 1000Kbit burst 1600b cburst 1600b
	    # class htb 1:2 parent 1:1 leaf 8001:
	    # class ieee80211 :2 parent 8001:

	    # record last data, and clean slate
	    $classes{$id} = $info if $id;

	    $info = {};
	    $id = $1;
	    $info->{id} = $id;

	    if (/ root / ) {
		$root = $id;
            } else {
		/ parent (\S+)/ && do {
		    $info->{parent} = $1;
		};

		/ leaf ([0-9a-f]+):/ && do {
                    $info->{leaf} = hex($1);
                };
            }
            next;
        };

        /^ Sent (\d+) bytes (\d+) pkt/ && do {
	    $info->{sent} = $1;
	};

	/ \(dropped (\d+), overlimits (\d+) requeues (\d+)\) / && do {
	    $info->{dropped} = $1;
	    $info->{overlimit} = $2;
	    $info->{requeues} = $3;
        };

	/ rate (\S+)bit (\d+)pps / && do {
	    $info->{rate} = $1;
	    $info->{pps} = $2;
	};

	/ backlog \d+b (\d+)p / && do {
	    $info->{backlog} = $1;
	};
    }
    close $tc;
    $classes{$id} = $info if $id;
    return unless $root;

    my $tree = Tree::Simple->new( $classes{$root}, Tree::Simple->ROOT );
    class2tree( \%classes, $root, $tree );
    return $tree;
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
# and root queue id and reference to map of qdisc to statistics
sub get_qdisc {
    my $interface = shift;
    my @qdisc;
    my ( $root, $dsmark );

    open( my $tc, '-|', "/sbin/tc -s qdisc show dev $interface" )
      or die 'tc command failed: $!';

    my ($qid, $qinfo);

    while (<$tc>) {
        chomp;

	# qdisc htb 1: root r2q 10 default 20 direct_packets...
	# qdisc pfifo 8008: parent 1:2 limit 1000p
        /^qdisc (\S+) ([0-9a-f]+): / && do {
	    # record last qdisc
	    $qdisc[$qid] = $qinfo if ($qid);
	    $qinfo = {};

	    my $name = $1;
	    $qid = hex($2);

	    $qinfo->{name} = shaper($name);
	    $dsmark = $qid  if ($name eq 'dsmark');

	    if (/ root /) {
		$root = $qid;
	    } elsif ( / parent (\S+)/ ) {
		my $pqid = $1;

		# hide dsmark qdisc from display
		if (defined($dsmark) && qmajor($pqid) == $dsmark) {
		    $root = $qid;
		} else {
		    $qinfo->{parent} = $pqid;
		}
            }

	    if (/ default ([0-9a-f]+) / ) {
		$qinfo->{default} = hex($1);
	    }

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
    $qdisc[$qid] = $qinfo if $qid;

    return ( $root, \@qdisc );
}

my $CLASSFMT = "%-10s %-16s";
my @fields = qw(sent rate dropped overlimit backlog);

sub print_info {
    my ($id, $name, $info, $depth) = @_;
    my $indent = '  ' x $depth;

    # Class Policy
    printf $CLASSFMT, $indent . $id, $name;

    for (@fields) {
	my $val = $info->{$_};
	if (defined($val)) {
	    printf ' %8s', $val;
	} else {
	    print '         ';
	}
    }
    print "\n";
}

sub show_queues {
    my ( $interface, $qdisc, $root ) = @_;
    my $rootq = $qdisc->[$root];
    my $default = $rootq->{default};

    print "\n$interface Queueing:\n";
    printf $CLASSFMT, 'Class', 'Policy';
    for (@fields) {
	printf " %8s", ucfirst($_);
    }
    print "\n";

    print_info('root', $rootq->{name}, $rootq, 0);

    my $tree = get_class( $interface, $root );
    return unless $tree;

    $tree->traverse(
        sub {
	    my $node = shift;
	    my $class = $node->getNodeValue();
	    my $qid = qminor($class->{id});
	    $qid = 'default' if (defined($default) && $qid == $default);

	    my $subq = $qdisc->[$class->{leaf}];

	    print_info($qid, $subq->{name}, $class, $node->getDepth());
        }
    );
}

sub show {
    my $interface = shift;
    my ( $root, $qdisc );

    # Show output queue first
    ( $root, $qdisc ) = get_qdisc($interface) unless $root;

    show_queues( $interface, $qdisc, $root ) if $root;
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
