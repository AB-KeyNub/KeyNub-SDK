/+ dub.sdl:
    name "verify_and_read"
    dependency "keynub-licdongle" path="../.."
+/
// KeyNub SDK - D sample: verify a dongle and read what it holds.
//
//     dub run --single samples/d/verify_and_read.d      (from the repository root)
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
import std.stdio : writeln, writefln;

import keynub.licdongle;

void report(ref Dongle d)
{
    auto i = d.info();
    writefln("Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.", i.protocolMajor,
        i.protocolMinor, i.firmwareMajor, i.firmwareMinor, i.firmwarePatch, i.dataFree, i.dataCapacity);
    // The only trace a firmware hang leaves behind. Worth reporting to support.
    if (i.watchdogReboot)
        writeln("WARNING: this dongle's previous boot ended in a watchdog reset.");
    auto g = d.verifyGenuine();
    writefln("Genuine: yes (serial %s, provisioned %s)", g.serial, g.provisionedDate);
}

void readRecords(ref Dongle d)
{
    auto recs = d.records();
    writefln("%d record(s) on the dongle:", recs.length);
    foreach (r; recs)
        writefln("  %-16s %d bytes", r.name, r.size);
    // A missing record is a normal state, not an error.
    foreach (r; recs)
        if (r.name == "license")
            writefln("Read %d bytes from the license record.", d.readRecord("license").length);
}

// The part that actually protects something. At licence-issue time you would
// call appEncrypt once, with a developer dongle, and ship only the sealed data;
// the program then cannot proceed without a dongle, because it holds no other
// copy. Scope.developer lets any dongle you have issued decrypt it, so one file
// serves every customer; Scope.device locks it to one dongle.
void protectSomething(ref Dongle d)
{
    auto needed = cast(const(ubyte)[]) "the data this program cannot run without";
    auto sealed = d.appEncrypt(Scope.developer, needed);
    auto recovered = d.appDecrypt(sealed);
    writefln("App-crypto round trip: %d bytes -> %d sealed -> %s", needed.length, sealed.length,
        recovered == needed ? "recovered intact" : "MISMATCH");
}

int main()
{
    try
    {
        auto v = libraryVersion();
        writefln("KeyNub library v%d.%d.%d", v.major, v.minor, v.patch);
        if (devices().length == 0)
        {
            writeln("Connect a KeyNub dongle and re-run.");
            return 0;
        }
        withDongle((ref Dongle d) { // first dongle, or withDongle("serial", ...)
            report(d);
            d.withSession({ // closed on every exit path
                readRecords(d);
                protectSomething(d);
            });
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
}
