use v6.d;
use NativeCall;
use KeyNub::LicDongle::Flat;
use KeyNub::LicDongle::Library;

# KeyNub License Dongle: verify that a dongle is genuine, read and write the
# license records it holds, use its hardware counters and encrypt data so that
# only a dongle can decrypt it. Calls the SDK's flat C API through NativeCall,
# with the native library loaded at run time; nothing is compiled.

my package Enums {
    #| The SDK's status codes (licd_status).
    our enum Status (
        Ok                   =>   0,
        InvalidArg           =>  -1,
        NoDevice             =>  -2,
        AccessDenied         =>  -3,
        Io                   =>  -4,
        Timeout              =>  -5,
        Protocol             =>  -6,
        NotGenuine           =>  -7,
        CertInvalid          =>  -8,
        SessionExpired       =>  -9,
        TagMismatch          => -10,
        Range                => -11,
        StorageFull          => -12,
        Busy                 => -13,
        NotFound             => -14,
        AuthRequired         => -15,
        FirmwareIncompatible => -16,
        SdkTooOld            => -17,
        Cancelled            => -18,
        NotImplemented       => -19,
        Internal             => -20,
    );

    #| Who can decrypt data sealed with Dongle.app-encrypt: this dongle only
    #| (Device), or any dongle issued by the same developer (Developer).
    our enum Scope (Device => 0, Developer => 1);
}

#| A failed dongle call: the status (an undefined Status for a code this
#| binding does not know), the raw code, the operation (the flat API function)
#| and the library's detail text, which may be empty.
class X::KeyNub::LicDongle is Exception {
    has Str $.operation is required;
    has Int $.code is required;
    has Str $.detail = '';

    method status() { Enums::Status.^enum_from_value($!code) // Enums::Status }

    method message(--> Str) {
        my $status = self.status;
        my $text = "$!operation: {$status.defined ?? $status.key !! 'Unknown'} ($!code)";
        $text ~= ": $!detail" if $!detail;
        $text
    }
}

#| The native library could not be loaded, or does not fit.
class X::KeyNub::LicDongle::Library is Exception {
    has Str $.reason is required;

    method message(--> Str) { $!reason }
}

module KeyNub::LicDongle {
    our constant VERSION = '1.1.1';

    our constant Status = Enums::Status;
    our constant Scope = Enums::Scope;

    #| The environment variable that names the library file.
    our constant LIBRARY-ENVIRONMENT-VARIABLE = KeyNub::LicDongle::Library::ENVIRONMENT-VARIABLE;

    #| The name of a status code; "Unknown" for one this binding does not know.
    our sub status-name(Int:D $code --> Str) {
        my $status = Status.^enum_from_value($code);
        $status.defined ?? $status.key !! 'Unknown'
    }

    #| An attached dongle.
    class Device {
        has Str $.serial;
        has Str $.path;
    }

    #| Plaintext device information. watchdog-reboot: the previous boot ended in
    #| a watchdog reset. write-auth-rotated: the write-auth key has been rotated
    #| away from the factory one.
    class Info {
        has Int $.protocol-major;
        has Int $.protocol-minor;
        has Int $.firmware-major;
        has Int $.firmware-minor;
        has Int $.firmware-patch;
        has Bool $.secure-element-ready;
        has Bool $.provisioned;
        has Bool $.watchdog-reboot;
        has Bool $.isolated;
        has Bool $.write-auth-rotated;
        has Int $.data-capacity;
        has Int $.data-free;
    }

    #| The result of a successful Dongle.verify-genuine. provisioned-date is
    #| "YYYY-MM-DD", or empty when the dongle reports none; informational.
    class Genuine {
        has Str $.serial;
        has Str $.provisioned-date;
    }

    #| A record on the dongle.
    class Record {
        has Str $.name;
        has Int $.size;
    }

    # ---- the library -------------------------------------------------------

    my $lock = Lock.new;
    my Str $chosen-path;
    my Str $loaded-path;

    #| With a path: names the library file to load. Call it before the first
    #| dongle call; a process loads the library once. Without one: the path in
    #| use, or the first candidate when nothing is loaded yet.
    our proto sub library-path(|) {*}

