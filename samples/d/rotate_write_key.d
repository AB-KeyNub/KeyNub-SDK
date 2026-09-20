/+ dub.sdl:
    name "rotate_write_key"
    dependency "keynub-licdongle" path="../.."
+/
// KeyNub SDK - D sample: take ownership of a new dongle.
//
// A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
// so that from the next session onward only your key can write records, erase
// them or increment counters. Run it once per dongle, when it arrives.
//
// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//
//     openssl ecparam -name prime256v1 -genkey -noout |
//       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//
//     dub run --single samples/d/rotate_write_key.d -- keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It
// cannot be recovered from the dongle, and a unit rotated to a key you have
// lost has to come back to be re-provisioned.
import std.file : read;
import std.stdio : writeln;

import keynub.licdongle;

int main(string[] args)
{
    if (args.length != 3)
    {
        writeln("usage: rotate_write_key <current-key.der> <new-key.der>");
        return 2;
    }
    try
    {
        auto current = cast(ubyte[]) read(args[1]);
        auto replacement = cast(ubyte[]) read(args[2]);
        if (devices().length == 0)
        {
            writeln("Connect a KeyNub dongle and re-run.");
            return 0;
        }
        withDongle((ref Dongle d) {
            writeln("Dongle ", d.serial);
            if (d.info().writeAuthRotated)
                writeln("This dongle's write key has already been rotated away from the factory one.");
            d.withSession({
                d.authorizeWrite(current); // the key the dongle accepts today
                d.rotateWriteKey(replacement); // from the next session: only the new one
            });
            writeln("Write key rotated: ", d.info().writeAuthRotated ? "yes" : "no");
        });
        return 0;
    }
    catch (LicDongleException e)
    {
        writeln("KeyNub error: ", e.msg);
        return 1;
    }
    catch (LibraryException e)
    {
        writeln("KeyNub error: ", e.msg);
        return 1;
    }
    catch (Exception e)
    {
        writeln("KeyNub error: ", e.msg);
        return 1;
    }
}
