#!/usr/bin/env perl
# End-to-end tests for the Perl binding against the in-process device simulator,
# mirroring the C, C++, Rust, Go, Zig, Julia, Nim, Lua, PHP, Ruby, Fortran, COBOL
# and managed suites. No hardware.
#
#   KEYNUB_SIM_PATH=../../build/keynub_licdongle_flat_sim.dll prove -l t/
#
# Test::More is a core module, so only FFI::Platypus has to be installed.
#
# Note the library: this binding uses the flat API, so the test needs
# keynub_licdongle_flat_sim (the flat library with the simulator compiled in),
# not keynub_licdongle_sim.

use strict;
use warnings;
use Test::More;
use File::Spec;
use FFI::Platypus::Buffer ();

# Point the binding at the simulator before loading it.
BEGIN {
    my $name = $^O eq 'MSWin32' ? 'keynub_licdongle_flat_sim.dll'
             : $^O eq 'darwin'  ? 'libkeynub_licdongle_flat_sim.dylib'
             :                    'libkeynub_licdongle_flat_sim.so';
    my $sdk = File::Spec->rel2abs(File::Spec->catdir('..', '..'));
    $ENV{KEYNUB_LICDONGLE_FLAT_LIBRARY} ||= $ENV{KEYNUB_SIM_PATH}
        || File::Spec->catfile($sdk, 'build', $name);
}

use KeyNub::LicDongle qw(%STATUS $SCOPE_DEVICE $SCOPE_DEVELOPER);

my $FIXTURE_SERIAL = '0123456789ABCDEFEE';

# --- version and no hardware ------------------------------------------------

my ($major, $minor, $patch) = KeyNub::LicDongle::library_version();
ok($major >= 0 && $minor >= 0 && $patch >= 0, 'library version is reported');

# No assertion on the count: this is the real hidapi path, so it depends on what is
# plugged into the machine running the suite. Asserting 0 made this suite fail on a bench
# with a dongle attached -- a test bug, not a finding.
my $count = KeyNub::LicDongle::device_count();
ok($count >= 0, 'device_count succeeds');

# Opening with no dongle is a status, not a crash -- checked only when there is genuinely
# nothing to find. CI has no hardware, which is where this path gates.
# $err is declared at file scope because the rest of this suite reuses it.
my $err;
if ($count == 0) {
    $err = do { local $@; eval { KeyNub::LicDongle->open }; $@ };
    isa_ok($err, 'KeyNub::LicDongle::Error', 'opening with no dongle dies with an Error');
    is($err->status, $STATUS{NO_DEVICE}, '... carrying NO_DEVICE');
    like("$err", qr/licdf_open/, '... and stringifying usefully');
}

# --- info, serial, genuine --------------------------------------------------

my $dongle = KeyNub::LicDongle->open_simulated;
isa_ok($dongle, 'KeyNub::LicDongle', 'open_simulated');

is($dongle->serial, $FIXTURE_SERIAL, 'serial matches the fixture');

my $info = $dongle->info;
is($info->{protocol_version}[0], 1, 'protocol v1');
is($info->{se_ready}, 1, 'secure element ready');
is($info->{provisioned}, 1, 'provisioned');
is($info->{data_capacity}, 1024 * 1024, 'capacity is 1 MiB');
# A healthy boot. Reading this as 1 would mean the flags word was misinterpreted.
is($info->{watchdog_reboot}, 0, 'no watchdog reboot on a healthy boot');
is(scalar @{ $info->{firmware_version} }, 3, 'firmware version has three parts');

my $genuine = $dongle->verify_genuine;
is($genuine->{genuine}, 1, 'the fixture dongle is genuine');
is($genuine->{serial}, $FIXTURE_SERIAL, 'certificate serial');
ok($dongle->is_genuine, 'is_genuine is true');

# Replacing the fixture root with a bogus one must make the same device fail:
# that proves set_trust_root marshals AND is actually consulted.
$dongle->set_trust_root("\x30\x82\x01\x00" . ("\xAB" x 128));
$err = do { local $@; eval { $dongle->verify_genuine }; $@ };
isa_ok($err, 'KeyNub::LicDongle::Error', 'a bogus root rejects the dongle');
is($err->status, $STATUS{CERTIFICATE_INVALID}, '... with CERTIFICATE_INVALID');
ok(!$dongle->is_genuine, 'is_genuine fails closed');

