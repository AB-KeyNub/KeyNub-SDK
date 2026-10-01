use v6.d;
# Every call of the binding against a stand-in for the flat C API: the SDK's
# flat layer compiled together with the C ABI stand-in
# (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
# into one shared library, with a C compiler from the path (cc, gcc, clang,
# zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
# stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the
# test does not run inside a clone. Exit code 0 when every check passed.
#
#     raku -I bindings/raku/lib bindings/raku/test/standin_test.raku      (from the SDK root)
use KeyNub::LicDongle;

my constant LD = KeyNub::LicDongle;
my constant Status = KeyNub::LicDongle::Status;
my constant Scope = KeyNub::LicDongle::Scope;
my constant Dongle = KeyNub::LicDongle::Dongle;

my constant SERIAL = '04A1B2C3D4E5F6';
my constant FACTORY-KEY = buf8.new(0x30, 0x10, 0x01, 0x02, 0x03);
my constant REPLACEMENT-KEY = buf8.new(0x30, 0x11, 0x09, 0x08, 0x07, 0x06);

my $failures = 0;

sub check($condition, Str $what) {
    return if $condition;
    $failures++;
    say "  FAIL  $what";
}

sub fails($status, Str $what, &block) {
    block();
    check(False, "$what: no failure");
    CATCH {
        when X::KeyNub::LicDongle {
            check(.status === $status, "$what: {LD::status-name(.code)}");
        }
    }
}

sub bytes(Str $text --> Buf) { buf8.new($text.encode('utf8')) }

sub same(Blob $a, Blob $b --> Bool) { $a.elems == $b.elems && $a.list eqv $b.list }

# ---- the stand-in ----------------------------------------------------------

sub sdk-root(--> IO::Path) {
    with %*ENV<KEYNUB_SDK_ROOT> -> $given {
        return $given.IO if $given;
    }
    my $dir = $*CWD;
    loop {
        return $dir if $dir.add('bindings').add('flat').add('licd_flat.c').f;
        my $parent = $dir.parent;
        last if $parent.absolute eq $dir.absolute;
        $dir = $parent;
    }
    say 'the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT';
    exit 1;
}

sub build-stand-in(--> Str) {
    my $root = sdk-root();
    my $windows = $*DISTRO.is-win;
    my $tmp = $*TMPDIR;
    # A file name of its own, apart from the real library's.
    my $output = $tmp.add($windows ?? 'keynub_flat_standin.dll' !! 'libkeynub_flat_standin.so').absolute;
    my $include-dir = $root.add('core').add('include').add('licdongle.h').f
        ?? $root.add('core').add('include').absolute
        !! $root.add('include').absolute;
    my $flat-dir = $root.add('bindings').add('flat').absolute;
    my @sources = $root.add('bindings').add('flat').add('licd_flat.c').absolute,
        $root.add('bindings').add('julia').add('test').add('stub').add('licd_stub.c').absolute;
    my @gcc-args = '-shared', '-O1', '-DLICD_BUILD_SHARED', '-DLICDF_BUILD_SHARED',
        "-I$include-dir", "-I$flat-dir", '-o', $output, |@sources;
    @gcc-args.push: '-fPIC' unless $windows;
    my @cl-args = '/nologo', '/LD', '/O1', '/DLICD_BUILD_SHARED', '/DLICDF_BUILD_SHARED',
        "/I$include-dir", "/I$flat-dir", "/Fe:$output", |@sources;
    my @commands = ('cc', |@gcc-args), ('gcc', |@gcc-args), ('clang', |@gcc-args),
        ('zig', 'cc', |@gcc-args), ('cl', |@cl-args);
    for @commands -> @command {
        my $built = try {
            my $proc = run |@command, :cwd($tmp), :out, :err;
            $proc.out.slurp(:close);
            $proc.err.slurp(:close);
            $proc.exitcode == 0
        };
        return $output if $built && $output.IO.f;
    }
    say 'the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path';
    exit 1;
}

sub stand-in(--> Str) {
    with %*ENV{LD::LIBRARY-ENVIRONMENT-VARIABLE} -> $given {
        return $given if $given;
    }
    build-stand-in()
}

# ---- the checks -------------------------------------------------------------

LD::library-path(stand-in());

check(LD::library-version() eqv v9.8.7, 'library version');
check(LD::status-text(-2) eq 'no device', 'status text');

my @devices = LD::devices();
check(@devices.elems == 1 && @devices[0].serial eq SERIAL && @devices[0].path eq 'stub:0', 'devices');
fails(Status::NoDevice, 'open by unknown serial', { Dongle.open('nope') });
fails(Status::NoDevice, 'open by unknown path', { Dongle.open-path('stub:9') });

