/// KeyNub License Dongle: verify that a dongle is genuine, read and write the
/// license records it holds, use its hardware counters and encrypt data so
/// that only a dongle can decrypt it. Calls the SDK's flat C API through a
/// library loaded at run time (`keynub.licdongle.library`); nothing is linked.
module keynub.licdongle;

public import keynub.licdongle.library : LibraryException, libraryEnvironmentVariable,
    libraryPath, loadedLibraryPath, setLibraryPath;

import std.conv : to;
import std.string : fromStringz, toStringz;

import keynub.licdongle.flat;
import keynub.licdongle.library : api;

/// The SDK's status codes (`licd_status`).
enum Status : int
{
    ok = 0,
    invalidArg = -1,
    noDevice = -2,
    accessDenied = -3,
    io = -4,
    timeout = -5,
    protocol = -6,
    notGenuine = -7,
    certInvalid = -8,
    sessionExpired = -9,
    tagMismatch = -10,
    range = -11,
    storageFull = -12,
    busy = -13,
    notFound = -14,
    authRequired = -15,
    firmwareIncompatible = -16,
    sdkTooOld = -17,
    cancelled = -18,
    notImplemented = -19,
    internal = -20,
}

/// The name of a status code; `"unknown"` for one this binding does not know.
string statusName(int code) pure nothrow @safe
{
    switch (code)
    {
        static foreach (member; __traits(allMembers, Status))
        {
    case __traits(getMember, Status, member):
            return member;
        }
    default:
        return "unknown";
    }
}

/// A failed dongle call: the status, the raw code, the operation (the flat API
/// function) and the library's detail text, which may be empty.
class LicDongleException : Exception
{
    Status status;
    int code;
    string operation;
    string detail;

    this(string operation, int code, string detail = "", string file = __FILE__,
        size_t line = __LINE__)
    {
        this.status = cast(Status) code;
        this.code = code;
        this.operation = operation;
        this.detail = detail;
        auto text = operation ~ ": " ~ statusName(code) ~ " (" ~ to!string(code) ~ ")";
        if (detail.length)
            text ~= ": " ~ detail;
        super(text, file, line);
    }
}

/// The native library's version.
struct LibraryVersion
{
    int major;
    int minor;
    int patch;
}

/// An attached dongle.
struct Device
{
    string serial;
    string path;
}

/// Plaintext device information.
struct Info
{
    int protocolMajor;
    int protocolMinor;
    int firmwareMajor;
    int firmwareMinor;
    int firmwarePatch;
    bool secureElementReady;
    bool provisioned;
    /// The previous boot ended in a watchdog reset.
    bool watchdogReboot;
    bool isolated;
    /// The write-auth key has been rotated away from the factory one.
    bool writeAuthRotated;
    int dataCapacity;
    int dataFree;
}

/// The result of a successful `Dongle.verifyGenuine`.
struct Genuine
{
    string serial;
    /// "YYYY-MM-DD", or empty when the dongle reports none. Informational.
    string provisionedDate;
}

/// A record on the dongle.
struct Record
{
    string name;
    int size;
}

/// Who can decrypt data sealed with `Dongle.appEncrypt`.
enum Scope : int
{
    /// This dongle only.
    device = 0,
    /// Any dongle issued by the same developer.
    developer = 1,
}

/// The native library's version.
LibraryVersion libraryVersion()
{
    LibraryVersion v;
    check("licdf_version", 0, api.version_(&v.major, &v.minor, &v.patch));
    return v;
}

/// Human-readable text for a status code; needs no dongle.
string statusText(int code)
{
    char[errorSize] text;
    if (api.strerror(code, text.ptr, errorSize) != 0)
        return statusName(code);
    return fromStringz(text.ptr).idup;
}

/// The attached dongles.
Device[] devices()
{
    auto a = api;
    int count;
    check("licdf_device_count", 0, a.deviceCount(&count));
    auto found = new Device[count];
    foreach (i; 0 .. count)
    {
        char[pathSize] text;
        check("licdf_device_serial", 0, a.deviceSerial(i, text.ptr, pathSize));
        found[i].serial = fromStringz(text.ptr).idup;
        check("licdf_device_path", 0, a.devicePath(i, text.ptr, pathSize));
        found[i].path = fromStringz(text.ptr).idup;
    }
    return found;
}

/// Opens the first dongle (or the one with `serial`), runs `dg` with it and
/// closes it on every exit path. Returns what `dg` returns.
auto withDongle(T)(scope T delegate(ref Dongle) dg)
{
    return withDongle!T(null, dg);
}

/// ditto
auto withDongle(T)(string serial, scope T delegate(ref Dongle) dg)
{
    auto d = Dongle.open(serial);
    scope (success)
        d.close();
    scope (failure)
    {
        try
            d.close();
        catch (Exception)
        {
        }
    }
    static if (is(T == void))
        dg(d);
    else
        return dg(d);
}

/// An open dongle. Not copyable; `close` it, or let it go out of scope.
struct Dongle
{
    private int handle_;

