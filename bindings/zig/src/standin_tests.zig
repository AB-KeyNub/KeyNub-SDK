//! Every call of the binding against the C ABI stand-in:
//! bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory,
//! which build.zig compiles into the shared library keynub_licdongle_standin and
//! links. No dongle and no native library needed:
//!
//!     zig build standin-test
//!
//! The stand-in keeps records, counters and the write key per opened device, so
//! each test starts from a fresh dongle.

const std = @import("std");
const keynub = @import("licdongle.zig");
const c = keynub.c;
const Error = keynub.Error;
const testing = std.testing;

const serial = "04A1B2C3D4E5F6";
const factory_key = [_]u8{ 0x30, 0x10, 0x01, 0x02, 0x03 };
const replacement_key = [_]u8{ 0x30, 0x11, 0x09, 0x08, 0x07, 0x06 };

fn recordLastDone(context: ?*anyopaque, done: u32, total: u32) bool {
    _ = total;
    const last: *u32 = @ptrCast(@alignCast(context.?));
    last.* = done;
    return true;
}

fn cancel(context: ?*anyopaque, done: u32, total: u32) bool {
    _ = context;
    _ = done;
    _ = total;
    return false;
}

test "stand-in: version, devices and open" {
    try testing.expectEqual(keynub.Version{ .major = 9, .minor = 8, .patch = 7 }, keynub.Context.libraryVersion());
    try testing.expectEqualStrings("no device", keynub.statusText(c.LICD_E_NO_DEVICE));

    var ctx = try keynub.Context.init();
    defer ctx.deinit();

    const devices = try ctx.enumerate(testing.allocator);
    defer testing.allocator.free(devices);
    try testing.expectEqual(@as(usize, 1), devices.len);
    try testing.expectEqualStrings(serial, devices[0].serial.slice());
    try testing.expectEqualStrings("stub:0", devices[0].path.slice());
    try testing.expectEqual(@as(u16, 0x1234), devices[0].vendor_id);
    try testing.expectEqual(@as(u16, 0xABCD), devices[0].product_id);

    try testing.expectError(Error.NoDevice, ctx.open("nope"));
    try testing.expectEqual(@as(c_int, c.LICD_E_NO_DEVICE), ctx.last_status);
    try testing.expectEqualStrings("no dongle with that serial", ctx.lastErrorDetail());
    // The binding has no open-by-path call.

    var first = try ctx.open(null);
    defer first.close();
    try testing.expectEqual(@as(c_int, c.LICD_OK), ctx.last_status);
    try testing.expectEqualStrings(serial, (try first.getSerial()).slice());
    var by_serial = try ctx.open(serial);
    defer by_serial.close();
    try testing.expectEqualStrings(serial, (try by_serial.getSerial()).slice());
}

test "stand-in: info and genuine" {
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var d = try ctx.open(null);
    defer d.close();

    try testing.expectEqual(keynub.Info{
        .protocol_major = 1,
        .protocol_minor = 0,
        .firmware_major = 2,
        .firmware_minor = 3,
        .firmware_patch = 4,
        .se_ready = true,
        .provisioned = true,
        .data_capacity = 1024 * 1024,
        .data_free = 1_000_000,
        .watchdog_reboot = false,
        .isolated = true,
        .writeauth_rotated = false,
    }, try d.getInfo());

    const g = try d.verifyGenuine();
    try testing.expect(g.genuine);
    try testing.expectEqualStrings(serial, g.serial.slice());
    try testing.expectEqualStrings("2026-08-15", g.provisioned_date.slice());
    try testing.expect(d.isGenuine());
}

test "stand-in: trust root" {
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var d = try ctx.open(null);
    defer d.close();

    try testing.expectError(Error.CertificateInvalid, ctx.setTrustRoot(&[_]u8{ 0x02, 0x01, 0x00 }));
    try testing.expectError(Error.InvalidArgument, ctx.setTrustRoot(&[_]u8{}));

    var root = [_]u8{0xAB} ** 132;
    root[0] = 0x30;
    root[1] = 0x82;
    root[2] = 0x01;
    root[3] = 0x00;
    try ctx.setTrustRoot(&root);
    try testing.expectError(Error.CertificateInvalid, d.verifyGenuine());
    try testing.expect(!d.isGenuine()); // fails closed

    @memset(root[4..], 0x01);
    try ctx.setTrustRoot(&root);
    try testing.expect(d.isGenuine());
}