my $d = Dongle.open;
check($d.is-open, 'open');
check($d.serial eq SERIAL, 'serial');
my $i = $d.info;
check($i.protocol-major == 1 && $i.protocol-minor == 0, 'protocol version');
check($i.firmware-major == 2 && $i.firmware-minor == 3 && $i.firmware-patch == 4, 'firmware version');
check($i.secure-element-ready && $i.provisioned && $i.isolated, 'flags set');
check(!$i.watchdog-reboot && !$i.write-auth-rotated, 'flags clear');
check($i.data-capacity == 1024 * 1024 && $i.data-free == 1_000_000, 'capacity');
my $g = $d.verify-genuine;
check($g.serial eq SERIAL && $g.provisioned-date eq '2026-08-15', 'genuine');
check($d.genuine, 'genuine');

fails(Status::CertInvalid, 'malformed trust root', { $d.trust-root = buf8.new(0x02, 0x01, 0x00) });
my $root = buf8.new(0xAB xx 132);
$root[0] = 0x30;
$root[1] = 0x82;
$root[2] = 0x01;
$root[3] = 0x00;
$d.trust-root = $root;
fails(Status::CertInvalid, 'verify against a foreign root', { $d.verify-genuine });
check(!$d.genuine, 'genuine fails closed');
$root[$_] = 0x01 for 4 ..^ $root.elems;
$d.trust-root = $root;
check($d.genuine, 'genuine after the right root');

fails(Status::SessionExpired, 'records without a session', { $d.records });
$d.session-open;
my $payload = bytes('license-blob-0123456789');
fails(Status::AuthRequired, 'write before the write role', { $d.write-record('lic', $payload) });
fails(Status::NotGenuine, 'write role with a bad key', { $d.authorize-write(buf8.new(0x30, 0x00)) });
$d.authorize-write(FACTORY-KEY);
$d.write-record('lic', $payload);
check(same($d.read-record('lic'), $payload), 'read back');
$d.write-record('cfg', bytes('cfgdata'));
my @recs = $d.records;
check(@recs.map(*.name).sort.List eqv <cfg lic>, 'record names');
check(@recs.first({ .name eq 'lic' && .size == $payload.elems }).defined, 'record size');
check(same($d.read-record('cfg'), bytes('cfgdata')), 'second record');
fails(Status::NotFound, 'read a missing record', { $d.read-record('nope') });
fails(Status::InvalidArg, 'erase with an empty name', { $d.erase-record('') });
check($d.records.elems == 2, 'two records');
$d.erase-record('cfg');
check($d.records.map(*.name).List eqv ('lic',), 'one record left');
$d.write-record('empty', buf8.new);
check($d.read-record('empty').elems == 0, 'empty record');

my $before = $d.read-counter(0);
check($d.increment-counter(0) == $before + 1, 'increment');
check($d.read-counter(0) == $before + 1 && $d.read-counter(1) == 0, 'counters');
fails(Status::Range, 'counter out of range', { $d.read-counter(7) });

my $secret = buf8.new((^100).map({ (3 * $_ + 7) % 256 }));
for Scope::Device, Scope::Developer -> $scope {
    my $blob = $d.app-encrypt($scope, $secret);
    check($blob.elems > $secret.elems, "sealed data is longer, $scope");
    check($blob[0] == $scope.value, "scope byte, $scope");
    check(same($d.app-decrypt($blob), $secret), "round trip, $scope");
    my $tampered = buf8.new($blob);
    $tampered[*-1] +^= 1;
    fails(Status::TagMismatch, "tampered blob, $scope", { $d.app-decrypt($tampered) });
}

$d.erase-all-records;
check($d.records.elems == 0, 'erase all');

$d.rotate-write-key(REPLACEMENT-KEY);
$d.write-record('lic', bytes('still-writable'));
$d.session-close;
check($d.info.write-auth-rotated, 'rotated flag');
$d.session-open;
fails(Status::NotGenuine, 'factory key after rotation', { $d.authorize-write(FACTORY-KEY) });
$d.authorize-write(REPLACEMENT-KEY);
$d.write-record('lic', bytes('new-key-writes'));
check(same($d.read-record('lic'), bytes('new-key-writes')), 'write with the new key');
$d.session-close;
$d.close;
check(!$d.is-open, 'closed');
fails(Status::InvalidArg, 'serial after close', { $d.serial });

my $via-block = LD::open(-> $dd { $dd.serial });
check($via-block eq SERIAL, 'open with a block');
# records needs a session, so a value back proves session opened one.
my $count = Dongle.open(SERIAL, -> $dd { $dd.session({ $dd.records.elems }) });
check($count >= 0, 'session with a block');
my $closed = Dongle.open(-> $dd { $dd });
check(!$closed.is-open, 'closed after the block');
check(LD::loaded-library-path() eq LD::library-path(), 'loaded path');

if $failures > 0 {
    say "$failures check(s) failed";
    exit 1;
}
say 'keynub_licdongle: every call passed against the ABI stand-in';
