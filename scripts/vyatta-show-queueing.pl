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
use Getopt::Long;

use strict;
use warnings;

my $intf_type;
my $summary;

# Map from kernel qdisc names to configuration names
my %qdisc_types = (
    'pfifo_fast' => 'default',
    'sfq'        => 'fair-queue',
    'tbf'        => 'rate-limit',
    'htb'        => 'traffic-shaper',
    'pfifo' 	 => 'drop-tail',

    # future
    'prio'  => 'priority',
    'netem' => 'network-emulator',
    'gred'  => 'random-detect',
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
    'bonding'	=> 'bond',
);

sub show_brief {
    my $match = '.+';    # match anything

    if ($intf_type) {
        my $prefix = $interface_types{$intf_type};
        defined $prefix
          or die "Unknown interface type $intf_type\n";
        $match = "^$prefix\\d(\\.\\d)?\$";
    }

    print "Output queues:\n";
    print "Interface  Qos-Policy             Sent    Dropped   Overlimit\n";

    # Read qdisc info
    open( my $tc, '/sbin/tc -s qdisc ls |' ) or die 'tc command failed';
    while (<$tc>) {

        # qdisc sfq 8003: dev eth1 root limit 127p quantum 1514b
        my ( undef, $qdisc, undef, undef, $interface, $parent ) = split;

        #  Sent 13860 bytes 88 pkt (dropped 0, overlimits 0 requeues 0)
        $_ = <$tc>;
        chomp;
        my ( undef, $sent, undef, undef, undef, undef, $drop, undef, $over ) =
          split;

        # punctuation was never jamal's strong suit
        $drop =~ s/,$//;

        #  rate 0bit 0pps backlog 0b 0p requeues 0
        <$tc>;

        if ( $parent eq 'root' && $interface =~ $match ) {
            my $shaper = $qdisc_types{$qdisc};
            defined $shaper or $shaper = '[' . $qdisc . ']';

            printf "%-10s %-16s %10d %10d %10d\n", $interface, $shaper, $sent,
              $drop, $over;
        }
    }
    close $tc;
}

# FIXME This needs to change to deal with multi-level tree and ingress
sub show {
    my $interface = shift;

    print "\n";
    print "$interface Output queue:\n";
    print "Class      Qos-Policy             Sent    Dropped   Overlimit\n";

    open( my $tc, "/sbin/tc -s qdisc show dev $interface |" )
      or die 'tc command failed: $!';
    while (<$tc>) {

        # qdisc htb 1: root r2q 10 default 20 direct_packets...
        my ( undef, $qdisc, $id, $parent ) = split;
        $id =~ s/:$//;

        #  Sent 13860 bytes 88 pkt (dropped 0, overlimits 0 requeues 0)
        $_ = <$tc>;
        chomp;
        my ( undef, $sent, undef, undef, undef, undef, $drop, undef, $over ) =
          split;
        $drop =~ s/,$//;

        #  rate 0bit 0pps backlog 0b 0p requeues 0
        <$tc>;

        my $shaper = $qdisc_types{$qdisc};
        defined $shaper or $shaper = '[' . $qdisc . ']';

        if ( $parent eq 'root' ) {
            printf "%-10s %-16s %10d %10d %10d\n", $id, $shaper, $sent, $drop,
              $over;
        }
        else {
            printf "  %-8s %-16s %10d %10d %10d\n", $id, $shaper, $sent, $drop,
              $over;
        }
    }
    close $tc;
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
    my $match = '.+';    # match anything

    if ($intf_type) {
	my $prefix = $interface_types{$intf_type};
	defined $prefix
	    or die "Unknown interface type $intf_type\n";
	$match = "^$prefix\\d(\\.\\d)?\$";
    }

    open( my $ip, '/sbin/ip link show |' ) or die 'ip command failed';
    while (<$ip>) {

        # 1: lo: <LOOPBACK, UP,>...
        my ( undef, $interface ) = split;
        $interface =~ s/:$//;

        if ( $interface =~ $match ) {
	    unshift @ARGV, $interface;
	}

        #    link/loopback ....
        <$ip>;
    }
    close $ip;
}

foreach my $interface (@ARGV) {
    show($interface);
}

