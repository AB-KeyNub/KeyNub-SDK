#!/usr/bin/env perl
# KeyNub dongle check from Perl: enumerate -> open -> verify -> session ->
# read a record -> app-crypto round trip.
#
#   KEYNUB_LICDONGLE_FLAT_LIBRARY=../../build/keynub_licdongle_flat.dll \
#     perl -I../../bindings/perl/lib verify_and_read.pl
#
# Note the library: the Perl binding goes through the flat companion API, so it
# wants keynub_licdongle_flat, not the core keynub_licdongle.
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# READ FIRST: docs/integration-security.md. This sample prints whether the dongle
# is genuine, which is the one thing a real licence check must not do — a printed
# boolean is a deleted line away from nothing. protect_something() shows the shape
# that actually protects something.
#
# The binding is dongle-centric rather than session-object-centric: session_open
# and the record and app-crypto calls all hang off the dongle, which keeps the
# object count down in a language where most people are writing a script.

use strict;
use warnings;

use KeyNub::LicDongle qw($SCOPE_DEVELOPER);

sub report {
    my ($dongle) = @_;
    my $info = $dongle->get_info;
    printf "Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.\n",
        $info->{protocol_major}, $info->{protocol_minor},
        $info->{firmware_major}, $info->{firmware_minor}, $info->{firmware_patch},
        $info->{data_free}, $info->{data_capacity};

    if ($info->{watchdog_reboot}) {
        # The only trace a firmware hang leaves behind. Worth reporting to support.
        print "WARNING: this dongle's previous boot ended in a watchdog reset.\n";
    }

    my $result = $dongle->verify_genuine;
    printf "Genuine: %s (serial %s, batch %s)\n",
        $result->{genuine} ? 'true' : 'false',
        $result->{serial}, $result->{batch};
}

sub read_records {
    my ($dongle) = @_;
    my @records = $dongle->record_list;
    printf "%d record(s) on the dongle:\n", scalar @records;
    printf "  %-16s %6d bytes\n", $_->{name}, $_->{size} for @records;

    for my $record (@records) {
        next unless $record->{name} eq 'license';
        my $data = $dongle->record_read('license');
        printf "Read %d bytes from the license record.\n", length $data;
        last;
    }
}

# The part that actually protects something. At licence-issue time you would call
# app_encrypt once, with a developer dongle, and ship only the blob; the program
# then cannot proceed without a dongle, because it holds no other copy of the data.
# $SCOPE_DEVELOPER lets any dongle from your batch decrypt it, so one file serves
# every customer; $SCOPE_DEVICE locks it to one dongle.
sub protect_something {
    my ($dongle) = @_;
    my $needed = 'the data this program cannot run without';

    my $sealed    = $dongle->app_encrypt($SCOPE_DEVELOPER, $needed);
    my $recovered = $dongle->app_decrypt($sealed);

    printf "App-crypto round trip: %d bytes -> %d sealed -> %s\n",
        length $needed, length $sealed,
        $recovered eq $needed ? 'recovered intact' : 'MISMATCH';
}

my ($major, $minor, $patch) = KeyNub::LicDongle::library_version();
printf "KeyNub SDK %d.%d.%d\n", $major, $minor, $patch;

my $count = KeyNub::LicDongle::device_count();
printf "Found %d KeyNub dongle(s).\n", $count;
for my $i (0 .. $count - 1) {
    printf "  [%d] serial %s\n", $i, KeyNub::LicDongle::device_serial($i);
}
if ($count == 0) {
    print "No dongle attached; nothing to do.\n";
    exit 0;
}

# The binding dies on failure, so one eval covers every call below. $@ carries the
# SDK's diagnostic text, which is what tells "no dongle" from "certificate rejected".
my $dongle;
eval {
    $dongle = KeyNub::LicDongle->open;    # first dongle, or ->open($serial)
    report($dongle);

    $dongle->session_open;
    read_records($dongle);
    protect_something($dongle);
    $dongle->session_close;
    1;
} or do {
    print STDERR "KeyNub error: $@";
    $dongle->close if $dongle;
    exit 1;
};

$dongle->close;