    multi sub library-path(Str:D $path --> Str) {
        $lock.protect: {
            if $loaded-path.defined && $loaded-path ne $path {
                X::KeyNub::LicDongle::Library.new(
                    reason => "the KeyNub library is already loaded from $loaded-path; a process loads it once"
                ).throw;
            }
            $chosen-path = $path;
        }
    }

    multi sub library-path(--> Str) {
        $lock.protect: { $loaded-path // library-candidates()[0] }
    }

    #| The path of the loaded library; an undefined Str before the first call.
    our sub loaded-library-path(--> Str) {
        $lock.protect: { $loaded-path }
    }

    #| The library's file name on this operating system.
    our sub library-basename(--> Str) { KeyNub::LicDongle::Library::basename() }

    #| The paths tried, in order.
    our sub library-candidates(--> List) { KeyNub::LicDongle::Library::candidates($chosen-path) }

    #| Loads the library on the first call; dies with X::KeyNub::LicDongle::Library
    #| when no candidate loads.
    our sub load-library(--> Str) {
        $lock.protect: {
            unless $loaded-path.defined {
                my @reasons;
                for library-candidates() -> $path {
                    my $reason = KeyNub::LicDongle::Library::try-load($path);
                    if $reason eq '' {
                        $KeyNub::LicDongle::Flat::library-file = $path;
                        $loaded-path = $path;
                        last;
                    }
                    @reasons.push: "$path ($reason)";
                }
                unless $loaded-path.defined {
                    X::KeyNub::LicDongle::Library.new(
                        reason => "cannot load the KeyNub library; tried {@reasons.join(', ')}"
                    ).throw;
                }
            }
            $loaded-path
        }
    }

    # ---- helpers -----------------------------------------------------------

    #| The text of a NUL-terminated buffer.
    our sub c-string(Blob:D $buffer --> Str) {
        my $length = $buffer.first(0, :k) // $buffer.elems;
        $buffer.subbuf(0, $length).decode('utf8')
    }

    sub detail-of(Int $handle --> Str) {
        my $text = buf8.allocate(KeyNub::LicDongle::Flat::ERROR-SIZE);
        my $rc = try KeyNub::LicDongle::Flat::licdf_last_error($handle, $text, KeyNub::LicDongle::Flat::ERROR-SIZE);
        ($rc // -1) == 0 ?? (try c-string($text)) // '' !! ''
    }

    sub fail-with(Str:D $operation, Int:D $code, Str:D $detail = '') {
        X::KeyNub::LicDongle.new(:$operation, :$code, :$detail).throw;
    }

    sub check(Str:D $operation, Int $handle, Int $rc) {
        fail-with($operation, $rc, $handle > 0 ?? detail-of($handle) !! '') if $rc != 0;
    }

    my $empty = buf8.allocate(1);

    # A buffer the library can read even for empty data.
    sub pointer-of(Blob:D $data) { $data.elems ?? $data !! $empty }

    sub length-of(Blob:D $data --> Int) {
        fail-with('argument', Status::InvalidArg.value, 'more than 2 GiB of data') if $data.elems > 2**31 - 1;
        $data.elems
    }

    # ---- functions without a dongle ----------------------------------------

    #| The native library's version.
    our sub library-version(--> Version) {
        load-library();
        my int32 $major = 0;
        my int32 $minor = 0;
        my int32 $patch = 0;
        check('licdf_version', 0, KeyNub::LicDongle::Flat::licdf_version($major, $minor, $patch));
        Version.new("$major.$minor.$patch")
    }

    #| Human-readable text for a status code; needs no dongle.
    our sub status-text(Int:D $code --> Str) {
        load-library();
        my $text = buf8.allocate(KeyNub::LicDongle::Flat::ERROR-SIZE);
        return status-name($code)
            if KeyNub::LicDongle::Flat::licdf_strerror($code, $text, KeyNub::LicDongle::Flat::ERROR-SIZE) != 0;
        c-string($text)
    }

    #| The attached dongles.
    our sub devices(--> List) {
        load-library();
        my int32 $count = 0;
        check('licdf_device_count', 0, KeyNub::LicDongle::Flat::licdf_device_count($count));
        my @devices;
        for ^$count -> $i {
            my $text = buf8.allocate(KeyNub::LicDongle::Flat::PATH-SIZE);
            check('licdf_device_serial', 0,
                KeyNub::LicDongle::Flat::licdf_device_serial($i, $text, KeyNub::LicDongle::Flat::PATH-SIZE));
            my $serial = c-string($text);
            $text = buf8.allocate(KeyNub::LicDongle::Flat::PATH-SIZE);
            check('licdf_device_path', 0,
                KeyNub::LicDongle::Flat::licdf_device_path($i, $text, KeyNub::LicDongle::Flat::PATH-SIZE));
            @devices.push: Device.new(:$serial, path => c-string($text));
        }
        @devices.List
    }

    # ---- a dongle ----------------------------------------------------------

    #| An open dongle. close it, or use the block form of open, which closes it
    #| on every exit path.
    class Dongle {
        has Int $!handle;
        has $!trust-root;

        submethod BUILD(Int:D :$handle) { $!handle = $handle }

        #| Opens the dongle with this serial, or the first one found when no
        #| serial or an empty one is given.
        multi method open(Dongle:U: Str $serial = '' --> Dongle) {
            load-library();
            my $handle = KeyNub::LicDongle::Flat::licdf_open($serial // '');
            fail-with('licdf_open', $handle) if $handle < 0;
            self.bless(:$handle)
        }

        #| Opens the first dongle, passes it to the block and closes it on every
        #| exit path. Returns what the block returns.
        multi method open(Dongle:U: &block) {
            self.open('', &block)
        }

        #| Opens the dongle with this serial, passes it to the block and closes
        #| it on every exit path. Returns what the block returns.
        multi method open(Dongle:U: Str $serial, &block) {
            my $dongle = self.open($serial);
            LEAVE $dongle.close-quietly;
            block($dongle)
        }

        #| Opens the dongle at this device path (from KeyNub::LicDongle::devices).
        multi method open-path(Dongle:U: Str:D $path --> Dongle) {
            load-library();
            my $handle = KeyNub::LicDongle::Flat::licdf_open_path($path);
            fail-with('licdf_open_path', $handle) if $handle < 0;
            self.bless(:$handle)
        }

        #| Opens the dongle at this device path, passes it to the block and
        #| closes it on every exit path. Returns what the block returns.
        multi method open-path(Dongle:U: Str:D $path, &block) {
            my $dongle = self.open-path($path);
            LEAVE $dongle.close-quietly;
            block($dongle)
        }

        submethod DESTROY { self.close-quietly }

        #| Whether close has not been called yet.
        method is-open(--> Bool) { $!handle > 0 }

        #| Closes the dongle. Further calls fail with Status::InvalidArg.
        method close() {
            return if $!handle <= 0;
            my $handle = $!handle;
            $!handle = 0;
            check('licdf_close', $handle, KeyNub::LicDongle::Flat::licdf_close($handle));
            Nil
        }

        #| Closes the dongle and ignores any failure.
        method close-quietly() {
            try self.close;
            Nil
        }

        #| The dongle's serial number (14 hex digits).
        method serial(--> Str) {
            my $text = buf8.allocate(KeyNub::LicDongle::Flat::SERIAL-SIZE);
            self!check('licdf_get_serial',
                KeyNub::LicDongle::Flat::licdf_get_serial($!handle, $text, KeyNub::LicDongle::Flat::SERIAL-SIZE));
            c-string($text)
        }

        #| Plaintext device information.
        method info(--> Info) {
            my int32 $pa = 0;
            my int32 $pb = 0;
            my int32 $fa = 0;
            my int32 $fb = 0;
            my int32 $fc = 0;
            my int32 $flags = 0;
            my int32 $capacity = 0;
            my int32 $free = 0;
            self!check('licdf_get_info', KeyNub::LicDongle::Flat::licdf_get_info(
                $!handle, $pa, $pb, $fa, $fb, $fc, $flags, $capacity, $free));
            Info.new(
                protocol-major => $pa, protocol-minor => $pb,
                firmware-major => $fa, firmware-minor => $fb, firmware-patch => $fc,
                secure-element-ready => so($flags +& KeyNub::LicDongle::Flat::FLAG-SECURE-ELEMENT-READY),
                provisioned => so($flags +& KeyNub::LicDongle::Flat::FLAG-PROVISIONED),
                watchdog-reboot => so($flags +& KeyNub::LicDongle::Flat::FLAG-WATCHDOG-REBOOT),
                isolated => so($flags +& KeyNub::LicDongle::Flat::FLAG-ISOLATED),
                write-auth-rotated => so($flags +& KeyNub::LicDongle::Flat::FLAG-WRITE-AUTH-ROTATED),
                data-capacity => $capacity, data-free => $free)
        }

        #| Proves the dongle is genuine: certificate chain to the trusted root
        #| plus a live challenge-response. Returns only when it is; dies otherwise.
        method verify-genuine(--> Genuine) {
            my int32 $genuine = 0;
            my $serial = buf8.allocate(KeyNub::LicDongle::Flat::SERIAL-SIZE);
            my $date = buf8.allocate(KeyNub::LicDongle::Flat::DATE-SIZE);
            self!check('licdf_verify_genuine', KeyNub::LicDongle::Flat::licdf_verify_genuine(
                $!handle, $genuine, $serial, KeyNub::LicDongle::Flat::SERIAL-SIZE,
                $date, KeyNub::LicDongle::Flat::DATE-SIZE));
            fail-with('licdf_verify_genuine', Status::NotGenuine.value) if $genuine == 0;
            Genuine.new(serial => c-string($serial), provisioned-date => c-string($date))
        }

        #| The boolean form for a gate: True only when verify-genuine succeeds.
        #| Fails closed: every failure gives False.
        method genuine(--> Bool) {
            so try { self.verify-genuine; True }
        }

        #| The CA root (DER) that verify-genuine checks against. Assigning one
        #| overrides the root the library embeds.
        method trust-root() is rw {
            my $self = self;
            Proxy.new(
                FETCH => -> $ { $self!get-trust-root },
                STORE => -> $, Blob:D $der { $self!set-trust-root($der) })
        }

        method !get-trust-root() { $!trust-root }

        method !set-trust-root(Blob:D $der) {
            self!check('licdf_set_trust_root',
                KeyNub::LicDongle::Flat::licdf_set_trust_root($!handle, pointer-of($der), length-of($der)));
            $!trust-root = $der;
        }

        #| Opens an authenticated session; records, counters and app crypto need one.
        method session-open() {
            self!check('licdf_session_open', KeyNub::LicDongle::Flat::licdf_session_open($!handle));
            Nil
        }

        #| Closes the session.
        method session-close() {
            self!check('licdf_session_close', KeyNub::LicDongle::Flat::licdf_session_close($!handle));
            Nil
        }

        #| Opens a session, runs the block and closes the session on every exit
        #| path. Returns what the block returns.
        method session(&block) {
            self.session-open;
            LEAVE { try self.session-close }
            block()
        }

        #| Elevates the session to the write role with a write-auth key (P-256
        #| PKCS#8 DER). Belongs in licence-issuing tooling, not in the
        #| application your users run.
        method authorize-write(Blob:D $key-der) {
            self!check('licdf_write_auth',
                KeyNub::LicDongle::Flat::licdf_write_auth($!handle, pointer-of($key-der), length-of($key-der)));
            Nil
        }

        #| Replaces the dongle's write-auth key with $key-der (P-256 PKCS#8 DER).
        #| Call authorize-write first. From the next session on, only the new
        #| key elevates.
        method rotate-write-key(Blob:D $key-der) {
            self!check('licdf_write_auth_rotate',
                KeyNub::LicDongle::Flat::licdf_write_auth_rotate($!handle, pointer-of($key-der), length-of($key-der)));
            Nil
        }

        #| The records on the dongle.
        method records(--> List) {
            my int32 $count = 0;
            self!check('licdf_record_count', KeyNub::LicDongle::Flat::licdf_record_count($!handle, $count));
            my @records;
            for ^$count -> $i {
                my $text = buf8.allocate(KeyNub::LicDongle::Flat::NAME-SIZE);
                my int32 $size = 0;
                self!check('licdf_record_name', KeyNub::LicDongle::Flat::licdf_record_name(
                    $!handle, $i, $text, KeyNub::LicDongle::Flat::NAME-SIZE, $size));
                @records.push: Record.new(name => c-string($text), size => $size);
            }
            @records.List
        }

        #| The content of a record.
        method read-record(Str:D $name --> Buf) {
            my $handle = $!handle;
            self!read-bytes('licdf_record_read', -> $data, $capacity, $length {
                KeyNub::LicDongle::Flat::licdf_record_read($handle, $name, $data, $capacity, $length)
            })
        }

        #| Writes a record, replacing one of the same name. Needs the write role.
        method write-record(Str:D $name, Blob:D $data) {
            self!check('licdf_record_write', KeyNub::LicDongle::Flat::licdf_record_write(
                $!handle, $name, pointer-of($data), length-of($data)));
            Nil
        }

        #| Erases one record. Needs the write role.
        method erase-record(Str:D $name) {
            self!check('licdf_record_erase', KeyNub::LicDongle::Flat::licdf_record_erase($!handle, $name));
            Nil
        }

        #| Erases every record. Separate from erase-record so that an
        #| accidentally empty name cannot wipe the dongle.
        method erase-all-records() {
            self!check('licdf_record_erase_all', KeyNub::LicDongle::Flat::licdf_record_erase_all($!handle));
            Nil
        }

        #| The value of a hardware monotonic counter.
        method read-counter(Int:D $counter-id --> Int) {
            my int32 $value = 0;
            self!check('licdf_counter_read',
                KeyNub::LicDongle::Flat::licdf_counter_read($!handle, $counter-id, $value));
            $value
        }

        #| Increments a counter and returns the new value. Needs the write role.
        method increment-counter(Int:D $counter-id --> Int) {
            my int32 $value = 0;
            self!check('licdf_counter_increment',
                KeyNub::LicDongle::Flat::licdf_counter_increment($!handle, $counter-id, $value));
            $value
        }

        #| Seals data so that only a dongle can open it: this one (Scope::Device)
        #| or any dongle issued by the same developer (Scope::Developer). Build
        #| the licence check on this pair: put something the program needs
        #| through it, so removing the check removes the data.
        method app-encrypt(Scope:D $scope, Blob:D $plaintext --> Buf) {
            my $handle = $!handle;
            my $source = pointer-of($plaintext);
            my $size = length-of($plaintext);
            self!read-bytes('licdf_app_encrypt', -> $data, $capacity, $length {
                KeyNub::LicDongle::Flat::licdf_app_encrypt($handle, $scope.value, $source, $size,
                    $data, $capacity, $length)
            })
        }

        #| Opens data sealed with app-encrypt.
        method app-decrypt(Blob:D $packed --> Buf) {
            my $handle = $!handle;
            my $source = pointer-of($packed);
            my $size = length-of($packed);
            self!read-bytes('licdf_app_decrypt', -> $data, $capacity, $length {
                KeyNub::LicDongle::Flat::licdf_app_decrypt($handle, $source, $size, $data, $capacity, $length)
            })
        }

        #| Diagnostic detail for the most recent failure on this dongle; may be empty.
        method last-error-detail(--> Str) { detail-of($!handle) }

        method !check(Str:D $operation, Int $rc) { check($operation, $!handle, $rc) }

        # The two-call convention: ask for the size, then read into a buffer of it.
        method !read-bytes(Str:D $operation, &call --> Buf) {
            my $needed = CArray[int32].new(0);
            my $rc = call(buf8.allocate(1), 0, $needed);
            return buf8.new if $rc == 0;
            fail-with($operation, $rc, self.last-error-detail) if $rc != Status::Range.value;
            my $data = buf8.allocate($needed[0] max 1);
            my $length = CArray[int32].new(0);
            $rc = call($data, $needed[0], $length);
            fail-with($operation, $rc, self.last-error-detail) if $rc != 0;
            $data.subbuf(0, $length[0])
        }
    }

    #| Opens the first dongle (or the one with $serial), passes it to the block
    #| and closes it on every exit path. Returns what the block returns.
    our proto sub open(|) {*}
    multi sub open(&block) { Dongle.open(&block) }
    multi sub open(Str $serial, &block) { Dongle.open($serial, &block) }
}