    @disable this(this);

    private this(int handle)
    {
        handle_ = handle;
    }

    ~this()
    {
        if (handle_ > 0)
        {
            try
                api.close(handle_);
            catch (Exception)
            {
            }
            handle_ = 0;
        }
    }

    /// Opens the dongle with this serial, or the first one found when `serial`
    /// is empty.
    static Dongle open(string serial = null)
    {
        auto handle = api.open((serial.length ? serial : "").toStringz);
        if (handle < 0)
            throw new LicDongleException("licdf_open", handle);
        return Dongle(handle);
    }

    /// Opens the dongle at this device path (from `devices`).
    static Dongle openPath(string path)
    {
        auto handle = api.openPath(path.toStringz);
        if (handle < 0)
            throw new LicDongleException("licdf_open_path", handle);
        return Dongle(handle);
    }

    /// Whether `close` has not been called yet.
    bool isOpen() const
    {
        return handle_ > 0;
    }

    /// Closes the dongle. Further calls fail with `Status.invalidArg`.
    void close()
    {
        if (handle_ <= 0)
            return;
        auto handle = handle_;
        handle_ = 0;
        check("licdf_close", handle, api.close(handle));
    }

    /// The dongle's serial number (14 hex digits).
    string serial()
    {
        char[serialSize] text;
        check("licdf_get_serial", handle_, api.getSerial(handle_, text.ptr, serialSize));
        return fromStringz(text.ptr).idup;
    }

    /// Plaintext device information.
    Info info()
    {
        int pa, pb, fa, fb, fc, flags, capacity, free;
        check("licdf_get_info", handle_, api.getInfo(handle_, &pa, &pb, &fa, &fb, &fc,
                &flags, &capacity, &free));
        Info i;
        i.protocolMajor = pa;
        i.protocolMinor = pb;
        i.firmwareMajor = fa;
        i.firmwareMinor = fb;
        i.firmwarePatch = fc;
        i.secureElementReady = (flags & flagSecureElementReady) != 0;
        i.provisioned = (flags & flagProvisioned) != 0;
        i.watchdogReboot = (flags & flagWatchdogReboot) != 0;
        i.isolated = (flags & flagIsolated) != 0;
        i.writeAuthRotated = (flags & flagWriteAuthRotated) != 0;
        i.dataCapacity = capacity;
        i.dataFree = free;
        return i;
    }

    /// Proves the dongle is genuine: certificate chain to the trusted root plus
    /// a live challenge-response. Returns only when it is; throws otherwise.
    Genuine verifyGenuine()
    {
        int genuine;
        char[serialSize] serialText;
        char[dateSize] dateText;
        check("licdf_verify_genuine", handle_, api.verifyGenuine(handle_, &genuine,
                serialText.ptr, serialSize, dateText.ptr, dateSize));
        if (genuine == 0)
            throw new LicDongleException("licdf_verify_genuine", Status.notGenuine);
        return Genuine(fromStringz(serialText.ptr).idup, fromStringz(dateText.ptr).idup);
    }

    /// The boolean form for a gate: `true` only when `verifyGenuine` succeeds.
    /// Fails closed: every failure gives `false`.
    bool isGenuine() nothrow
    {
        try
        {
            verifyGenuine();
            return true;
        }
        catch (Exception)
            return false;
    }

    /// Overrides the CA root that `verifyGenuine` checks against (DER).
    void setTrustRoot(const(ubyte)[] der)
    {
        check("licdf_set_trust_root", handle_, api.setTrustRoot(handle_, ptrOf(der), lengthOf(der)));
    }

    /// Opens an authenticated session; records, counters and app crypto need one.
    void sessionOpen()
    {
        check("licdf_session_open", handle_, api.sessionOpen(handle_));
    }

    /// Closes the session.
    void sessionClose()
    {
        check("licdf_session_close", handle_, api.sessionClose(handle_));
    }

    /// Opens a session, runs `dg` and closes the session on every exit path.
    /// Returns what `dg` returns.
    auto withSession(T)(scope T delegate() dg)
    {
        sessionOpen();
        scope (success)
            sessionClose();
        scope (failure)
        {
            try
                sessionClose();
            catch (Exception)
            {
            }
        }
        static if (is(T == void))
            dg();
        else
            return dg();
    }

    /// Elevates the session to the write role with a write-auth key (P-256
    /// PKCS#8 DER). Belongs in licence-issuing tooling, not in the application
    /// your users run.
    void authorizeWrite(const(ubyte)[] key)
    {
        check("licdf_write_auth", handle_, api.writeAuth(handle_, ptrOf(key), lengthOf(key)));
    }

    /// Replaces the dongle's write-auth key with `key` (P-256 PKCS#8 DER).
    /// Call `authorizeWrite` first. From the next session on, only the new key
    /// elevates.
    void rotateWriteKey(const(ubyte)[] key)
    {
        check("licdf_write_auth_rotate", handle_, api.writeAuthRotate(handle_, ptrOf(key), lengthOf(key)));
    }

