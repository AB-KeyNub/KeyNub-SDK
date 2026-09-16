// The encrypted session: records, counters, the write role, app-data crypto.

import CLicDongle
import Foundation

/// Who can decrypt data produced by `Session.appEncrypt`.
public enum Scope: Sendable {
    /// Only the one physical dongle that encrypted it.
    case device
    /// Any dongle issued by the same developer, so one blob serves every customer.
    case developer

    var raw: licd_scope {
        switch self {
        case .device: return LICD_SCOPE_DEVICE
        case .developer: return LICD_SCOPE_DEVELOPER
        }
    }
}

/// One record as listed: its name and size in bytes.
public struct RecordInfo: Sendable, Equatable {
    public let name: String
    public let size: UInt32
}

/// Reports a transfer: `(done, total)` in bytes. Return `false` to cancel,
/// which makes the call throw `.cancelled`. An error thrown inside cancels the
/// transfer as well and is rethrown after the C frames have unwound.
public typealias Progress = (UInt32, UInt32) throws -> Bool

/// An open session on a dongle. Obtained from `Dongle.openSession()` or
/// `Dongle.withSession`. Reading needs the session; writing, erasing and
/// counter increments need the write role, see `authorizeWrite`.
public final class Session {
    /// The dongle this session is on.
    public let dongle: Dongle
    private let api: API
    private var open = true
    private let lock = NSLock()

    init(dongle: Dongle) {
        self.dongle = dongle
        self.api = dongle.api
    }

    deinit {
        close()
    }

    /// `true` until `close()`.
    public var isOpen: Bool { lock.withLock { open } }

    /// Ends the session. Safe to call more than once.
    public func close() {
        let wasOpen = lock.withLock { () -> Bool in
            let was = open
            open = false
            return was
        }
        if wasOpen {
            dongle.closeSession()
        }
    }

    private func device() throws -> OpaquePointer {
        guard lock.withLock({ open }) else {
            throw LicenseDongleError(status: Status.sessionExpired.rawValue, operation: "licd_session",
                                     detail: "the session has been closed")
        }
        return try dongle.requireHandle()
    }

    private var context: OpaquePointer? { dongle.contextHandle }

    private static func requireName(_ name: String) throws {
        if name.isEmpty {
            throw LicenseDongleError(status: Status.invalidArgument.rawValue, operation: "licd_record",
                                     detail: "the record name must not be empty")
        }
    }

    // MARK: write role

    /// Elevates to the write role with the dongle's write key (a P-256 private
    /// key in PKCS#8 DER). This belongs in your licence-issuing tooling; never
    /// ship that key in the application your users run. A key the dongle does
    /// not accept throws `.notGenuine`.
    public func authorizeWrite(key: [UInt8]) throws {
        let dev = try device()
        let rc = key.withUnsafeBufferPointer { api.writeAuth(dev, $0.baseAddress, $0.count) }
        try check(api, rc, "licd_write_auth", context: context)
    }

    /// Replaces the dongle's write key with `key`, a key you hold. Needs the
    /// write role; this session keeps it, and from the next session on only the
    /// new key elevates. Do this once per dongle, when it arrives: the factory
    /// key is public.
    public func rotateWriteKey(_ key: [UInt8]) throws {
        let dev = try device()
        let rc = key.withUnsafeBufferPointer { api.writeAuthRotate(dev, $0.baseAddress, $0.count) }
        try check(api, rc, "licd_write_auth_rotate", context: context)
    }

    // MARK: records

    /// The records on the dongle.
    public func records() throws -> [RecordInfo] {
        let dev = try device()
        var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var sizes: UnsafeMutablePointer<UInt32>?
        var count = 0
        try check(api, api.recordList(dev, &names, &sizes, &count), "licd_record_list", context: context)
        defer { api.freeRecordList(names, sizes, count) }
        guard let names = names, let sizes = sizes else { return [] }
        return (0..<count).map { i in
            RecordInfo(name: names[i].map { String(cString: $0) } ?? "", size: sizes[i])
        }
    }

