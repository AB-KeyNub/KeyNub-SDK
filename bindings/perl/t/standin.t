#!/usr/bin/env perl
# Every call of the binding against a stand-in for the flat C API: the SDK's
# flat layer compiled together with the C ABI stand-in
# (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
# into one shared library, with a C compiler from the path (cc, gcc, clang,
# zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
# stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the test
# does not run inside a clone.
#
#     prove -l t/standin.t        (from bindings/perl)

use strict;
use warnings;
use Test::More;
use Cwd ();
use File::Spec;

# ---- the stand-in -------------------------------------------------------------

sub sdk_root {
    return $ENV{KEYNUB_SDK_ROOT} if defined $ENV{KEYNUB_SDK_ROOT} && length $ENV{KEYNUB_SDK_ROOT};
    my $dir = Cwd::getcwd();
    while (1) {
        return $dir if -f File::Spec->catfile($dir, 'bindings', 'flat', 'licd_flat.c');
        my $parent = File::Spec->catdir($dir, File::Spec->updir);
        $parent = Cwd::abs_path($parent);
        last if !defined $parent || $parent eq $dir;
        $dir = $parent;
    }
    BAIL_OUT('the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT');
}

sub build_stand_in {
    my $root = sdk_root();
    my $windows = $^O eq 'MSWin32';
    my $tmp = File::Spec->tmpdir;
    # Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf
    # name even for an absolute-path dlopen, and a build tree on that path holds
    # the real library under that name.
    my $output = File::Spec->catfile($tmp, $windows ? 'keynub_flat_standin.dll' : 'libkeynub_flat_standin.so');
    my $include = File::Spec->catdir($root, 'core', 'include');
    $include = File::Spec->catdir($root, 'include') unless -f File::Spec->catfile($include, 'licdongle.h');
    my $flat = File::Spec->catdir($root, 'bindings', 'flat');
    my @sources = (File::Spec->catfile($flat, 'licd_flat.c'),
                   File::Spec->catfile($root, 'bindings', 'julia', 'test', 'stub', 'licd_stub.c'));
    my @gcc = ('-shared', '-O1', '-DLICD_BUILD_SHARED', '-DLICDF_BUILD_SHARED', "-I$include", "-I$flat",
               '-o', $output, @sources, $windows ? () : ('-fPIC'));
    my @cl = ('/nologo', '/LD', '/O1', '/DLICD_BUILD_SHARED', '/DLICDF_BUILD_SHARED', "/I$include", "/I$flat",
              "/Fe:$output", @sources);
    # In the temporary folder, where the compilers leave their byproducts.
    my $here = Cwd::getcwd();
    chdir $tmp or BAIL_OUT("cannot change to $tmp: $!");
    my $built;
    for my $command (['cc', @gcc], ['gcc', @gcc], ['clang', @gcc], ['zig', 'cc', @gcc], ['cl', @cl]) {
        open my $saved_out, '>&', \*STDOUT or die;
        open my $saved_err, '>&', \*STDERR or die;
        open STDOUT, '>', File::Spec->devnull or die;
        open STDERR, '>', File::Spec->devnull or die;
        my $status = system { $command->[0] } @$command;
        open STDOUT, '>&', $saved_out or die;
        open STDERR, '>&', $saved_err or die;
        if ($status == 0 && -f $output) {
            $built = $output;
            last;
        }
    }
    chdir $here;
    BAIL_OUT('the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path')
        unless $built;
    return $built;
}

BEGIN {
    # The library is loaded on the binding's first call, once per process.
    $ENV{KEYNUB_LICDONGLE_FLAT_LIBRARY} = build_stand_in()
        unless defined $ENV{KEYNUB_LICDONGLE_FLAT_LIBRARY} && length $ENV{KEYNUB_LICDONGLE_FLAT_LIBRARY};
}

use KeyNub::LicDongle qw(
    %STATUS $FLAG_SE_READY $FLAG_PROVISIONED $FLAG_WATCHDOG_REBOOT $FLAG_ISOLATED
    $FLAG_WRITEAUTH_ROTATED $SCOPE_DEVICE $SCOPE_DEVELOPER
);

# ---- the checks ------------------------------------------------------------------

my $SERIAL = '04A1B2C3D4E5F6';
my $FACTORY_KEY = pack 'C*', 0x30, 0x10, 0x01, 0x02, 0x03;
my $REPLACEMENT_KEY = pack 'C*', 0x30, 0x11, 0x09, 0x08, 0x07, 0x06;

