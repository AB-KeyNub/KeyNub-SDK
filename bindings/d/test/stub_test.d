// Every call of the binding against a stand-in for the flat C API: the SDK's
// flat layer compiled together with the C ABI stand-in
// (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
// into one shared library, with a C compiler from the path (cc, gcc, clang,
// zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
// stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the
// test does not run inside a clone. Exit code 0 when every check passed.
//
//     dub run --config=standin-test        (from the repository root)
module stub_test;

import std.algorithm : any, map, sort;
import std.array : array;
import std.conv : to;
import std.file : exists, getcwd, tempDir;
import std.path : buildPath, dirName;
import std.process : environment, execute, Config;
import std.range : iota;
import std.stdio : writeln, writefln;

import keynub.licdongle;

enum serial = "04A1B2C3D4E5F6";
immutable ubyte[] factoryKey = [0x30, 0x10, 0x01, 0x02, 0x03];
immutable ubyte[] replacementKey = [0x30, 0x11, 0x09, 0x08, 0x07, 0x06];

int failures;

void check(bool condition, string what)
{
    if (!condition)
    {
        failures++;
        writeln("  FAIL  ", what);
    }
}

void fails(Status status, string what, scope void delegate() action)
{
    try
    {
        action();
        check(false, what ~ ": no failure");
    }
    catch (LicDongleException e)
        check(e.status == status, what ~ ": " ~ statusName(e.code));
}

ubyte[] bytes(string text)
{
    return cast(ubyte[]) text.dup;
}

int main()
{
    setLibraryPath(standIn());

    check(libraryVersion() == LibraryVersion(9, 8, 7), "library version");
    check(statusText(-2) == "no device", "status text");

    check(devices() == [Device(serial, "stub:0")], "devices");
    fails(Status.noDevice, "open by unknown serial", { Dongle.open("nope"); });
    fails(Status.noDevice, "open by unknown path", { Dongle.openPath("stub:9"); });

    auto d = Dongle.open();
    check(d.isOpen, "open");
    check(d.serial == serial, "serial");
    auto i = d.info();
    check(i.protocolMajor == 1 && i.protocolMinor == 0, "protocol version");
    check(i.firmwareMajor == 2 && i.firmwareMinor == 3 && i.firmwarePatch == 4, "firmware version");
    check(i.secureElementReady && i.provisioned && i.isolated, "flags set");
    check(!i.watchdogReboot && !i.writeAuthRotated, "flags clear");
    check(i.dataCapacity == 1024 * 1024 && i.dataFree == 1_000_000, "capacity");
    auto g = d.verifyGenuine();
    check(g.serial == serial && g.provisionedDate == "2026-08-15", "genuine");
    check(d.isGenuine(), "isGenuine");

    ubyte[] badRoot = [0x02, 0x01, 0x00];
    fails(Status.certInvalid, "malformed trust root", { d.setTrustRoot(badRoot); });
    ubyte[] root = [0x30, 0x82, 0x01, 0x00];
    root ~= new ubyte[128];
    root[4 .. $] = 0xAB;
    d.setTrustRoot(root);
    fails(Status.certInvalid, "verify against a foreign root", { d.verifyGenuine(); });
    check(!d.isGenuine(), "isGenuine fails closed");
    root[4 .. $] = 0x01;
    d.setTrustRoot(root);
    check(d.isGenuine(), "isGenuine after the right root");

    fails(Status.sessionExpired, "records without a session", { d.records(); });
    d.sessionOpen();
    auto payload = bytes("license-blob-0123456789");
    fails(Status.authRequired, "write before the write role", { d.writeRecord("lic", payload); });
    ubyte[] badKey = [0x30, 0x00];
    fails(Status.notGenuine, "write role with a bad key", { d.authorizeWrite(badKey); });
    d.authorizeWrite(factoryKey);
    d.writeRecord("lic", payload);
    check(d.readRecord("lic") == payload, "read back");
    d.writeRecord("cfg", bytes("cfgdata"));
    auto recs = d.records();
    check(recs.map!(r => r.name).array.sort.array == ["cfg", "lic"], "record names");
    check(recs.any!(r => r.name == "lic" && r.size == payload.length), "record size");
    check(d.readRecord("cfg") == bytes("cfgdata"), "second record");
    fails(Status.notFound, "read a missing record", { d.readRecord("nope"); });
    fails(Status.invalidArg, "erase with an empty name", { d.eraseRecord(""); });
    check(d.records().length == 2, "two records");
    d.eraseRecord("cfg");
    check(d.records().map!(r => r.name).array == ["lic"], "one record left");
    d.writeRecord("empty", []);
    check(d.readRecord("empty").length == 0, "empty record");

    auto before = d.readCounter(0);
    check(d.incrementCounter(0) == before + 1, "increment");
    check(d.readCounter(0) == before + 1 && d.readCounter(1) == 0, "counters");
    fails(Status.range, "counter out of range", { d.readCounter(7); });

    auto secret = iota(100).map!(k => cast(ubyte)((3 * k + 7) % 256)).array;
    foreach (scope_; [Scope.device, Scope.developer])
    {
        auto name = to!string(scope_);
        auto blob = d.appEncrypt(scope_, secret);
        check(blob.length > secret.length, "sealed data is longer, " ~ name);
        check(blob[0] == cast(int) scope_, "scope byte, " ~ name);
        check(d.appDecrypt(blob) == secret, "round trip, " ~ name);
        auto tampered = blob.dup;
        tampered[$ - 1] ^= 1;
        fails(Status.tagMismatch, "tampered blob, " ~ name, { d.appDecrypt(tampered); });
    }

    d.eraseAllRecords();
    check(d.records().length == 0, "erase all");

    d.rotateWriteKey(replacementKey);
    d.writeRecord("lic", bytes("still-writable"));
    d.sessionClose();
    check(d.info().writeAuthRotated, "rotated flag");
    d.sessionOpen();
    fails(Status.notGenuine, "factory key after rotation", { d.authorizeWrite(factoryKey); });
    d.authorizeWrite(replacementKey);
    d.writeRecord("lic", bytes("new-key-writes"));
    check(d.readRecord("lic") == bytes("new-key-writes"), "write with the new key");
    d.sessionClose();
    d.close();
    check(!d.isOpen, "closed");
    try
    {
        d.serial();
        check(false, "serial after close: no failure");
    }
    catch (LicDongleException)
    {
    }

    auto viaWith = withDongle((ref Dongle dd) => dd.serial());
    check(viaWith == serial, "withDongle");
    // records() needs a session, so a value back proves withSession opened one.
    auto count = withDongle(serial, (ref Dongle dd) => dd.withSession(() => dd.records().length));
    check(count >= 0, "withSession");
    withDongle((ref Dongle dd) { check(dd.isOpen, "withDongle, void"); });
    check(loadedLibraryPath() == libraryPath(), "loaded path");

    if (failures)
    {
        writefln("%d check(s) failed", failures);
        return 1;
    }
    writeln("keynub-licdongle: every call passed against the ABI stand-in");
    return 0;
}

