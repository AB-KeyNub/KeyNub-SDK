// KeyNub dongle check from Swift: enumerate -> open -> verify -> session ->
// read a record -> app-crypto round trip.
//
//   swift run verify_and_read
//
// Run from this checkout the package finds the native library in
// natives/<platform> on its own; elsewhere set KEYNUB_LICDONGLE_LIBRARY or
// Library.path first.
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// READ FIRST: docs/integration-security.md. This sample prints whether the dongle
// is genuine, which is the one thing a real licence check must not do: a printed
// boolean is a deleted line away from nothing. protectSomething() shows the shape
// that actually protects something.

import Foundation
import KeyNubLicDongle

func report(_ dongle: Dongle) throws {
    let info = try dongle.info()
    print("Protocol v\(info.protocolVersion.major).\(info.protocolVersion.minor), "
        + "firmware v\(info.firmwareVersion.major).\(info.firmwareVersion.minor).\(info.firmwareVersion.patch), "
        + "\(info.dataFree) of \(info.dataCapacity) bytes free.")

    if info.watchdogReboot {
        // The only trace a firmware hang leaves behind. Worth reporting to support.
        print("WARNING: this dongle's previous boot ended in a watchdog reset.")
    }

    let result = try dongle.verifyGenuine()
    print("Genuine: \(result.genuine) (serial \(result.serial), provisioned \(result.provisionedDate))")
}

func readRecords(_ s: Session) throws {
    let records = try s.records()
    print("\(records.count) record(s) on the dongle:")
    for record in records {
        print("  \(record.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(record.size) bytes")
    }

    // A missing record is a normal state, not an error.
    if records.contains(where: { $0.name == "license" }) {
        let data = try s.readRecord("license")
        print("Read \(data.count) bytes from the license record.")
    }
}

// The part that actually protects something. At licence-issue time you would call
// appEncrypt once, with a developer dongle, and ship only the sealed data; the
// program then cannot proceed without a dongle, because it holds no other copy.
// .developer lets any dongle you have issued decrypt it, so one file serves every
// customer; .device locks it to one dongle.
func protectSomething(_ s: Session) throws {
    let needed = Array("the data this program cannot run without".utf8)

    let sealed = try s.appEncrypt(needed, scope: .developer)
    let recovered = try s.appDecrypt(sealed)

    print("App-crypto round trip: \(needed.count) bytes -> \(sealed.count) sealed -> "
        + (recovered == needed ? "recovered intact" : "MISMATCH"))
}

do {
    let version = try libraryVersion()
    print("KeyNub SDK \(version.major).\(version.minor).\(version.patch) (\(Library.loadedPath ?? "?"))")

    let ctx = try Context()
    defer { ctx.close() }
    let dongles = try ctx.enumerate()
    print("Found \(dongles.count) KeyNub dongle(s).")
    for (i, d) in dongles.enumerated() {
        print("  [\(i)] serial \(d.serial)")
    }
    if dongles.isEmpty {
        print("No dongle attached; nothing to do.")
        exit(0)
    }

    let dongle = try ctx.open()                  // first dongle, or ctx.open(serial:)
    defer { dongle.close() }
    try report(dongle)
    try dongle.withSession { s in
        try readRecords(s)
        try protectSomething(s)
    }
} catch {
    // Every failure carries the SDK's detail, which is what tells "no dongle"
    // from "certificate rejected".
    FileHandle.standardError.write("KeyNub error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