    /// Reads a record. A record that does not exist throws `.notFound`.
    public func readRecord(_ name: String, progress: Progress? = nil) throws -> [UInt8] {
        try Session.requireName(name)
        let dev = try device()
        // Probe for the size first, so progress runs from 0 to the total once.
        var probe: UInt8 = 0
        var got: UInt32 = 0
        var total: UInt32 = 0
        let rc = name.withCString { api.recordRead(dev, $0, 0, &probe, 1, &got, &total, nil, nil) }
        try check(api, rc, "licd_record_read", context: context)
        if total == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(total))
        let box = ProgressBox(progress)
        let rc2 = name.withCString { cname in
            buffer.withUnsafeMutableBytes { raw in
                box.call { shim, user in
                    api.recordRead(dev, cname, 0, raw.baseAddress, total, &got, &total, shim, user)
                }
            }
        }
        try box.rethrow()
        try check(api, rc2, "licd_record_read", context: context)
        return Array(buffer.prefix(Int(got)))
    }

    /// Atomically replaces a record. Needs the write role.
    public func writeRecord(_ name: String, _ data: [UInt8], progress: Progress? = nil) throws {
        try Session.requireName(name)
        let dev = try device()
        let box = ProgressBox(progress)
        let rc = name.withCString { cname in
            data.withUnsafeBytes { raw in
                box.call { shim, user in
                    api.recordWrite(dev, cname, raw.baseAddress, UInt32(data.count), shim, user)
                }
            }
        }
        try box.rethrow()
        try check(api, rc, "licd_record_write", context: context)
    }

    /// Writes a string's UTF-8 bytes as a record.
    public func writeRecord(_ name: String, _ text: String, progress: Progress? = nil) throws {
        try writeRecord(name, Array(text.utf8), progress: progress)
    }

    /// Erases one record. Needs the write role. A missing record throws `.notFound`.
    public func eraseRecord(_ name: String) throws {
        // To the C library a null name means "erase everything"; that is
        // eraseAllRecords() here, so an empty string can never wipe the dongle.
        try Session.requireName(name)
        let dev = try device()
        let rc = name.withCString { api.recordErase(dev, $0) }
        try check(api, rc, "licd_record_erase", context: context)
    }

    /// Erases every record. Needs the write role.
    public func eraseAllRecords() throws {
        let dev = try device()
        try check(api, api.recordErase(dev, nil), "licd_record_erase", context: context)
    }

    // MARK: counters

    /// Reads a hardware monotonic counter.
    public func readCounter(_ id: UInt8) throws -> UInt32 {
        let dev = try device()
        var value: UInt32 = 0
        try check(api, api.counterRead(dev, id, &value), "licd_counter_read", context: context)
        return value
    }

    /// Increments a counter, irreversibly; needs the write role. Returns the new value.
    public func incrementCounter(_ id: UInt8) throws -> UInt32 {
        let dev = try device()
        var value: UInt32 = 0
        try check(api, api.counterIncrement(dev, id, &value), "licd_counter_increment", context: context)
        return value
    }

    // MARK: app-data envelope encryption

    /// Seals `plaintext` so that only a dongle of `scope` can open it. The pair
    /// to build a licence check on: put something the program needs through it
    /// and ship only the sealed form, so removing the check removes the data.
    public func appEncrypt(_ plaintext: [UInt8], scope: Scope) throws -> [UInt8] {
        let dev = try device()
        var out: UnsafeMutablePointer<UInt8>?
        var outLen: UInt32 = 0
        let rc = plaintext.withUnsafeBytes { raw in
            api.appEncrypt(dev, scope.raw, raw.baseAddress, UInt32(plaintext.count), &out, &outLen)
        }
        try check(api, rc, "licd_app_encrypt", context: context)
        return takeBuffer(out, outLen)
    }

    /// Opens data sealed with `appEncrypt`.
    public func appDecrypt(_ packed: [UInt8]) throws -> [UInt8] {
        let dev = try device()
        var out: UnsafeMutablePointer<UInt8>?
        var outLen: UInt32 = 0
        let rc = packed.withUnsafeBytes { raw in
            api.appDecrypt(dev, raw.baseAddress, UInt32(packed.count), &out, &outLen)
        }
        try check(api, rc, "licd_app_decrypt", context: context)
        return takeBuffer(out, outLen)
    }

    private func takeBuffer(_ buffer: UnsafeMutablePointer<UInt8>?, _ length: UInt32) -> [UInt8] {
        defer { api.freeBuffer(buffer) }
        guard let buffer = buffer else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(length)))
    }
}

/// Carries a Swift progress closure across the C boundary through the `user`
/// pointer. A closure is not a C function pointer, so the C side calls one
/// static shim that finds the box again. An error thrown by the closure is
/// stored and the transfer cancelled; it is rethrown once the C call returned.
final class ProgressBox {
    let progress: Progress?
    var error: Error?

    init(_ progress: Progress?) {
        self.progress = progress
    }

    func call(_ body: (ProgressFn?, UnsafeMutableRawPointer?) -> Int32) -> Int32 {
        guard progress != nil else { return body(nil, nil) }
        let user = Unmanaged.passUnretained(self).toOpaque()
        return body(ProgressBox.shim, user)
    }

    func rethrow() throws {
        if let error = error { throw error }
    }

    static let shim: ProgressFn = { done, total, user in
        guard let user = user else { return 1 }
        let box = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
        guard let progress = box.progress else { return 1 }
        do {
            return try progress(done, total) ? 1 : 0
        } catch {
            box.error = error
            return 0
        }
    }
}