// ---- the stand-in ----------------------------------------------------------

string standIn()
{
    auto given = environment.get("KEYNUB_LICDONGLE_FLAT_LIBRARY", "");
    if (given.length)
        return given;
    return buildStandIn();
}

string buildStandIn()
{
    auto root = sdkRoot();
    version (Windows)
        enum windows = true;
    else
        enum windows = false;
    auto tmp = tempDir();
    // Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by
    // leaf name even for an absolute-path dlopen, and a build tree on that
    // path holds the real library under that name.
    auto output = buildPath(tmp, windows ? "keynub_flat_standin.dll" : "libkeynub_flat_standin.so");
    auto include = exists(buildPath(root, "core", "include", "licdongle.h"))
        ? buildPath(root, "core", "include") : buildPath(root, "include");
    string[] sources = [
        buildPath(root, "bindings", "flat", "licd_flat.c"),
        buildPath(root, "bindings", "julia", "test", "stub", "licd_stub.c")
    ];
    string[] gccArgs = [
        "-shared", "-O1", "-DLICD_BUILD_SHARED", "-DLICDF_BUILD_SHARED", "-I" ~ include,
        "-I" ~ buildPath(root, "bindings", "flat"), "-o", output
    ] ~ sources ~ (windows ? [] : ["-fPIC"]);
    string[] clArgs = [
        "/nologo", "/LD", "/O1", "/DLICD_BUILD_SHARED", "/DLICDF_BUILD_SHARED", "/I" ~ include,
        "/I" ~ buildPath(root, "bindings", "flat"), "/Fe:" ~ output
    ] ~ sources;
    string[][] compilers = [
        ["cc"] ~ gccArgs, ["gcc"] ~ gccArgs, ["clang"] ~ gccArgs, ["zig", "cc"] ~ gccArgs,
        ["cl"] ~ clArgs
    ];
    foreach (command; compilers)
    {
        try
        {
            auto result = execute(command, null, Config.none, size_t.max, tmp);
            if (result.status == 0)
                return output;
        }
        catch (Exception)
        {
        }
    }
    writeln("the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path");
    import core.stdc.stdlib : exit;

    exit(1);
    assert(0);
}

string sdkRoot()
{
    auto given = environment.get("KEYNUB_SDK_ROOT", "");
    if (given.length)
        return given;
    for (auto dir = getcwd();; dir = dirName(dir))
    {
        if (exists(buildPath(dir, "bindings", "flat", "licd_flat.c")))
            return dir;
        if (dirName(dir) == dir)
            break;
    }
    writeln("the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT");
    import core.stdc.stdlib : exit;

    exit(1);
    assert(0);
}