$err = do { local $@; eval { $dongle->set_trust_root('') }; $@ };
isa_ok($err, 'KeyNub::LicDongle::Error', 'an empty trust root is rejected');

$dongle->close;
$dongle->close;    # idempotent

# --- records, counters, app-crypto ------------------------------------------

$dongle = KeyNub::LicDongle->open_simulated;

# Record calls need a session.
$err = do { local $@; eval { $dongle->records }; $@ };
like($err, qr/no session/, 'record access without a session is refused');

$dongle->session_open;

my $payload = 'license-blob-0123456789';

# Writes need the write role, and the status says which.
$err = do { local $@; eval { $dongle->write_record('lic', $payload) }; $@ };
is($err->status, $STATUS{AUTH_REQUIRED}, 'a write without the role is refused');

# The fixture developer key comes from the simulator library itself.
{
    my $ffi = KeyNub::LicDongle::_ffi();
    $ffi->attach(licd_test_get_master_key_der => ['opaque*','sint32*'] => 'void');
    my ($ptr, $len) = (undef, 0);
    licd_test_get_master_key_der(\$ptr, \$len);
    # buffer_to_scalar copies $len bytes out of a raw pointer; the fixture data is
    # static in the library, so there is nothing to free.
    my $key = FFI::Platypus::Buffer::buffer_to_scalar($ptr, $len);
    $dongle->authorize_write($key);
    pass('authorize_write with the fixture key');
}

$dongle->write_record('lic', $payload);
is($dongle->read_record('lic'), $payload, 'record round-trips');
is(length($dongle->read_record('lic')), length($payload), 'record length round-trips');

$dongle->write_record('cfg', 'cfgdata');
my $records = $dongle->records;
is(scalar @$records, 2, 'two records listed');
is_deeply([ sort map { $_->{name} } @$records ], [ 'cfg', 'lic' ], 'record names');
my ($lic) = grep { $_->{name} eq 'lic' } @$records;
is($lic->{size}, length($payload), 'record size');

$err = do { local $@; eval { $dongle->read_record('nope') }; $@ };
is($err->status, $STATUS{NOT_FOUND}, 'a missing record reports NOT_FOUND');

# An empty name must not fall through to "erase everything".
$err = do { local $@; eval { $dongle->erase_record('') }; $@ };
like($err, qr/erase_all_records/, 'an empty erase name is refused');
is(scalar @{ $dongle->records }, 2, 'nothing was erased');

$dongle->erase_record('cfg');
is(scalar @{ $dongle->records }, 1, 'one record after erase');

my $before = $dongle->read_counter(0);
my $after  = $dongle->increment_counter(0);
is($after, $before + 1, 'the counter advanced by one');

my $secret = join '', map { chr(($_ * 3 + 7) % 256) } 0 .. 99;
for my $scope ($SCOPE_DEVICE, $SCOPE_DEVELOPER) {
    my $blob = $dongle->app_encrypt($scope, $secret);
    ok(length($blob) > length($secret), "envelope is larger than the plaintext (scope $scope)");
    ok(index($blob, $secret) < 0, "plaintext is not in the blob (scope $scope)");
    is($dongle->app_decrypt($blob), $secret, "app-crypto round trip (scope $scope)");

    # Tampering is rejected rather than yielding different plaintext.
    my $tampered = $blob;
    substr($tampered, -1, 1) = chr(ord(substr($tampered, -1, 1)) ^ 1);
    $err = do { local $@; eval { $dongle->app_decrypt($tampered) }; $@ };
    isa_ok($err, 'KeyNub::LicDongle::Error', "a tampered envelope is rejected (scope $scope)");
}

$err = do { local $@; eval { $dongle->app_encrypt(7, $secret) }; $@ };
like($err, qr/scope must be/, 'an unknown scope is refused');

$dongle->erase_all_records;
is(scalar @{ $dongle->records }, 0, 'all records erased');

# An empty record round-trips as an empty string.
$dongle->write_record('empty', '');
is($dongle->read_record('empty'), '', 'an empty record round-trips');

$dongle->session_close;
$dongle->session_close;    # idempotent
$err = do { local $@; eval { $dongle->records }; $@ };
like($err, qr/no session/, 'a closed session refuses use');

$dongle->close;
$err = do { local $@; eval { $dongle->serial }; $@ };
like($err, qr/closed/, 'a closed dongle refuses use');

done_testing();
