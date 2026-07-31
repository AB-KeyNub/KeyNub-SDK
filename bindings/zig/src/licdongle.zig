//! KeyNub License Dongle SDK — Zig binding.
//!
//! ```zig
//! const keynub = @import("keynub_licdongle");
//!
//! var ctx = try keynub.Context.init();
//! defer ctx.deinit();
//!
//! var dongle = try ctx.open(null);
//! defer dongle.close();
//! _ = try dongle.verifyGenuine();          // error unless genuine
//!
//! var session = try dongle.openSession();
//! defer session.close();
//! const data = try session.appDecrypt(allocator, blob);  // the licence check
//! defer allocator.free(data);
//! ```
//!
//! Unlike every other binding in this SDK, there are no re-declared prototypes
//! here: `@cImport` compiles `include/licdongle.h` itself, so the
//! declarations cannot drift from the header. That removes the failure mode the
//! other bindings each need a test to guard against — and it is why the tests
//! here concentrate on the wrapper's own behaviour instead.
//!
//! Read SDK/docs/integration-security.md before writing the check.
//! `if (dongle.isGenuine())` compiles to a conditional jump, and patching one of
//! those in a release binary is a beginner exercise. Route something the program
//! needs through appEncrypt/appDecrypt, so removing the check removes the data.

const std = @import("std");

/// The raw C ABI, translated from the real header. Public so this wrapper can be
/// mixed with direct C calls.
pub const c = @cImport({
    @cInclude("licdongle.h");
});

// ============================================================================
// Errors
// ============================================================================

/// Zig error sets carry no payload, so the numeric status and the SDK's
/// diagnostic text are reached through `Context.lastStatus` and
/// `Context.lastErrorDetail` after a failure.
pub const Error = error{
    InvalidArgument,
    NoDevice,
    AccessDenied,
    Io,
    Timeout,
    Protocol,
    NotGenuine,
    CertificateInvalid,
    SessionExpired,
    TagMismatch,
    OutOfRange,
    StorageFull,
    Busy,
    NotFound,
    AuthRequired,
    FirmwareIncompatible,
    SdkTooOld,
    Cancelled,
    NotImplemented,
    Internal,
};

fn errorFromStatus(status: c_int) Error {
    return switch (status) {
        c.LICD_E_INVALID_ARG => Error.InvalidArgument,
        c.LICD_E_NO_DEVICE => Error.NoDevice,
        c.LICD_E_ACCESS_DENIED => Error.AccessDenied,
        c.LICD_E_IO => Error.Io,
        c.LICD_E_TIMEOUT => Error.Timeout,
        c.LICD_E_PROTOCOL => Error.Protocol,
        c.LICD_E_NOT_GENUINE => Error.NotGenuine,
        c.LICD_E_CERT_INVALID => Error.CertificateInvalid,
        c.LICD_E_SESSION_EXPIRED => Error.SessionExpired,
        c.LICD_E_TAG_MISMATCH => Error.TagMismatch,
        c.LICD_E_RANGE => Error.OutOfRange,
        c.LICD_E_STORAGE_FULL => Error.StorageFull,
        c.LICD_E_BUSY => Error.Busy,
        c.LICD_E_NOT_FOUND => Error.NotFound,
        c.LICD_E_AUTH_REQUIRED => Error.AuthRequired,
        c.LICD_E_FW_INCOMPATIBLE => Error.FirmwareIncompatible,
        c.LICD_E_SDK_TOO_OLD => Error.SdkTooOld,
        c.LICD_E_CANCELLED => Error.Cancelled,
        c.LICD_E_NOT_IMPLEMENTED => Error.NotImplemented,
        else => Error.Internal,
    };
}

/// Human-readable text for a status code, from the SDK itself.
pub fn statusText(status: c_int) []const u8 {
    const raw = c.licd_strerror(status);
    if (raw == null) return "unknown error";
    return std.mem.sliceTo(raw, 0);
}