test "stand-in: records and the write role" {
    const allocator = testing.allocator;
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var d = try ctx.open(null);
    defer d.close();
    var s = try d.openSession();
    defer s.close();

    const payload = "license-blob-0123456789";
    try testing.expectError(Error.AuthRequired, s.writeRecord("lic", payload));
    try testing.expectError(Error.AuthRequired, s.eraseRecord("lic"));
    try testing.expectError(Error.AuthRequired, s.eraseAllRecords());
    try testing.expectError(Error.AuthRequired, s.incrementCounter(0));
    try testing.expectError(Error.NotGenuine, s.authorizeWrite(&[_]u8{ 0x30, 0x00 }));

    try s.authorizeWrite(&factory_key);
    try s.writeRecord("lic", payload);
    {
        const back = try s.readRecord(allocator, "lic");
        defer allocator.free(back);
        try testing.expectEqualStrings(payload, back);
    }
    try s.writeRecord("cfg", "cfgdata");
    {
        const records = try s.listRecords(allocator);
        defer keynub.Session.freeRecords(allocator, records);
        try testing.expectEqual(@as(usize, 2), records.len);
        var seen_lic = false;
        var seen_cfg = false;
        for (records) |r| {
            if (std.mem.eql(u8, r.name, "lic")) {
                seen_lic = true;
                try testing.expectEqual(@as(u32, payload.len), r.size);
            }
            if (std.mem.eql(u8, r.name, "cfg")) seen_cfg = true;
        }
        try testing.expect(seen_lic and seen_cfg);
    }
    {
        const cfg = try s.readRecord(allocator, "cfg");
        defer allocator.free(cfg);
        try testing.expectEqualStrings("cfgdata", cfg);
    }
    try testing.expectError(Error.NotFound, s.readRecord(allocator, "nope"));
    try testing.expectError(Error.NotFound, s.eraseRecord("nope"));

    // An empty name is refused by the binding, never passed on as "erase everything".
    try testing.expectError(Error.InvalidArgument, s.eraseRecord(""));
    try testing.expectError(Error.InvalidArgument, s.readRecord(allocator, ""));
    try testing.expectError(Error.InvalidArgument, s.writeRecord("", payload));
    {
        const records = try s.listRecords(allocator);
        defer keynub.Session.freeRecords(allocator, records);
        try testing.expectEqual(@as(usize, 2), records.len);
    }
    try s.eraseRecord("cfg");
    {
        const records = try s.listRecords(allocator);
        defer keynub.Session.freeRecords(allocator, records);
        try testing.expectEqual(@as(usize, 1), records.len);
        try testing.expectEqualStrings("lic", records[0].name);
    }

    try s.writeRecord("empty", "");
    {
        const empty = try s.readRecord(allocator, "empty");
        defer allocator.free(empty);
        try testing.expectEqual(@as(usize, 0), empty.len);
    }

    // Bigger than one transfer chunk, with progress and cancellation.
    var big: [3000]u8 = undefined;
    for (&big, 0..) |*b, k| b.* = @truncate(k *% 31 +% 5);
    var last: u32 = 0;
    const track = keynub.Progress{ .context = &last, .callback = recordLastDone };
    try s.writeRecordWithProgress("big", &big, &track);
    try testing.expectEqual(@as(u32, big.len), last);
    last = 0;
    {
        const read = try s.readRecordWithProgress(allocator, "big", &track);
        defer allocator.free(read);
        try testing.expectEqualSlices(u8, &big, read);
        try testing.expectEqual(@as(u32, big.len), last);
    }
    const stop = keynub.Progress{ .callback = cancel };
    try testing.expectError(Error.Cancelled, s.readRecordWithProgress(allocator, "big", &stop));
    {
        const again = try s.readRecord(allocator, "big");
        defer allocator.free(again);
        try testing.expectEqualSlices(u8, &big, again);
    }

    try s.eraseAllRecords();
    {
        const records = try s.listRecords(allocator);
        defer keynub.Session.freeRecords(allocator, records);
        try testing.expectEqual(@as(usize, 0), records.len);
    }
}