# The error $action dies with, or undef when it does not die.
sub error_of {
    my ($action) = @_;
    local $@;
    return eval { $action->(); 1 } ? undef : $@;
}

# Checks that $action dies with a binding error carrying $status.
sub fails_with {
    my ($status, $what, $action) = @_;
    my $err = error_of($action);
    ok(ref $err && $err->isa('KeyNub::LicDongle::Error') && $err->status == $status, $what)
        or diag(defined $err ? "got: $err" : 'no failure');
    return $err;
}

# Checks that $action croaks with a message matching $pattern.
sub croaks_like {
    my ($pattern, $what, $action) = @_;
    my $err = error_of($action);
    ok(defined $err && !ref $err && $err =~ $pattern, $what) or diag(defined $err ? "got: $err" : 'no failure');
}

is_deeply([ KeyNub::LicDongle::library_version() ], [ 9, 8, 7 ], 'library version');
is($STATUS{NO_DEVICE}, -2, 'status code');

my $err = fails_with($STATUS{NO_DEVICE}, 'open by unknown serial', sub { KeyNub::LicDongle->open('nope') });
is($err->message, 'no device', 'status text');
is($err->operation, 'licdf_open', 'error operation');
is("$err", "licdf_open: no device\n", 'error text');

is(KeyNub::LicDongle::device_count(), 1, 'device count');
is(KeyNub::LicDongle::device_serial(0), $SERIAL, 'device serial');

my $d = KeyNub::LicDongle->open;
isa_ok($d, 'KeyNub::LicDongle', 'open');
is($d->serial, $SERIAL, 'serial');
my $by_serial = KeyNub::LicDongle->open($SERIAL);
is($by_serial->serial, $SERIAL, 'open by serial');
$by_serial->close;

is_deeply($d->info, {
    protocol_version  => [ 1, 0 ],
    firmware_version  => [ 2, 3, 4 ],
    se_ready          => 1,
    provisioned       => 1,
    watchdog_reboot   => 0,
    isolated          => 1,
    writeauth_rotated => 0,
    data_capacity     => 1024 * 1024,
    data_free         => 1_000_000,
}, 'info fields and flags');
is($FLAG_SE_READY | $FLAG_PROVISIONED | $FLAG_WATCHDOG_REBOOT | $FLAG_ISOLATED | $FLAG_WRITEAUTH_ROTATED, 0x1F,
   'flag bits');

is_deeply($d->verify_genuine, { genuine => 1, serial => $SERIAL, provisioned_date => '2026-08-15' }, 'genuine');
is($d->is_genuine, 1, 'is_genuine');
fails_with($STATUS{CERTIFICATE_INVALID}, 'malformed trust root', sub { $d->set_trust_root(pack 'C*', 0x02, 0x01, 0x00) });
fails_with($STATUS{INVALID_ARGUMENT}, 'empty trust root', sub { $d->set_trust_root('') });
$d->set_trust_root(pack('C*', 0x30, 0x82, 0x01, 0x00) . ("\xAB" x 128));
fails_with($STATUS{CERTIFICATE_INVALID}, 'verify against a foreign root', sub { $d->verify_genuine });
is($d->is_genuine, 0, 'is_genuine fails closed');
$d->set_trust_root(pack('C*', 0x30, 0x82, 0x01, 0x00) . ("\x01" x 128));
is($d->is_genuine, 1, 'is_genuine after the right root');

croaks_like(qr/no session/, 'records without a session', sub { $d->records });
$d->session_open;
my $payload = 'license-blob-0123456789';
fails_with($STATUS{AUTH_REQUIRED}, 'write before the write role', sub { $d->write_record('lic', $payload) });
fails_with($STATUS{AUTH_REQUIRED}, 'increment before the write role', sub { $d->increment_counter(0) });
fails_with($STATUS{NOT_GENUINE}, 'write role with a bad key', sub { $d->authorize_write(pack 'C*', 0x30, 0x00) });
$d->authorize_write($FACTORY_KEY);