// ============================================================================
// Plain results
// ============================================================================

/// A short string copied out of a fixed-size C array. A plain struct rather than
/// std.BoundedArray, which has moved between Zig releases; this cannot break.
pub const FixedString = struct {
    buffer: [512]u8 = undefined,
    length: usize = 0,

    pub fn slice(self: *const FixedString) []const u8 {
        return self.buffer[0..self.length];
    }

    fn fromC(bytes: []const u8) FixedString {
        var out = FixedString{};
        const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
        const n = @min(end, out.buffer.len);
        @memcpy(out.buffer[0..n], bytes[0..n]);
        out.length = n;
        return out;
    }
};

pub const Version = struct { major: i32, minor: i32, patch: i32 };

pub const DeviceInfo = struct {
    serial: FixedString,
    /// Opaque; pass to `Context.openPath`.
    path: FixedString,
    vendor_id: u16,
    product_id: u16,
};

pub const Info = struct {
    protocol_major: u8,
    protocol_minor: u8,
    firmware_major: u8,
    firmware_minor: u8,
    firmware_patch: u8,
    se_ready: bool,
    provisioned: bool,
    data_capacity: u32,
    data_free: u32,
    /// The dongle's *previous* boot ended in a watchdog timeout: the firmware
    /// hung and reset itself. The only trace a field hang leaves behind, and a
    /// power cycle clears it — worth logging.
    watchdog_reboot: bool,
    /// Whether the dongle confirmed at boot that its USB and parsing code is fenced off
    /// from keys and storage. The software simulator reports false.
    isolated: bool,
};

pub const GenuineResult = struct {
    genuine: bool,
    serial: FixedString,
    batch: FixedString,
    /// "YYYY-MM-DD", or empty.
    provisioned_date: FixedString,
};

pub const RecordInfo = struct {
    name: []u8,
    size: u32,
};

pub const Scope = enum(c_int) {
    /// Only this one physical dongle can decrypt.
    device = c.LICD_SCOPE_DEVICE,
    /// Any dongle from the same developer batch.
    developer = c.LICD_SCOPE_DEVELOPER,
};

/// Progress reporting for a transfer. Return false from `callback` to cancel,
/// which surfaces as `Error.Cancelled`.
pub const Progress = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque, done: u32, total: u32) bool,
};

fn progressTrampoline(done: u32, total: u32, user: ?*anyopaque) callconv(.c) c_int {
    const progress: *const Progress = @ptrCast(@alignCast(user.?));
    return if (progress.callback(progress.context, done, total)) 1 else 0;
}

// ============================================================================
// Context
// ============================================================================

