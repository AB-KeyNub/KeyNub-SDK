#!/usr/bin/env perl
# KeyNub SDK - Perl sample: take ownership of a new dongle.
#
# A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
# that from the next session onward only your key can write records, erase them or
# increment counters. Run it once per dongle, when it arrives.
#
# Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
#
#   openssl ecparam -name prime256v1 -genkey -noout |
#     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
#
#   KEYNUB_LICDONGLE_FLAT_LIBRARY=../../build/keynub_licdongle_flat.dll \
#     perl -I../../bindings/perl/lib rotate_write_key.pl ../../keys/keynub-shipping-writeauth.key.der my-key.der
#
# Note the library: the Perl binding goes through the flat companion API, so it
# wants keynub_licdongle_flat, not the core keynub_licdongle.
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# The replacement key is worth what your licence-signing key is worth. It cannot be
# recovered from the dongle, and a unit rotated to a key you have lost has to come
# back to be re-provisioned.

use strict;
use warnings;

use KeyNub::LicDongle;

sub read_key {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot open $path: $!\n";
    local $/;
    my $der = <$fh>;
    close $fh;
    return $der;
}

if (@ARGV != 2) {
    print STDERR "usage: perl rotate_write_key.pl <current-key.der> <new-key.der>\n";
    exit 2;
}
my ($current, $replacement) = map { read_key($_) } @ARGV;

my $dongle;
my $status = eval {
    if (KeyNub::LicDongle::device_count() == 0) {
        print "Connect a KeyNub dongle and re-run.\n";
        return 0;
    }

    $dongle = KeyNub::LicDongle->open;    # first dongle, or ->open($serial)
    printf "dongle %s\n", $dongle->serial;

    $dongle->session_open;
    $dongle->authorize_write($current);
    $dongle->rotate_write_key($replacement);
    print "rotated: this dongle now answers only to your key\n";
    $dongle->session_close;

    # A fresh session is the only place the change is observable: the session
    # above keeps the role it was already granted.
    $dongle->session_open;
    my $still_works = eval { $dongle->authorize_write($current); 1 };
    if ($still_works) {
        print STDERR "WARNING: the old key still works -- do not ship this unit\n";
        return 1;
    }
    print "confirmed: the old key no longer elevates\n";
    $dongle->authorize_write($replacement);
    print "confirmed: your key elevates\n";
    $dongle->session_close;

    print "\nKeep the replacement key safe. Every future write to this dongle needs it.\n";
    return 0;
};
if (!defined $status) {
    my $err = $@;
    print STDERR "KeyNub error: $err";
    $status = 1;
}
$dongle->close if $dongle;
exit $status;
