//! End-to-end tests for the Zig binding against the in-process device simulator,
//! mirroring the C, C++, Rust, Go, Fortran, COBOL and managed suites. No hardware.
//!
//!     zig build test -Dkeynub-lib-name=keynub_licdongle_sim -Dkeynub-lib-dir=../../build
//!
//! What these do *not* need to check is that the declarations match the header —
//! @cImport compiles the header itself, so a mismatch is a compile error rather
//! than something a test has to catch. They cover the wrapper: allocation and
//! ownership, the error mapping, the progress bridge, and lifetimes.

const std = @import("std");
const keynub = @import("licdongle.zig");
const c = keynub.c;

const fixture_serial = "0123456789ABCDEFEE";

// Exported by keynub_licdongle_sim only; the shipping library has neither.
extern fn licd_open_simulated(ctx: *c.licd_ctx, out_dev: *?*c.licd_device) c_int;
extern fn licd_test_get_master_key_der(out_der: *[*c]const u8, out_len: *u32) void;

fn openSimulated(ctx: *keynub.Context) !keynub.Dongle {
    var dev: ?*c.licd_device = null;
    const rc = licd_open_simulated(ctx.ptr, &dev);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    return ctx.adopt(dev.?);
}

fn masterKey() []const u8 {
    var der: [*c]const u8 = undefined;
    var len: u32 = 0;
    licd_test_get_master_key_der(&der, &len);
    return der[0..len];
}

test "library version is reported" {
    const version = keynub.Context.libraryVersion();
    try std.testing.expect(version.major >= 0);
}

test "enumerate succeeds whatever is attached" {
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    const devices = try ctx.enumerate(std.testing.allocator);
    defer std.testing.allocator.free(devices);
    // Deliberately no assertion on the count. This is the real hidapi path, so the answer
    // depends on what is plugged into the machine running the suite; asserting "empty"
    // made this suite fail on a bench with a dongle attached, which is a test bug rather
    // than a finding. What is under test is that enumeration succeeds at all.
    //
    // The not-found path is still worth covering, so assert it only when there is
    // genuinely nothing to find. CI runs without hardware, which is where it gates.
    if (devices.len == 0) {
        try std.testing.expectError(keynub.Error.NoDevice, ctx.open(null));
    }
}

test "info, serial and genuine" {
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var dongle = try openSimulated(&ctx);
    defer dongle.close();

    const info = try dongle.getInfo();
    try std.testing.expectEqual(@as(u8, 1), info.protocol_major);
    try std.testing.expect(info.se_ready);
    try std.testing.expect(info.provisioned);
    try std.testing.expectEqual(@as(u32, 1024 * 1024), info.data_capacity);
    // A healthy boot: false rather than garbage.
    try std.testing.expect(!info.watchdog_reboot);

    const serial = try dongle.getSerial();
    try std.testing.expectEqualStrings(fixture_serial, serial.slice());

    const result = try dongle.verifyGenuine();
    try std.testing.expect(result.genuine);
    try std.testing.expectEqualStrings(fixture_serial, result.serial.slice());
    try std.testing.expect(dongle.isGenuine());
}

test "the trust root is consulted" {
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var dongle = try openSimulated(&ctx);
    defer dongle.close();
    try std.testing.expect(dongle.isGenuine());

    // Replacing the fixture root with a bogus one must make the same device fail:
    // that proves setTrustRoot marshals AND is actually consulted.
    var bogus: [132]u8 = [_]u8{0xAB} ** 132;
    bogus[0] = 0x30;
    bogus[1] = 0x82;
    bogus[2] = 0x01;
    bogus[3] = 0x00;
    try ctx.setTrustRoot(&bogus);

    try std.testing.expectError(keynub.Error.CertificateInvalid, dongle.verifyGenuine());
    try std.testing.expect(!dongle.isGenuine()); // fails closed
    try std.testing.expectError(keynub.Error.InvalidArgument, ctx.setTrustRoot(&[_]u8{}));
}