pub const Context = struct {
    ptr: *c.licd_ctx,
    /// The status of the most recent failure, for when the error set is not
    /// specific enough. Zig errors carry no payload.
    last_status: c_int = c.LICD_OK,

    pub fn init() Error!Context {
        var ptr: ?*c.licd_ctx = null;
        const rc = c.licd_init(&ptr);
        if (rc != c.LICD_OK) return errorFromStatus(rc);
        return Context{ .ptr = ptr orelse return Error.Internal };
    }

    pub fn deinit(self: *Context) void {
        c.licd_free(self.ptr);
    }

    pub fn libraryVersion() Version {
        var major: c_int = 0;
        var minor: c_int = 0;
        var patch: c_int = 0;
        c.licd_version(&major, &minor, &patch);
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    /// The SDK's diagnostic detail for the most recent failure on this thread.
    pub fn lastErrorDetail(self: *Context) []const u8 {
        const raw = c.licd_error_detail(self.ptr);
        if (raw == null) return "";
        return std.mem.sliceTo(raw, 0);
    }

    fn check(self: *Context, rc: c_int) Error!void {
        self.last_status = rc;
        if (rc != c.LICD_OK) return errorFromStatus(rc);
    }

    /// Overrides the CA root that `verifyGenuine` checks against. Applications do
    /// not need this: a release build embeds the KeyNub production root. It exists
    /// for dongles provisioned against a different CA, and for vendor tooling.
    pub fn setTrustRoot(self: *Context, der: []const u8) Error!void {
        try self.check(c.licd_set_trust_root(self.ptr, der.ptr, der.len));
    }

    /// Connected dongles. Caller owns the slice.
    pub fn enumerate(self: *Context, allocator: std.mem.Allocator) ![]DeviceInfo {
        var list: [*c]c.licd_device_info = null;
        var count: usize = 0;
        try self.check(c.licd_enumerate(self.ptr, &list, &count));
        defer if (list != null) c.licd_free_device_list(list, count);

        const out = try allocator.alloc(DeviceInfo, count);
        for (0..count) |i| {
            out[i] = .{
                .serial = FixedString.fromC(&list[i].serial),
                .path = FixedString.fromC(&list[i].path),
                .vendor_id = list[i].vendor_id,
                .product_id = list[i].product_id,
            };
        }
        return out;
    }

    /// Opens the dongle with this serial, or the first one found when null.
    pub fn open(self: *Context, serial: ?[]const u8) Error!Dongle {
        var buffer: [64]u8 = undefined;
        var name: ?[*:0]const u8 = null;
        if (serial) |s| {
            if (s.len >= buffer.len) return Error.InvalidArgument;
            @memcpy(buffer[0..s.len], s);
            buffer[s.len] = 0;
            name = @ptrCast(&buffer);
        }
        var dev: ?*c.licd_device = null;
        try self.check(c.licd_open(self.ptr, name, &dev));
        return Dongle{ .ptr = dev orelse return Error.Internal, .ctx = self };
    }

    /// Adopts a device opened through the C ABI directly, so this wrapper can be
    /// introduced into existing code a call at a time — and so a test harness can
    /// wrap a simulated device.
    pub fn adopt(self: *Context, dev: *c.licd_device) Dongle {
        return Dongle{ .ptr = dev, .ctx = self };
    }
};

// ============================================================================
// Dongle
// ============================================================================

pub const Dongle = struct {
    ptr: *c.licd_device,
    ctx: *Context,
    closed: bool = false,

    pub fn close(self: *Dongle) void {
        if (!self.closed) {
            self.closed = true;
            c.licd_close(self.ptr);
        }
    }

    fn device(self: *Dongle) Error!*c.licd_device {
        if (self.closed) return Error.InvalidArgument;
        return self.ptr;
    }

    pub fn getInfo(self: *Dongle) Error!Info {
        var raw: c.licd_info = std.mem.zeroes(c.licd_info);
        try self.ctx.check(c.licd_get_info(try self.device(), &raw));
        return .{
            .protocol_major = raw.proto_version_major,
            .protocol_minor = raw.proto_version_minor,
            .firmware_major = raw.fw_version_major,
            .firmware_minor = raw.fw_version_minor,
            .firmware_patch = raw.fw_version_patch,
            .se_ready = raw.se_ready != 0,
            .provisioned = raw.provisioned != 0,
            .data_capacity = raw.data_capacity,
            .data_free = raw.data_free,
            .watchdog_reboot = raw.watchdog_reboot != 0,
            .isolated = raw.isolated != 0,
        };
    }

    pub fn getSerial(self: *Dongle) Error!FixedString {
        var buffer: [c.LICD_SERIAL_HEX_LEN + 1]u8 = undefined;
        try self.ctx.check(c.licd_get_serial(try self.device(), &buffer, buffer.len));
        return FixedString.fromC(&buffer);
    }

    /// Validates the device certificate chain to the trusted root and checks a
    /// live ECDSA challenge-response. Errors unless the dongle is genuine.
    pub fn verifyGenuine(self: *Dongle) Error!GenuineResult {
        var raw: c.licd_genuine_result = std.mem.zeroes(c.licd_genuine_result);
        try self.ctx.check(c.licd_verify_genuine(try self.device(), &raw));
        return .{
            .genuine = raw.genuine != 0,
            .serial = FixedString.fromC(&raw.serial),
            .batch = FixedString.fromC(&raw.batch),
            .provisioned_date = FixedString.fromC(&raw.provisioned_date),
        };
    }

    /// Non-erroring form for a licence gate. Fails closed: a missing dongle, an
    /// I/O error and an invalid certificate all report false.
    pub fn isGenuine(self: *Dongle) bool {
        const result = self.verifyGenuine() catch return false;
        return result.genuine;
    }

    pub fn openSession(self: *Dongle) Error!Session {
        try self.ctx.check(c.licd_session_open(try self.device()));
        return Session{ .dongle = self };
    }
};

// ============================================================================
// Session
// ============================================================================

pub const Session = struct {
    dongle: *Dongle,
    open: bool = true,

    /// Ends the session, zeroizing the session keys on the dongle. Idempotent.
    pub fn close(self: *Session) void {
        if (self.open) {
            self.open = false;
            if (!self.dongle.closed) {
                _ = c.licd_session_close(self.dongle.ptr);
            }
        }
    }

    fn device(self: *Session) Error!*c.licd_device {
        if (!self.open) return Error.SessionExpired;
        return self.dongle.device();
    }

    fn ctx(self: *Session) *Context {
        return self.dongle.ctx;
    }

    /// Elevates to the write role with the developer master key. Vendor tooling
    /// only — never ship that key in an application.
    pub fn authorizeWrite(self: *Session, master_key_der: []const u8) Error!void {
        try self.ctx().check(c.licd_write_auth(try self.device(), master_key_der.ptr, master_key_der.len));
    }

    /// Records stored on the dongle. Free with `freeRecords`.
    pub fn listRecords(self: *Session, allocator: std.mem.Allocator) ![]RecordInfo {
        var names: [*c][*c]u8 = null;
        var sizes: [*c]u32 = null;
        var count: usize = 0;
        try self.ctx().check(c.licd_record_list(try self.device(), &names, &sizes, &count));
        defer if (names != null) c.licd_free_record_list(names, sizes, count);

        var out = try allocator.alloc(RecordInfo, count);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |record| allocator.free(record.name);
            allocator.free(out);
        }
        while (filled < count) {
            const name = std.mem.sliceTo(names[filled], 0);
            out[filled] = .{ .name = try allocator.dupe(u8, name), .size = sizes[filled] };
            filled += 1;
        }
        return out;
    }

    pub fn freeRecords(allocator: std.mem.Allocator, records: []RecordInfo) void {
        for (records) |record| allocator.free(record.name);
        allocator.free(records);
    }

    /// Reads a record in full. Caller owns the returned bytes.
    pub fn readRecord(self: *Session, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return self.readRecordWithProgress(allocator, name, null);
    }

    pub fn readRecordWithProgress(
        self: *Session,
        allocator: std.mem.Allocator,
        name: []const u8,
        progress: ?*const Progress,
    ) ![]u8 {
        var name_buf: [128]u8 = undefined;
        const cname = try nameToC(name, &name_buf);
        const dev = try self.device();

        // Probe for the size first, so progress runs monotonically 0 -> total.
        var probe: [1]u8 = undefined;
        var got: u32 = 0;
        var total: u32 = 0;
        try self.ctx().check(c.licd_record_read(dev, cname, 0, &probe, 1, &got, &total, null, null));
        if (total == 0) return allocator.alloc(u8, 0);

        const buffer = try allocator.alloc(u8, total);
        errdefer allocator.free(buffer);
        const rc = c.licd_record_read(
            dev,
            cname,
            0,
            buffer.ptr,
            total,
            &got,
            &total,
            if (progress != null) progressTrampoline else null,
            @constCast(@ptrCast(progress)),
        );
        try self.ctx().check(rc);
        return allocator.realloc(buffer, got) catch buffer[0..got];
    }

    /// Atomically replaces a record. Requires the write role.
    pub fn writeRecord(self: *Session, name: []const u8, data: []const u8) Error!void {
        return self.writeRecordWithProgress(name, data, null);
    }

    pub fn writeRecordWithProgress(
        self: *Session,
        name: []const u8,
        data: []const u8,
        progress: ?*const Progress,
    ) Error!void {
        var name_buf: [128]u8 = undefined;
        const cname = try nameToC(name, &name_buf);
        const rc = c.licd_record_write(
            try self.device(),
            cname,
            data.ptr,
            @intCast(data.len),
            if (progress != null) progressTrampoline else null,
            @constCast(@ptrCast(progress)),
        );
        try self.ctx().check(rc);
    }

    /// Erases one record. Requires the write role.
    pub fn eraseRecord(self: *Session, name: []const u8) Error!void {
        // A null name means "erase everything" to the C API; that is
        // `eraseAllRecords` here, so an empty slice cannot wipe the dongle.
        var name_buf: [128]u8 = undefined;
        const cname = try nameToC(name, &name_buf);
        try self.ctx().check(c.licd_record_erase(try self.device(), cname));
    }

    /// Erases every record. Requires the write role.
    pub fn eraseAllRecords(self: *Session) Error!void {
        try self.ctx().check(c.licd_record_erase(try self.device(), null));
    }

    pub fn readCounter(self: *Session, counter_id: u8) Error!u32 {
        var value: u32 = 0;
        try self.ctx().check(c.licd_counter_read(try self.device(), counter_id, &value));
        return value;
    }

    /// Irreversible: the counter is monotonic in hardware. Requires the write role.
    pub fn incrementCounter(self: *Session, counter_id: u8) Error!u32 {
        var value: u32 = 0;
        try self.ctx().check(c.licd_counter_increment(try self.device(), counter_id, &value));
        return value;
    }

    /// Encrypts so only a dongle of `scope` can decrypt. This is the pair to build
    /// a licence check on: put something the program needs through it, so removing
    /// the check removes the data.
    pub fn appEncrypt(self: *Session, allocator: std.mem.Allocator, scope: Scope, plaintext: []const u8) ![]u8 {
        var out: [*c]u8 = null;
        var out_len: u32 = 0;
        try self.ctx().check(c.licd_app_encrypt(
            try self.device(),
            // @intCast rather than @intFromEnum alone: translate-c renders the C
            // enum as unsigned because none of its values are negative, and that
            // choice is not something to depend on across Zig releases.
            @intCast(@intFromEnum(scope)),
            plaintext.ptr,
            @intCast(plaintext.len),
            &out,
            &out_len,
        ));
        return takeBuffer(allocator, out, out_len);
    }

    pub fn appDecrypt(self: *Session, allocator: std.mem.Allocator, packed_blob: []const u8) ![]u8 {
        var out: [*c]u8 = null;
        var out_len: u32 = 0;
        try self.ctx().check(c.licd_app_decrypt(
            try self.device(),
            packed_blob.ptr,
            @intCast(packed_blob.len),
            &out,
            &out_len,
        ));
        return takeBuffer(allocator, out, out_len);
    }
};

fn nameToC(name: []const u8, buffer: []u8) Error![*:0]const u8 {
    if (name.len == 0 or name.len >= buffer.len) return Error.InvalidArgument;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = 0;
    return @ptrCast(buffer.ptr);
}

/// Copies a library-allocated buffer into Zig-owned memory and frees the original.
fn takeBuffer(allocator: std.mem.Allocator, out: [*c]u8, len: u32) ![]u8 {
    defer if (out != null) c.licd_free_buffer(out);
    if (out == null or len == 0) return allocator.alloc(u8, 0);
    return allocator.dupe(u8, out[0..len]);
}
