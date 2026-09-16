// Tests against a stand-in for the C ABI: the SDK's bindings/julia/test/stub/
// licd_stub.c, one imaginary dongle held in memory, compiled here with the C
// compiler on the path and loaded through Library.path. Every call of the
// package runs end to end without hardware. KEYNUB_LICDONGLE_LIBRARY naming an
// already compiled stand-in skips the build.

import Foundation
import XCTest
@testable import KeyNubLicDongle

final class StubTests: XCTestCase {
    static let factoryKey: [UInt8] = [0x30, 0x10, 0x01, 0x02, 0x03]
    static let replacementKey: [UInt8] = [0x30, 0x11, 0x09, 0x08, 0x07, 0x06]
    static let serial = "04A1B2C3D4E5F6"
    static var stub: Result<String, Error>?

    override class func setUp() {
        super.setUp()
        guard stub == nil else { return }
        if let env = ProcessInfo.processInfo.environment["KEYNUB_LICDONGLE_LIBRARY"], !env.isEmpty {
            stub = .success(env)
        } else {
            stub = Result { try buildStub() }
        }
        if case .success(let path)? = stub {
            Library.path = path
        }
    }

    struct BuildFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Compiles the stand-in into a temporary directory and returns its path.
    static func buildStub() throws -> String {
        let root = Loader.repositoryRoot
        // The stand-in ships in the public repository; KEYNUB_STUB_SOURCE names it
        // from anywhere else.
        let env = ProcessInfo.processInfo.environment
        let source = env["KEYNUB_STUB_SOURCE"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("bindings/julia/test/stub/licd_stub.c")
        let include = ["include", "core/include"]
            .map { root.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("licdongle.h").path) }
        guard FileManager.default.fileExists(atPath: source.path), let include = include else {
            throw BuildFailure(description: "no stand-in source (\(source.path)) or header under \(root.path)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keynub-swift-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(macOS)
        let out = dir.appendingPathComponent("liblicd_stub.dylib").path
        #else
        let out = dir.appendingPathComponent("liblicd_stub.so").path
        #endif
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        cc.arguments = ["cc", "-shared", "-fPIC", "-O1", "-DLICD_BUILD_SHARED", "-I", include.path, "-o", out, source.path]
        let pipe = Pipe()
        cc.standardError = pipe
        cc.standardOutput = pipe
        try cc.run()
        cc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard cc.terminationStatus == 0 else {
            throw BuildFailure(description: "cc failed (\(cc.terminationStatus)): \(output)")
        }
        return out
    }

    func stubPath() throws -> String {
        try XCTUnwrap(StubTests.stub).get()
    }

    /// Runs body against the stand-in and always tears down.
    func withDevice(_ body: (Context, Dongle) throws -> Void) throws {
        _ = try stubPath()
        let ctx = try Context()
        defer { ctx.close() }
        let dongle = try ctx.open()
        defer { dongle.close() }
        try body(ctx, dongle)
    }

    func expectError<T>(_ status: Status, _ what: String, file: StaticString = #filePath, line: UInt = #line,
                        _ body: () throws -> T) -> LicenseDongleError? {
        do {
            _ = try body()
            XCTFail("\(what): no error was thrown", file: file, line: line)
            return nil
        } catch let error as LicenseDongleError {
            XCTAssertEqual(error.status, status, "\(what): \(error)", file: file, line: line)
            return error
        } catch {
            XCTFail("\(what): unexpected error \(error)", file: file, line: line)
            return nil
        }
    }

    func testLibraryAndStatusCodes() throws {
        let path = try stubPath()
        XCTAssertEqual(Library.resolvedPath, path)
        XCTAssertEqual(try libraryVersion().major, 9)
        XCTAssertEqual(try libraryVersion().minor, 8)
        XCTAssertEqual(try libraryVersion().patch, 7)
        XCTAssertEqual(Library.loadedPath, path)
        XCTAssertEqual(Status.noDevice.message, "no device")
        for status in Status.allCases {
            XCTAssertFalse(status.message.isEmpty)
        }
        let error = LicenseDongleError(status: -2, operation: "licd_op", detail: "the detail")
        XCTAssertEqual(error.status, .noDevice)
        XCTAssertEqual(error.description, "licd_op: no device (the detail)")
        XCTAssertEqual(LicenseDongleError(status: -4, operation: "licd_op", detail: "").description, "licd_op: I/O error")
        XCTAssertEqual(LicenseDongleError(status: -99, operation: "x", detail: "").status, .internalError)
        XCTAssertTrue(["win-x64", "win-x86", "win-arm64", "linux-x64", "linux-arm64", "osx-x64", "osx-arm64"]
            .contains(Library.platform))
    }

    func testEnumerateAndOpen() throws {
        _ = try stubPath()
        let ctx = try Context()
        XCTAssertTrue(ctx.isOpen)
        let devices = try ctx.enumerate()
        XCTAssertEqual(devices, [DeviceInfo(serial: StubTests.serial, path: "stub:0", vendorID: 0x1234, productID: 0xABCD)])

        let error = expectError(.noDevice, "open with a wrong serial") { try ctx.open(serial: "nope") }
        XCTAssertEqual(error?.operation, "licd_open")
        XCTAssertEqual(error?.detail, "no dongle with that serial")
        XCTAssertEqual(ctx.lastErrorDetail, "no dongle with that serial")
        _ = expectError(.noDevice, "open at a wrong path") { try ctx.open(path: "stub:9") }

        for dongle in [try ctx.open(), try ctx.open(serial: StubTests.serial), try ctx.open(path: "stub:0")] {
            XCTAssertTrue(dongle.isOpen)
            XCTAssertEqual(try dongle.serial(), StubTests.serial)
            dongle.close()
            dongle.close()
            XCTAssertFalse(dongle.isOpen)
            _ = expectError(.invalidArgument, "a closed dongle refuses calls") { try dongle.serial() }
        }

        let dongle = try ctx.open()
        ctx.close()
        XCTAssertFalse(ctx.isOpen)
        XCTAssertFalse(dongle.isOpen, "closing the context closes its dongles")
        _ = expectError(.invalidArgument, "a closed context refuses calls") { try ctx.open() }
        ctx.close()
    }

    func testInfoSerialGenuine() throws {
        try withDevice { _, dongle in
            let info = try dongle.info()
            XCTAssertEqual(info.protocolVersion.major, 1)
            XCTAssertEqual(info.protocolVersion.minor, 0)
            XCTAssertEqual(info.firmwareVersion.major, 2)
            XCTAssertEqual(info.firmwareVersion.minor, 3)
            XCTAssertEqual(info.firmwareVersion.patch, 4)
            XCTAssertTrue(info.secureElementReady && info.provisioned && info.isolated)
            XCTAssertEqual(info.dataCapacity, 1024 * 1024)
            XCTAssertEqual(info.dataFree, 1_000_000)
            XCTAssertFalse(info.watchdogReboot)
            XCTAssertFalse(info.writeAuthRotated)

            let result = try dongle.verifyGenuine()
            XCTAssertEqual(result, GenuineResult(genuine: true, serial: StubTests.serial, provisionedDate: "2026-08-15"))
            XCTAssertTrue(dongle.isGenuine)
        }
    }

    func testTrustRoot() throws {
        try withDevice { ctx, dongle in
            _ = expectError(.invalidArgument, "an empty root") { try ctx.setTrustRoot([]) }
            _ = expectError(.certificateInvalid, "a non-DER root") { try ctx.setTrustRoot([0x02, 0x01, 0x00]) }
            try ctx.setTrustRoot([0x30, 0x82, 0x01, 0x00] + [UInt8](repeating: 0xAB, count: 128))
            _ = expectError(.certificateInvalid, "verification under a foreign root") { try dongle.verifyGenuine() }
            XCTAssertFalse(dongle.isGenuine, "isGenuine fails closed")
            try ctx.setTrustRoot([0x30, 0x82, 0x01, 0x00] + [UInt8](repeating: 0x01, count: 128))
            XCTAssertTrue(dongle.isGenuine)
        }
    }

    func testRecordsCountersCrypto() throws {
        try withDevice { _, dongle in
            try dongle.withSession { s in
                XCTAssertTrue(s.isOpen)
                let payload = Array("license-blob-0123456789".utf8)
                _ = expectError(.authRequired, "writing needs the write role") { try s.writeRecord("lic", payload) }
                _ = expectError(.notGenuine, "a wrong key") { try s.authorizeWrite(key: [0x30, 0x00]) }
                _ = expectError(.invalidArgument, "an empty key") { try s.authorizeWrite(key: []) }
                try s.authorizeWrite(key: StubTests.factoryKey)
                try s.writeRecord("lic", payload)
                XCTAssertEqual(try s.readRecord("lic"), payload)

                try s.writeRecord("cfg", "cfgdata")
                let records = try s.records()
                XCTAssertEqual(records.map(\.name).sorted(), ["cfg", "lic"])
                XCTAssertEqual(records.first { $0.name == "lic" }?.size, UInt32(payload.count))

                _ = expectError(.notFound, "reading a missing record") { try s.readRecord("nope") }
                _ = expectError(.notFound, "erasing a missing record") { try s.eraseRecord("nope") }
                _ = expectError(.invalidArgument, "an empty name never erases") { try s.eraseRecord("") }
                XCTAssertEqual(try s.records().count, 2)
                try s.eraseRecord("cfg")
                XCTAssertEqual(try s.records().map(\.name), ["lic"])

                try s.writeRecord("empty", [UInt8]())
                XCTAssertEqual(try s.readRecord("empty"), [])

                let before = try s.readCounter(0)
                XCTAssertEqual(try s.incrementCounter(0), before + 1)
                XCTAssertEqual(try s.readCounter(0), before + 1)
                XCTAssertEqual(try s.readCounter(1), 0)
                _ = expectError(.range, "a counter the dongle lacks") { try s.readCounter(7) }

                let secret = (0..<100).map { UInt8(($0 * 3 + 7) % 256) }
                for scope in [Scope.device, Scope.developer] {
                    let blob = try s.appEncrypt(secret, scope: scope)
                    XCTAssertGreaterThan(blob.count, secret.count)
                    XCTAssertEqual(blob[0], scope == .device ? 0 : 1)
                    XCTAssertEqual(try s.appDecrypt(blob), secret)
                    var tampered = blob
                    tampered[tampered.count - 1] ^= 0x01
                    _ = expectError(.tagMismatch, "tampered data") { try s.appDecrypt(tampered) }
                }
                XCTAssertEqual(try s.appDecrypt(s.appEncrypt(Array("text".utf8), scope: .device)), Array("text".utf8))
                XCTAssertEqual(try s.appDecrypt(s.appEncrypt([], scope: .device)), [])

                try s.eraseAllRecords()
                XCTAssertEqual(try s.records().count, 0)
            }
            // withSession closed the session on the device: a Session object made
            // without opening one (internal initialiser) meets the library's refusal.
            _ = expectError(.sessionExpired, "no session after withSession") { try Session(dongle: dongle).records() }
        }
    }

    func testRotation() throws {
        try withDevice { _, dongle in
            try dongle.withSession { s in
                _ = expectError(.authRequired, "rotation needs the write role") { try s.rotateWriteKey(StubTests.replacementKey) }
                try s.authorizeWrite(key: StubTests.factoryKey)
                _ = expectError(.invalidArgument, "an empty replacement key") { try s.rotateWriteKey([]) }
                try s.rotateWriteKey(StubTests.replacementKey)
                try s.writeRecord("lic", "still-writable")
            }
            XCTAssertTrue(try dongle.info().writeAuthRotated)
            try dongle.withSession { s in
                _ = expectError(.notGenuine, "the factory key no longer elevates") { try s.authorizeWrite(key: StubTests.factoryKey) }
                try s.authorizeWrite(key: StubTests.replacementKey)
                try s.writeRecord("lic", "new-key-writes")
                XCTAssertEqual(String(decoding: try s.readRecord("lic"), as: UTF8.self), "new-key-writes")
            }
        }
    }

    struct Boom: Error {}

    func testProgressAndCancellation() throws {
        try withDevice { _, dongle in
            try dongle.withSession { s in
                try s.authorizeWrite(key: StubTests.factoryKey)
                let blob = (0..<2000).map { UInt8(($0 * 31 + 5) % 256) }
                var writes: [(UInt32, UInt32)] = []
                try s.writeRecord("big", blob) { done, total in
                    writes.append((done, total))
                    return true
                }
                XCTAssertEqual(writes.last?.0, 2000)
                XCTAssertEqual(writes.last?.1, 2000)
                _ = expectError(.cancelled, "a false from progress cancels a write") {
                    try s.writeRecord("big2", blob) { _, _ in false }
                }

                var ticks: [(UInt32, UInt32)] = []
                let data = try s.readRecord("big") { done, total in
                    ticks.append((done, total))
                    return true
                }
                XCTAssertEqual(data, blob)
                XCTAssertEqual(ticks.count, 4)
                XCTAssertEqual(ticks.last?.0, 2000)
                _ = expectError(.cancelled, "a false from progress cancels a read") {
                    try s.readRecord("big") { _, _ in false }
                }
                do {
                    _ = try s.readRecord("big") { _, _ in throw Boom() }
                    XCTFail("an error thrown inside progress must propagate")
                } catch is Boom {
                    // The transfer was cancelled and the closure's error rethrown.
                } catch {
                    XCTFail("unexpected error \(error)")
                }
                XCTAssertEqual(try s.readRecord("big"), blob, "the dongle is usable afterwards")
            }
        }
    }

    func testClosedSessionAndDongle() throws {
        _ = try stubPath()
        let ctx = try Context()
        let dongle = try ctx.open()
        let s = try dongle.openSession()
        s.close()
        s.close()
        XCTAssertFalse(s.isOpen)
        _ = expectError(.sessionExpired, "a closed session refuses calls") { try s.readRecord("lic") }

        let second = try dongle.openSession()
        dongle.close()
        _ = expectError(.invalidArgument, "a session on a closed dongle") { try second.readRecord("lic") }
        second.close()
        ctx.close()
    }

    func testDeinitReleases() throws {
        _ = try stubPath()
        func leak() throws {
            let ctx = try Context()
            let dongle = try ctx.open()
            _ = try dongle.openSession()
            _ = try ctx.open()
        }
        try leak()
        var dongle: Dongle?
        do {
            let ctx = try Context()
            dongle = try ctx.open()
        }
        XCTAssertTrue(dongle?.isOpen ?? false, "a reachable dongle keeps its context alive")
        XCTAssertEqual(try dongle?.serial(), StubTests.serial)
        dongle?.close()
    }
}