    /// The records on the dongle.
    Record[] records()
    {
        auto a = api;
        int count;
        check("licdf_record_count", handle_, a.recordCount(handle_, &count));
        auto found = new Record[count];
        foreach (i; 0 .. count)
        {
            char[nameSize] text;
            int size;
            check("licdf_record_name", handle_, a.recordName(handle_, i, text.ptr, nameSize, &size));
            found[i] = Record(fromStringz(text.ptr).idup, size);
        }
        return found;
    }

    /// The content of a record.
    ubyte[] readRecord(string name)
    {
        auto a = api;
        auto cname = name.toStringz;
        return readBytes("licdf_record_read", (ubyte* data, int capacity, int* length) =>
                a.recordRead(handle_, cname, data, capacity, length));
    }

    /// Writes a record, replacing one of the same name. Needs the write role.
    void writeRecord(string name, const(ubyte)[] data)
    {
        check("licdf_record_write", handle_, api.recordWrite(handle_, name.toStringz,
                ptrOf(data), lengthOf(data)));
    }

    /// Erases one record. Needs the write role.
    void eraseRecord(string name)
    {
        check("licdf_record_erase", handle_, api.recordErase(handle_, name.toStringz));
    }

    /// Erases every record. Separate from `eraseRecord` so that an
    /// accidentally empty name cannot wipe the dongle.
    void eraseAllRecords()
    {
        check("licdf_record_erase_all", handle_, api.recordEraseAll(handle_));
    }

    /// The value of a hardware monotonic counter.
    int readCounter(int counterId)
    {
        int value;
        check("licdf_counter_read", handle_, api.counterRead(handle_, counterId, &value));
        return value;
    }

    /// Increments a counter and returns the new value. Needs the write role.
    int incrementCounter(int counterId)
    {
        int value;
        check("licdf_counter_increment", handle_, api.counterIncrement(handle_, counterId, &value));
        return value;
    }

    /// Seals data so that only a dongle can open it: this one (`Scope.device`)
    /// or any dongle issued by the same developer (`Scope.developer`). Build
    /// the licence check on this pair: put something the program needs through
    /// it, so removing the check removes the data.
    ubyte[] appEncrypt(Scope scope_, const(ubyte)[] plaintext)
    {
        auto a = api;
        return readBytes("licdf_app_encrypt", (ubyte* data, int capacity, int* length) =>
                a.appEncrypt(handle_, scope_, ptrOf(plaintext), lengthOf(plaintext),
                    data, capacity, length));
    }

    /// Opens data sealed with `appEncrypt`.
    ubyte[] appDecrypt(const(ubyte)[] packed)
    {
        auto a = api;
        return readBytes("licdf_app_decrypt", (ubyte* data, int capacity, int* length) =>
                a.appDecrypt(handle_, ptrOf(packed), lengthOf(packed), data, capacity, length));
    }

    /// Diagnostic detail for the most recent failure on this dongle; may be empty.
    string lastErrorDetail()
    {
        return detailOf(handle_);
    }

    private ubyte[] readBytes(string operation, scope int delegate(ubyte*, int, int*) call)
    {
        int needed;
        ubyte probe;
        auto rc = call(&probe, 0, &needed);
        if (rc == 0)
            return [];
        if (rc != Status.range)
            throw new LicDongleException(operation, rc, detailOf(handle_));
        auto data = new ubyte[needed > 0 ? needed : 1];
        int length;
        rc = call(data.ptr, needed, &length);
        if (rc != 0)
            throw new LicDongleException(operation, rc, detailOf(handle_));
        return data[0 .. length];
    }
}

private void check(string operation, int handle, int rc)
{
    if (rc != 0)
        throw new LicDongleException(operation, rc, handle > 0 ? detailOf(handle) : "");
}

private string detailOf(int handle) nothrow
{
    try
    {
        char[errorSize] text;
        if (api.lastError(handle, text.ptr, errorSize) == 0)
            return fromStringz(text.ptr).idup;
    }
    catch (Exception)
    {
    }
    return "";
}

private const(ubyte)* ptrOf(const(ubyte)[] data)
{
    static immutable ubyte empty = 0;
    return data.length ? data.ptr : &empty;
}

private int lengthOf(const(ubyte)[] data)
{
    if (data.length > int.max)
        throw new LicDongleException("argument", Status.invalidArg, "more than 2 GiB of data");
    return cast(int) data.length;
}

unittest
{
    assert(statusName(-2) == "noDevice");
    assert(statusName(0) == "ok");
    assert(statusName(-99) == "unknown");
    auto e = new LicDongleException("licdf_open", -2);
    assert(e.status == Status.noDevice && e.code == -2 && e.operation == "licdf_open");
    assert(e.msg == "licdf_open: noDevice (-2)");
    auto f = new LicDongleException("licdf_record_read", -14, "no such record");
    assert(f.msg == "licdf_record_read: notFound (-14): no such record");
    assert(cast(Status) -99 != Status.ok);
}
