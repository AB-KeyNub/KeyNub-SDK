//! KeyNub SDK - Zig sample: take ownership of a new dongle.
//!
//! A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
//! that from the next session onward only your key can write records, erase them or
//! increment counters. Run it once per dongle, when it arrives.
//!
//! Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//!
//!   openssl ecparam -name prime256v1 -genkey -noout |
//!     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//!
//!   zig build rotate -Dkeynub-lib-dir=../../build -- ../../keys/keynub-shipping-writeauth.key.der my-key.der
//!
//! Targets real hardware: with no dongle attached it prints guidance and exits 0.
//!
//! `main` takes a `std.process.Init` because this sample needs the command line and
//! the filesystem, and both arrive through it: `init.minimal.args` and `init.io`.
//! The verify_and_read sample beside this one needs neither and so takes nothing.
//!
//! The replacement key is worth what your licence-signing key is worth. It cannot be
//! recovered from the dongle, and a unit rotated to a key you have lost has to come
//! back to be re-provisioned.

const std = @import("std");
const keynub = @import("keynub_licdongle");

const max_key: std.Io.Limit = .limited(4096);

fn run(init: std.process.Init, current: []const u8, replacement: []const u8) !u8 {
    var ctx = try keynub.Context.init();
    defer ctx.deinit();

    const devices = try ctx.enumerate(init.gpa);
    defer init.gpa.free(devices);
    if (devices.len == 0) {
        std.debug.print("Connect a KeyNub dongle and re-run.\n", .{});
        return 0;
    }

    // null = first dongle found; pass a serial to pick a specific one.
    var dongle = try ctx.open(null);
    defer dongle.close();
    const serial = try dongle.getSerial();
    std.debug.print("dongle {s}\n", .{serial.slice()});

    {
        var session = try dongle.openSession();
        defer session.close();
        try session.authorizeWrite(current);
        try session.rotateWriteKey(replacement);
        std.debug.print("rotated: this dongle now answers only to your key\n", .{});
    }

    // A fresh session is the only place the change is observable: the session
    // above keeps the role it was already granted.
    var session = try dongle.openSession();
    defer session.close();
    if (session.authorizeWrite(current)) |_| {
        std.debug.print("WARNING: the old key still works -- do not ship this unit\n", .{});
        return 1;
    } else |_| {
        std.debug.print("confirmed: the old key no longer elevates\n", .{});
    }
    try session.authorizeWrite(replacement);
    std.debug.print("confirmed: your key elevates\n", .{});

    std.debug.print("\nKeep the replacement key safe. Every future write to this " ++
        "dongle needs it.\n", .{});
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: rotate_write_key <current-key.der> <new-key.der>\n", .{});
        return 2;
    }

    const cwd = std.Io.Dir.cwd();
    const current = try cwd.readFileAlloc(init.io, args[1], init.gpa, max_key);
    defer init.gpa.free(current);
    const replacement = try cwd.readFileAlloc(init.io, args[2], init.gpa, max_key);
    defer init.gpa.free(replacement);

    return run(init, current, replacement) catch |err| {
        std.debug.print("KeyNub error: {s}\n", .{@errorName(err)});
        return 1;
    };
}
