// Status codes, and how a failed call becomes a thrown error.

/// The status codes the native library reports. `ok` is zero; every failure is
/// negative.
public enum Status: Int32, Sendable, CaseIterable {
    case ok = 0
    case invalidArgument = -1
    case noDevice = -2
    case accessDenied = -3
    case io = -4
    case timeout = -5
    case protocolError = -6
    case notGenuine = -7
    case certificateInvalid = -8
    case sessionExpired = -9
    case tagMismatch = -10
    case range = -11
    case storageFull = -12
    case busy = -13
    case notFound = -14
    case authRequired = -15
    case firmwareIncompatible = -16
    case sdkTooOld = -17
    case cancelled = -18
    case notImplemented = -19
    case internalError = -20

    /// The library's short text for the code.
    public var message: String {
        guard let api = try? Loader.shared.api(), let text = api.strerror(rawValue) else {
            return "status \(rawValue)"
        }
        return String(cString: text)
    }
}

/// A failure reported by the native library.
///
/// `status` is what happened, `operation` the SDK function that reported it,
/// and `detail` the library's diagnostic text for this failure, or `""`. Log
/// the detail; do not parse it.
public struct LicenseDongleError: Error, CustomStringConvertible, Sendable {
    public let status: Status
    public let operation: String
    public let detail: String
    /// The library's text for `status`, read when the error was created.
    public let message: String

    init(status rawStatus: Int32, operation: String, detail: String) {
        self.status = Status(rawValue: rawStatus) ?? .internalError
        self.operation = operation
        self.detail = detail
        self.message = Status(rawValue: rawStatus)?.message ?? "status \(rawStatus)"
    }

    public var description: String {
        detail.isEmpty ? "\(operation): \(message)" : "\(operation): \(message) (\(detail))"
    }
}

/// Reads the library's detail for the last failure on this thread and throws.
func fail(_ api: API, _ status: Int32, _ operation: String, context: OpaquePointer?) -> LicenseDongleError {
    let detail = api.errorDetail(context).map { String(cString: $0) } ?? ""
    return LicenseDongleError(status: status, operation: operation, detail: detail)
}

func check(_ api: API, _ status: Int32, _ operation: String, context: OpaquePointer?) throws {
    if status != 0 {
        throw fail(api, status, operation, context: context)
    }
}
