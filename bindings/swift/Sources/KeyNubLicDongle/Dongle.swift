// An open dongle: plaintext information, authenticity, and its sessions.

import CLicDongle
import Foundation

/// Plaintext device information from `Dongle.info()`.
public struct Info: Sendable, Equatable {
    public let protocolVersion: (major: Int, minor: Int)
    public let firmwareVersion: (major: Int, minor: Int, patch: Int)
    /// The secure element responded.
    public let secureElementReady: Bool
    /// Factory provisioning is complete.
    public let provisioned: Bool
    public let dataCapacity: UInt32
    public let dataFree: UInt32
    /// The dongle's *previous* boot ended in a watchdog timeout: the firmware
    /// hung and reset itself. The only trace a field hang leaves; log it.
    public let watchdogReboot: Bool
    /// The dongle confirmed at boot that its USB code is fenced off from keys
    /// and storage.
    public let isolated: Bool
    /// The write key has been rotated away from the public factory one. Rotate
    /// on receipt, and check this before shipping a dongle to anyone.
    public let writeAuthRotated: Bool

    public static func == (a: Info, b: Info) -> Bool {
        a.protocolVersion == b.protocolVersion && a.firmwareVersion == b.firmwareVersion
            && a.secureElementReady == b.secureElementReady && a.provisioned == b.provisioned
            && a.dataCapacity == b.dataCapacity && a.dataFree == b.dataFree
            && a.watchdogReboot == b.watchdogReboot && a.isolated == b.isolated
            && a.writeAuthRotated == b.writeAuthRotated
    }
}

/// The result of a successful `Dongle.verifyGenuine()`.
public struct GenuineResult: Sendable, Equatable {
    public let genuine: Bool
    /// The serial from the verified certificate.
    public let serial: String
    /// `"YYYY-MM-DD"`, or `""`.
    public let provisionedDate: String
}

/// An open connection to one dongle. Obtained from `Context.open`.
public final class Dongle {
    /// The context this dongle was opened on.
    public let context: Context
    let api: API
    private var handle: OpaquePointer?
    private let lock = NSLock()

    init(context: Context, handle: OpaquePointer) {
        self.context = context
        self.api = context.api
        self.handle = handle
    }

    deinit {
        close()
    }

    /// `true` while the dongle can be used.
    public var isOpen: Bool { lock.withLock { handle != nil } }

    /// Releases the dongle. Safe to call more than once.
    public func close() {
        lock.withLock {
            if let h = handle {
                api.close(h)
                handle = nil
            }
        }
    }

    func requireHandle() throws -> OpaquePointer {
        guard let h = lock.withLock({ handle }) else {
            throw LicenseDongleError(status: Status.invalidArgument.rawValue, operation: "licd_device",
                                     detail: "the dongle has been closed")
        }
        return h
    }

    var contextHandle: OpaquePointer? { try? context.requireHandle() }

    /// Plaintext device information; needs no session.
    public func info() throws -> Info {
        let h = try requireHandle()
        var raw = licd_info()
        try check(api, api.getInfo(h, &raw), "licd_get_info", context: contextHandle)
        return Info(
            protocolVersion: (Int(raw.proto_version_major), Int(raw.proto_version_minor)),
            firmwareVersion: (Int(raw.fw_version_major), Int(raw.fw_version_minor), Int(raw.fw_version_patch)),
            secureElementReady: raw.se_ready != 0,
            provisioned: raw.provisioned != 0,
            dataCapacity: raw.data_capacity,
            dataFree: raw.data_free,
            watchdogReboot: raw.watchdog_reboot != 0,
            isolated: raw.isolated != 0,
            writeAuthRotated: raw.writeauth_rotated != 0
        )
    }

    /// The dongle's serial as hex.
    public func serial() throws -> String {
        let h = try requireHandle()
        var buffer = [CChar](repeating: 0, count: Int(LICD_SERIAL_HEX_LEN) + 1)
        let rc = buffer.withUnsafeMutableBufferPointer { api.getSerial(h, $0.baseAddress, $0.count) }
        try check(api, rc, "licd_get_serial", context: contextHandle)
        return String(cString: buffer)
    }

    /// Proves authenticity: the certificate chain to the trusted root plus a
    /// live challenge-response. Throws unless the dongle is genuine.
    public func verifyGenuine() throws -> GenuineResult {
        let h = try requireHandle()
        var raw = licd_genuine_result()
        try check(api, api.verifyGenuine(h, &raw), "licd_verify_genuine", context: contextHandle)
        guard raw.genuine != 0 else {
            throw LicenseDongleError(status: Status.notGenuine.rawValue, operation: "licd_verify_genuine", detail: "")
        }
        return GenuineResult(genuine: true, serial: cString(raw.serial), provisionedDate: cString(raw.provisioned_date))
    }

    /// The non-throwing form of `verifyGenuine()`, for a gate. **Fails closed**:
    /// a missing dongle, an I/O error and an invalid certificate all give `false`.
    public var isGenuine: Bool {
        (try? verifyGenuine()) != nil
    }

    /// Opens the encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM) that
    /// records, counters and app-data encryption need. Close it with
    /// `Session.close()`, or use `withSession`.
    public func openSession() throws -> Session {
        let h = try requireHandle()
        try check(api, api.sessionOpen(h), "licd_session_open", context: contextHandle)
        return Session(dongle: self)
    }

    /// Opens a session, runs `body` with it and closes the session afterwards,
    /// whatever happens inside `body`.
    public func withSession<T>(_ body: (Session) throws -> T) throws -> T {
        let session = try openSession()
        defer { session.close() }
        return try body(session)
    }

    func closeSession() {
        guard let h = lock.withLock({ handle }) else { return }
        _ = api.sessionClose(h)
    }
}