test "records, counters and app-crypto" {
    const allocator = std.testing.allocator;
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var dongle = try openSimulated(&ctx);
    defer dongle.close();
    var session = try dongle.openSession();
    defer session.close();

    const payload = "license-blob-0123456789";

    // Writes need the write role, and the error says which.
    try std.testing.expectError(keynub.Error.AuthRequired, session.writeRecord("lic", payload));
    try session.authorizeWrite(masterKey());
    try session.writeRecord("lic", payload);

    const read = try session.readRecord(allocator, "lic");
    defer allocator.free(read);
    try std.testing.expectEqualStrings(payload, read);

    try session.writeRecord("cfg", "cfgdata");
    const records = try session.listRecords(allocator);
    defer keynub.Session.freeRecords(allocator, records);
    try std.testing.expectEqual(@as(usize, 2), records.len);

    try std.testing.expectError(keynub.Error.NotFound, session.readRecord(allocator, "nope"));

    // An empty name must not fall through to "erase everything".
    try std.testing.expectError(keynub.Error.InvalidArgument, session.eraseRecord(""));
    const still = try session.listRecords(allocator);
    defer keynub.Session.freeRecords(allocator, still);
    try std.testing.expectEqual(@as(usize, 2), still.len);

    const before = try session.readCounter(0);
    const after = try session.incrementCounter(0);
    try std.testing.expectEqual(before + 1, after);

    var secret: [100]u8 = undefined;
    for (&secret, 0..) |*byte, i| byte.* = @truncate(i * 3 + 7);

    for ([_]keynub.Scope{ .device, .developer }) |scope| {
        const blob = try session.appEncrypt(allocator, scope, &secret);
        defer allocator.free(blob);
        try std.testing.expect(blob.len > secret.len);
        try std.testing.expect(std.mem.indexOf(u8, blob, &secret) == null);

        const recovered = try session.appDecrypt(allocator, blob);
        defer allocator.free(recovered);
        try std.testing.expectEqualSlices(u8, &secret, recovered);

        // Tampering is rejected rather than yielding different plaintext.
        blob[blob.len - 1] ^= 1;
        try std.testing.expectError(keynub.Error.TagMismatch, session.appDecrypt(allocator, blob));
    }

    try session.eraseAllRecords();
    const none = try session.listRecords(allocator);
    defer keynub.Session.freeRecords(allocator, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "an empty record round-trips" {
    const allocator = std.testing.allocator;
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var dongle = try openSimulated(&ctx);
    defer dongle.close();
    var session = try dongle.openSession();
    defer session.close();
    try session.authorizeWrite(masterKey());

    try session.writeRecord("empty", "");
    const data = try session.readRecord(allocator, "empty");
    defer allocator.free(data);
    try std.testing.expectEqual(@as(usize, 0), data.len);
}

// Progress state for the callback below. A struct rather than a closure, because
// Zig has no closures — the context travels through the Progress struct.
const Ticks = struct {
    count: usize = 0,
    last_done: u32 = 0,
    last_total: u32 = 0,
    cancel: bool = false,

    fn callback(context: ?*anyopaque, done: u32, total: u32) bool {
        const self: *Ticks = @ptrCast(@alignCast(context.?));
        self.count += 1;
        self.last_done = done;
        self.last_total = total;
        return !self.cancel;
    }
};

test "progress is reported and can cancel" {
    const allocator = std.testing.allocator;
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var dongle = try openSimulated(&ctx);
    defer dongle.close();
    var session = try dongle.openSession();
    defer session.close();
    try session.authorizeWrite(masterKey());

    var blob: [2000]u8 = undefined; // > the 1 KB read chunk, so several ticks
    for (&blob, 0..) |*byte, i| byte.* = @truncate(i * 31 + 5);
    try session.writeRecord("big", &blob);

    var ticks = Ticks{};
    const progress = keynub.Progress{ .context = &ticks, .callback = Ticks.callback };
    const read = try session.readRecordWithProgress(allocator, "big", &progress);
    defer allocator.free(read);
    try std.testing.expectEqualSlices(u8, &blob, read);
    try std.testing.expect(ticks.count > 0);
    try std.testing.expectEqual(@as(u32, 2000), ticks.last_done);
    try std.testing.expectEqual(@as(u32, 2000), ticks.last_total);

    // Returning false cancels.
    var cancelling = Ticks{ .cancel = true };
    const cancel_progress = keynub.Progress{ .context = &cancelling, .callback = Ticks.callback };
    try std.testing.expectError(
        keynub.Error.Cancelled,
        session.readRecordWithProgress(allocator, "big", &cancel_progress),
    );

    // ... and the dongle still works afterwards.
    const again = try session.readRecord(allocator, "big");
    defer allocator.free(again);
    try std.testing.expectEqualSlices(u8, &blob, again);
}

test "a closed session and dongle are refused" {
    const allocator = std.testing.allocator;
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var dongle = try openSimulated(&ctx);
    defer dongle.close();

    var session = try dongle.openSession();
    session.close();
    session.close(); // idempotent
    try std.testing.expectError(keynub.Error.SessionExpired, session.readRecord(allocator, "lic"));

    // A session whose dongle went away reports it rather than using freed memory.
    var second = try dongle.openSession();
    dongle.close();
    try std.testing.expectError(keynub.Error.InvalidArgument, second.readRecord(allocator, "lic"));
    second.close(); // must not call into the freed device
}
