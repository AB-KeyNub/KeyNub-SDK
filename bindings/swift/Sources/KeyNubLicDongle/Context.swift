// The library context: enumeration, opening dongles, the trust root.

import CLicDongle
import Foundation

/// One attached dongle, as enumerated.
public struct DeviceInfo: Sendable, Equatable {
    /// The serial as hex.
    public let serial: String
    /// The operating system's device path, accepted by `Context.open(path:)`.
    public let path: String
    public let vendorID: UInt16
    public let productID: UInt16
}

/// A library context. It owns the connection to the operating system's USB
/// layer and the dongles opened on it; one per program is usual.
///
/// Close it with `close()` when done. A context that is deinitialised closes
/// itself, together with any dongle still open on it.
public final class Context {
    let api: API
    private(set) var handle: OpaquePointer?
    private let lock = NSLock()
    private var dongles: [WeakDongle] = []

    /// Creates a context, loading the native library if this is the first call.
    /// Throws `LibraryError` when the library cannot be loaded and
    /// `LicenseDongleError` when the library refuses.
    public init() throws {
        api = try Loader.shared.api()
        var out: OpaquePointer?
        let rc = api.initialize(&out)
        guard rc == 0, let ctx = out else {
            throw LicenseDongleError(status: rc, operation: "licd_init", detail: "")
        }
        handle = ctx
    }

    deinit {
        close()
    }

    /// `true` while the context can be used.
    public var isOpen: Bool { lock.withLock { handle != nil } }

    /// Closes every dongle still open on this context, then the context.
    /// Safe to call more than once.
    public func close() {
        let open = lock.withLock { () -> [Dongle] in
            let list = dongles.compactMap { $0.dongle }
            dongles.removeAll()
            return list
        }
        for dongle in open {
            dongle.close()
        }
        lock.withLock {
            if let h = handle {
                api.free(h)
                handle = nil
            }
        }
    }

    func requireHandle() throws -> OpaquePointer {
        guard let h = lock.withLock({ handle }) else {
            throw LicenseDongleError(status: Status.invalidArgument.rawValue, operation: "licd_ctx",
                                     detail: "the context has been closed")
        }
        return h
    }

    /// The library's diagnostic text for the most recent failure on this thread.
    public var lastErrorDetail: String {
        guard let h = lock.withLock({ handle }) else { return "" }
        return api.errorDetail(h).map { String(cString: $0) } ?? ""
    }

    /// Replaces the CA root certificate (DER) that `verifyGenuine` checks the
    /// dongle's certificate chain against. Applications do not need this: a
    /// release build of the library embeds the KeyNub production root.
    public func setTrustRoot(_ der: [UInt8]) throws {
        let h = try requireHandle()
        let rc = der.withUnsafeBufferPointer { api.setTrustRoot(h, $0.baseAddress, $0.count) }
        try check(api, rc, "licd_set_trust_root", context: h)
    }

    /// The attached dongles, without opening any.
    public func enumerate() throws -> [DeviceInfo] {
        let h = try requireHandle()
        var list: UnsafeMutablePointer<licd_device_info>?
        var count = 0
        try check(api, api.enumerate(h, &list, &count), "licd_enumerate", context: h)
        defer { api.freeDeviceList(list, count) }
        guard let list = list else { return [] }
        return (0..<count).map { i in
            let d = list[i]
            return DeviceInfo(serial: cString(d.serial), path: cString(d.path),
                              vendorID: d.vendor_id, productID: d.product_id)
        }
    }

    /// Opens the dongle with `serial`, or the first one found when `nil`.
    /// Throws `LicenseDongleError` with `status == .noDevice` when none matches.
    public func open(serial: String? = nil) throws -> Dongle {
        let h = try requireHandle()
        var dev: OpaquePointer?
        let rc: Int32
        if let serial = serial {
            rc = serial.withCString { api.open(h, $0, &dev) }
        } else {
            rc = api.open(h, nil, &dev)
        }
        try check(api, rc, "licd_open", context: h)
        return register(Dongle(context: self, handle: dev!))
    }

    /// Opens the dongle at a device path from `enumerate()`.
    public func open(path: String) throws -> Dongle {
        let h = try requireHandle()
        var dev: OpaquePointer?
        let rc = path.withCString { api.openPath(h, $0, &dev) }
        try check(api, rc, "licd_open_path", context: h)
        return register(Dongle(context: self, handle: dev!))
    }

    private func register(_ dongle: Dongle) -> Dongle {
        lock.withLock {
            dongles.removeAll { $0.dongle == nil }
            dongles.append(WeakDongle(dongle))
        }
        return dongle
    }
}

struct WeakDongle {
    weak var dongle: Dongle?
    init(_ dongle: Dongle) { self.dongle = dongle }
}
