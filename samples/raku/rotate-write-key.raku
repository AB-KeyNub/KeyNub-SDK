use v6.d;
# KeyNub SDK - Raku sample: take ownership of a new dongle.
#
# A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
# so that from the next session onward only your key can write records, erase
# them or increment counters. Run it once per dongle, when it arrives.
#
# Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
#
#     openssl ecparam -name prime256v1 -genkey -noout |
#       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
#
#     raku samples/raku/rotate-write-key.raku keys/keynub-shipping-writeauth.key.der my-key.der
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# The replacement key is worth what your licence-signing key is worth. It
# cannot be recovered from the dongle, and a unit rotated to a key you have
# lost has to come back to be re-provisioned.
#
# In your own project, after `zef install KeyNub::LicDongle`, drop the `use lib` line.
use lib $?FILE.IO.parent.parent.parent.add('bindings').add('raku').add('lib').absolute;
use KeyNub::LicDongle;

my constant LD = KeyNub::LicDongle;

if @*ARGS.elems != 2 {
    say 'usage: rotate-write-key <current-key.der> <new-key.der>';
    exit 2;
}

for @*ARGS -> $path {
    next if $path.IO.f;
    say "KeyNub error: no key file at $path";
    exit 1;
}

{
    my $current = @*ARGS[0].IO.slurp(:bin);
    my $replacement = @*ARGS[1].IO.slurp(:bin);
    unless LD::devices() {
        say 'Connect a KeyNub dongle and re-run.';
        exit 0;
    }
    LD::open(-> $d {
        say "Dongle {$d.serial}";
        if $d.info.write-auth-rotated {
            say "This dongle's write key has already been rotated away from the factory one.";
        }
        $d.session({
            $d.authorize-write($current);       # the key the dongle accepts today
            $d.rotate-write-key($replacement);  # from the next session: only the new one
        });
        say "Write key rotated: {$d.info.write-auth-rotated ?? 'yes' !! 'no'}";
    });
    CATCH {
        when X::KeyNub::LicDongle | X::KeyNub::LicDongle::Library | X::IO {
            say "KeyNub error: {.message}";
            exit 1;
        }
    }
}