test "stand-in: counters" {
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var d = try ctx.open(null);
    defer d.close();
    var s = try d.openSession();
    defer s.close();
    try s.authorizeWrite(&factory_key);

    const before = try s.readCounter(0);
    try testing.expectEqual(before + 1, try s.incrementCounter(0));
    try testing.expectEqual(before + 1, try s.readCounter(0));
    try testing.expectEqual(@as(u32, 0), try s.readCounter(1));
    try testing.expectError(Error.OutOfRange, s.readCounter(7));
    try testing.expectError(Error.OutOfRange, s.incrementCounter(7));
}

test "stand-in: app encrypt and decrypt" {
    const allocator = testing.allocator;
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var d = try ctx.open(null);
    defer d.close();
    var s = try d.openSession();
    defer s.close();

    var secret: [100]u8 = undefined;
    for (&secret, 0..) |*b, k| b.* = @intCast((3 * k + 7) % 256);
    for ([_]keynub.Scope{ .device, .developer }) |scope| {
        const blob = try s.appEncrypt(allocator, scope, &secret);
        defer allocator.free(blob);
        try testing.expect(blob.len > secret.len);
        try testing.expectEqual(@as(u8, @intCast(@intFromEnum(scope))), blob[0]);
        const plain = try s.appDecrypt(allocator, blob);
        defer allocator.free(plain);
        try testing.expectEqualSlices(u8, &secret, plain);

        const tampered = try allocator.dupe(u8, blob);
        defer allocator.free(tampered);
        tampered[tampered.len - 1] ^= 1;
        try testing.expectError(Error.TagMismatch, s.appDecrypt(allocator, tampered));
    }
    const empty_blob = try s.appEncrypt(allocator, .device, "");
    defer allocator.free(empty_blob);
    const empty = try s.appDecrypt(allocator, empty_blob);
    defer allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "stand-in: write-key rotation" {
    const allocator = testing.allocator;
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var d = try ctx.open(null);
    defer d.close();

    {
        var s = try d.openSession();
        defer s.close();
        try testing.expectError(Error.AuthRequired, s.rotateWriteKey(&replacement_key));
        try s.authorizeWrite(&factory_key);
        try s.rotateWriteKey(&replacement_key);
        try s.writeRecord("lic", "still-writable"); // the session keeps its role
    }
    try testing.expect((try d.getInfo()).writeauth_rotated);

    var s = try d.openSession();
    defer s.close();
    try testing.expectError(Error.NotGenuine, s.authorizeWrite(&factory_key));
    try s.authorizeWrite(&replacement_key);
    try s.writeRecord("lic", "new-key-writes");
    const back = try s.readRecord(allocator, "lic");
    defer allocator.free(back);
    try testing.expectEqualStrings("new-key-writes", back);
}

test "stand-in: session and close semantics" {
    const allocator = testing.allocator;
    var ctx = try keynub.Context.init();
    defer ctx.deinit();
    var d = try ctx.open(null);

    // Closing one session ends the device's session, so the other one is refused by the device.
    var stale = try d.openSession();
    var s = try d.openSession();
    s.close();
    try testing.expectError(Error.SessionExpired, stale.listRecords(allocator));
    try testing.expectEqual(@as(c_int, c.LICD_E_SESSION_EXPIRED), ctx.last_status);
    stale.close();
    s.close(); // idempotent
    try testing.expectError(Error.SessionExpired, s.readCounter(0));

    var orphan = try d.openSession();
    d.close();
    d.close(); // idempotent
    try testing.expectError(Error.InvalidArgument, d.getSerial());
    try testing.expectError(Error.InvalidArgument, orphan.readCounter(0));
    orphan.close();

    // adopt takes over a device handle opened through the C ABI.
    var dev: ?*c.licd_device = null;
    try testing.expectEqual(@as(c_int, c.LICD_OK), c.licd_open(ctx.ptr, null, &dev));
    var adopted = ctx.adopt(dev.?);
    defer adopted.close();
    try testing.expectEqualStrings(serial, (try adopted.getSerial()).slice());
}
