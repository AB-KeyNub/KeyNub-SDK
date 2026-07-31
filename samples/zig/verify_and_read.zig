//! KeyNub dongle check from Zig: enumerate -> open -> verify -> session ->
//! read a record -> app-crypto round trip.
//!
//!   zig build run -Dkeynub-lib-dir=../../build
//!
//! Targets real hardware: with no dongle attached it prints guidance and exits 0.
//!
//! READ FIRST: docs/integration-security.md. This sample prints whether the dongle
//! is genuine, which is the one thing a real licence check must not do — a printed
//! boolean is a deleted line away from nothing. `protectSomething` shows the shape
//! that actually protects something.
//!
//! Zig is the one binding whose declarations cannot drift from the ABI: `@cImport`
//! compiles the real `licdongle.h`, so a changed prototype is a compile error here
//! rather than a wrong call at run time. Allocation is explicit, as everywhere in
//! Zig — the calls that return variable-length data take an allocator and the
//! caller frees.

const std = @import("std");
const keynub = @import("keynub_licdongle");

fn report(dongle: *keynub.Dongle) !void {
    const info = try dongle.getInfo();
    std.debug.print("Protocol v{d}.{d}, firmware v{d}.{d}.{d}, {d} of {d} bytes free.\n", .{
        info.protocol_major, info.protocol_minor,
        info.firmware_major, info.firmware_minor, info.firmware_patch,
        info.data_free,     info.data_capacity,
    });

    if (info.watchdog_reboot) {
        // The only trace a firmware hang leaves behind. Worth reporting to support.
        std.debug.print("WARNING: this dongle's previous boot ended in a watchdog reset.\n", .{});
    }

    const result = try dongle.verifyGenuine();
    std.debug.print("Genuine: {} (serial {s}, batch {s})\n", .{
        result.genuine, result.serial.slice(), result.batch.slice(),
    });
}

fn readRecords(session: *keynub.Session, allocator: std.mem.Allocator) !void {
    const records = try session.listRecords(allocator);
    defer keynub.Session.freeRecords(allocator, records);

    std.debug.print("{d} record(s) on the dongle:\n", .{records.len});
    for (records) |record| {
        std.debug.print("  {s: <16} {d: >6} bytes\n", .{ record.name, record.size });
    }

    // A missing record is a normal state, not an error.
    for (records) |record| {
        if (std.mem.eql(u8, record.name, "license")) {
            const data = try session.readRecord(allocator, "license");
            defer allocator.free(data);
            std.debug.print("Read {d} bytes from the license record.\n", .{data.len});
            break;
        }
    }
}

/// The part that actually protects something. At licence-issue time you would call
/// appEncrypt once, with a developer dongle, and ship only the blob; the program
/// then cannot proceed without a dongle, because it holds no other copy of the data.
/// `.developer` lets any dongle from your batch decrypt it, so one file serves every
/// customer; `.device` locks it to one dongle.
fn protectSomething(session: *keynub.Session, allocator: std.mem.Allocator) !void {
    const needed = "the data this program cannot run without";

    const sealed = try session.appEncrypt(allocator, .developer, needed);
    defer allocator.free(sealed);

    const recovered = try session.appDecrypt(allocator, sealed);
    defer allocator.free(recovered);

    std.debug.print("App-crypto round trip: {d} bytes -> {d} sealed -> {s}\n", .{
        needed.len,
        sealed.len,
        if (std.mem.eql(u8, recovered, needed)) "recovered intact" else "MISMATCH",
    });
}

fn run(allocator: std.mem.Allocator) !void {
    var ctx = try keynub.Context.init();
    defer ctx.deinit();

    const devices = try ctx.enumerate(allocator);
    defer allocator.free(devices);

    std.debug.print("Found {d} KeyNub dongle(s).\n", .{devices.len});
    for (devices, 0..) |d, i| {
        std.debug.print("  [{d}] serial {s} (VID {X:0>4} PID {X:0>4})\n", .{
            i, d.serial.slice(), d.vendor_id, d.product_id,
        });
    }
    if (devices.len == 0) {
        std.debug.print("No dongle attached; nothing to do.\n", .{});
        return;
    }

    // null = first dongle found; pass a serial to pick a specific one.
    var dongle = try ctx.open(null);
    defer dongle.close();
    try report(&dongle);

    var session = try dongle.openSession();
    defer session.close();
    try readRecords(&session, allocator);
    try protectSomething(&session, allocator);
}

pub fn main() !void {
    // Reports leaks on deinit, which is what you want while integrating.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const v = keynub.Context.libraryVersion();
    std.debug.print("KeyNub SDK {d}.{d}.{d}\n", .{ v.major, v.minor, v.patch });

    run(allocator) catch |err| {
        // The error set distinguishes the cases; lastErrorDetail on the context
        // carries the SDK's diagnostic text, which is what tells "no dongle" from
        // "certificate rejected".
        std.debug.print("KeyNub error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