$d->write_record('lic', $payload);
is($d->read_record('lic'), $payload, 'read back');
$d->write_record('cfg', 'cfgdata');
my $recs = $d->records;
is_deeply([ sort map { $_->{name} } @$recs ], [ 'cfg', 'lic' ], 'record names');
ok((grep { $_->{name} eq 'lic' && $_->{size} == length $payload } @$recs), 'record size');
is($d->read_record('cfg'), 'cfgdata', 'second record');
$err = fails_with($STATUS{NOT_FOUND}, 'read a missing record', sub { $d->read_record('nope') });
is($err->detail, 'no such record', 'error detail');
is($d->last_error_detail, 'no such record', 'last error detail');
fails_with($STATUS{NOT_FOUND}, 'erase a missing record', sub { $d->erase_record('nope') });
croaks_like(qr/erase_all_records/, 'erase with an empty name', sub { $d->erase_record('') });
croaks_like(qr/must not be empty/, 'read with an empty name', sub { $d->read_record('') });
croaks_like(qr/must not be empty/, 'write with an empty name', sub { $d->write_record('', 'x') });
is(scalar @{ $d->records }, 2, 'two records');
$d->erase_record('cfg');
is_deeply([ map { $_->{name} } @{ $d->records } ], [ 'lic' ], 'one record left');
$d->write_record('empty', '');
is($d->read_record('empty'), '', 'empty record');
my $big = join '', map { chr(($_ * 31 + 5) % 256) } 0 .. 1999;
$d->write_record('big', $big);
is($d->read_record('big'), $big, 'record larger than the first buffer');

my $before = $d->read_counter(0);
is($d->increment_counter(0), $before + 1, 'increment');
is($d->read_counter(0), $before + 1, 'counter 0');
is($d->read_counter(1), 0, 'counter 1');
fails_with($STATUS{RANGE}, 'counter out of range', sub { $d->read_counter(7) });
fails_with($STATUS{RANGE}, 'increment out of range', sub { $d->increment_counter(7) });

my $secret = join '', map { chr((3 * $_ + 7) % 256) } 0 .. 99;
for my $scope ($SCOPE_DEVICE, $SCOPE_DEVELOPER) {
    my $blob = $d->app_encrypt($scope, $secret);
    ok(length($blob) > length($secret), "sealed data is longer, scope $scope");
    is(ord(substr $blob, 0, 1), $scope, "scope byte, scope $scope");
    is($d->app_decrypt($blob), $secret, "round trip, scope $scope");
    my $tampered = $blob;
    substr($tampered, -1, 1) = chr(ord(substr($tampered, -1, 1)) ^ 1);
    fails_with($STATUS{TAG_MISMATCH}, "tampered blob, scope $scope", sub { $d->app_decrypt($tampered) });
}
croaks_like(qr/scope must be/, 'unknown scope', sub { $d->app_encrypt(7, $secret) });
is($d->app_decrypt($d->app_encrypt($SCOPE_DEVICE, '')), '', 'empty plaintext');
fails_with($STATUS{INVALID_ARGUMENT}, 'short blob', sub { $d->app_decrypt("\x00\x01") });

$d->erase_all_records;
is(scalar @{ $d->records }, 0, 'erase all');

$d->session_close;
$d->session_open;
fails_with($STATUS{AUTH_REQUIRED}, 'rotate before the write role', sub { $d->rotate_write_key($REPLACEMENT_KEY) });
$d->authorize_write($FACTORY_KEY);
$d->rotate_write_key($REPLACEMENT_KEY);
$d->write_record('lic', 'still-writable');
$d->session_close;
is($d->info->{writeauth_rotated}, 1, 'rotated flag');
$d->session_open;
fails_with($STATUS{NOT_GENUINE}, 'factory key after rotation', sub { $d->authorize_write($FACTORY_KEY) });
$d->authorize_write($REPLACEMENT_KEY);
$d->write_record('lic', 'new-key-writes');
is($d->read_record('lic'), 'new-key-writes', 'write with the new key');
$d->session_close;
$d->session_close;    # idempotent
croaks_like(qr/no session/, 'a closed session refuses use', sub { $d->records });

$d->close;
$d->close;            # idempotent
croaks_like(qr/closed/, 'serial after close', sub { $d->serial });

# The library holds 32 handles at a time, so this loop succeeds only when
# DESTROY releases each handle as its object goes out of scope.
my $opened = 0;
for (1 .. 40) {
    my $scoped = KeyNub::LicDongle->open;
    $opened++ if $scoped->serial eq $SERIAL;
}
is($opened, 40, 'DESTROY releases the handle');

done_testing();
