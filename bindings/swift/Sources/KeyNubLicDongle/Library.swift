// Where the native library comes from, and the functions bound from it.
//
// The library is loaded once per process, on the first call that needs it.
// Every SDK function is resolved by name into a table of C function pointers,
// so the package links nothing and installs on a machine that has no library.

import CLicDongle
import Foundation

#if os(Windows)
import WinSDK
#else
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif
#endif

/// Failures of loading the native library itself, before any SDK call.
public enum LibraryError: Error, CustomStringConvertible {
    /// The file could not be loaded; `reason` is the loader's message.
    case notLoadable(path: String, reason: String)
    /// The file loaded but is not the KeyNub core library: `symbol` is missing.
    case notTheCoreLibrary(path: String, symbol: String)
    /// A different library is already loaded; a process loads it once.
    case alreadyLoaded(path: String)

    public var description: String {
        switch self {
        case .notLoadable(let path, let reason):
            return "could not load the KeyNub library '\(path)': \(reason)"
        case .notTheCoreLibrary(let path, let symbol):
            return "'\(path)' is not the KeyNub core library: \(symbol) is missing"
        case .alreadyLoaded(let path):
            return "the KeyNub library is already loaded from '\(path)'; a process loads it once"
        }
    }
}

/// The native library in use.
///
/// `Library.path` names the file to load and must be set before the first call
/// that needs the library. Without it the package takes, in this order, the
/// `KEYNUB_LICDONGLE_LIBRARY` environment variable, `natives/<platform>/` of
/// the SDK repository this package was built from (a package dependency is a
/// clone of it), the same folder found from the working directory upwards, and
/// finally the bare file name, which the operating system resolves along its
/// search path.
public enum Library {
    /// The file to load. Set before the first call; `nil` means automatic.
    public static var path: String? {
        get { Loader.shared.lock.withLock { Loader.shared.chosen } }
        set { Loader.shared.lock.withLock { Loader.shared.chosen = newValue } }
    }

    /// The library the process has loaded, or `nil` before the first call.
    public static var loadedPath: String? {
        Loader.shared.lock.withLock { Loader.shared.loadedPath }
    }

    /// The path the next load would use, given `path`, the environment and the
    /// file system as they are now.
    public static var resolvedPath: String {
        if let chosen = path { return chosen }
        return Loader.resolve()
    }

    /// The `natives/<platform>` folder name for this process.
    public static var platform: String { Loader.platform }

    /// Loads the library now instead of on the first call. Throws `LibraryError`.
    public static func load() throws {
        _ = try Loader.shared.api()
    }
}

// MARK: - the function table

typealias VersionFn = @convention(c) (UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?,
                                      UnsafeMutablePointer<Int32>?) -> Void
typealias InitFn = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Int32
typealias FreeFn = @convention(c) (OpaquePointer?) -> Void
typealias BytesFn = @convention(c) (OpaquePointer?, UnsafePointer<UInt8>?, Int) -> Int32
typealias EnumerateFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<licd_device_info>?>?,
                                        UnsafeMutablePointer<Int>?) -> Int32
typealias FreeDeviceListFn = @convention(c) (UnsafeMutablePointer<licd_device_info>?, Int) -> Void
typealias OpenFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
typealias GetInfoFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<licd_info>?) -> Int32
typealias GetSerialFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<CChar>?, Int) -> Int32
typealias VerifyGenuineFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<licd_genuine_result>?) -> Int32
typealias DeviceFn = @convention(c) (OpaquePointer?) -> Int32
typealias RecordListFn = @convention(c) (OpaquePointer?,
                                         UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>?,
                                         UnsafeMutablePointer<UnsafeMutablePointer<UInt32>?>?,
                                         UnsafeMutablePointer<Int>?) -> Int32
typealias FreeRecordListFn = @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                             UnsafeMutablePointer<UInt32>?, Int) -> Void
typealias ProgressFn = @convention(c) (UInt32, UInt32, UnsafeMutableRawPointer?) -> Int32
typealias RecordReadFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UInt32, UnsafeMutableRawPointer?,
                                         UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
                                         ProgressFn?, UnsafeMutableRawPointer?) -> Int32
typealias RecordWriteFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, UInt32,
                                          ProgressFn?, UnsafeMutableRawPointer?) -> Int32
typealias RecordEraseFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
typealias CounterFn = @convention(c) (OpaquePointer?, UInt8, UnsafeMutablePointer<UInt32>?) -> Int32
typealias AppEncryptFn = @convention(c) (OpaquePointer?, licd_scope, UnsafeRawPointer?, UInt32,
                                         UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                                         UnsafeMutablePointer<UInt32>?) -> Int32
typealias AppDecryptFn = @convention(c) (OpaquePointer?, UnsafeRawPointer?, UInt32,
                                         UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                                         UnsafeMutablePointer<UInt32>?) -> Int32
typealias FreeBufferFn = @convention(c) (UnsafeMutablePointer<UInt8>?) -> Void
typealias StrerrorFn = @convention(c) (Int32) -> UnsafePointer<CChar>?
typealias ErrorDetailFn = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

struct API {
    let version: VersionFn
    let initialize: InitFn
    let free: FreeFn
    let setTrustRoot: BytesFn
    let enumerate: EnumerateFn
    let freeDeviceList: FreeDeviceListFn
    let open: OpenFn
    let openPath: OpenFn
    let close: FreeFn
    let getInfo: GetInfoFn
    let getSerial: GetSerialFn
    let verifyGenuine: VerifyGenuineFn
    let sessionOpen: DeviceFn
    let sessionClose: DeviceFn
    let writeAuth: BytesFn
    let writeAuthRotate: BytesFn
    let recordList: RecordListFn
    let freeRecordList: FreeRecordListFn
    let recordRead: RecordReadFn
    let recordWrite: RecordWriteFn
    let recordErase: RecordEraseFn
    let counterRead: CounterFn
    let counterIncrement: CounterFn
    let appEncrypt: AppEncryptFn
    let appDecrypt: AppDecryptFn
    let freeBuffer: FreeBufferFn
    let strerror: StrerrorFn
    let errorDetail: ErrorDetailFn
}

// MARK: - loading

final class Loader {
    static let shared = Loader()

    let lock = NSLock()
    var chosen: String?
    var loadedPath: String?
    private var table: API?

    /// The bound function table, loading the library on the first call.
    func api() throws -> API {
        try lock.withLock {
            if let table = table { return table }
            let path = chosen ?? Loader.resolve()
            let table = try Loader.bind(path: path)
            self.table = table
            self.loadedPath = path
            return table
        }
    }

    static var platform: String {
        #if os(Windows)
        let os = "win"
        #elseif os(macOS)
        let os = "osx"
        #else
        let os = "linux"
        #endif
        #if arch(x86_64)
        let cpu = "x64"
        #elseif arch(arm64)
        let cpu = "arm64"
        #elseif arch(i386)
        let cpu = "x86"
        #else
        let cpu = "unknown"
        #endif
        return "\(os)-\(cpu)"
    }

    static var defaultBasename: String {
        #if os(Windows)
        return "keynub_licdongle.dll"
        #elseif os(macOS)
        return "libkeynub_licdongle.dylib"
        #else
        return "libkeynub_licdongle.so"
        #endif
    }

    /// The repository this file was compiled from: four levels above it.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KeyNubLicDongle
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // swift
            .deletingLastPathComponent() // bindings
            .deletingLastPathComponent() // repository root
    }

    static func resolve() -> String {
        if let env = ProcessInfo.processInfo.environment["KEYNUB_LICDONGLE_LIBRARY"], !env.isEmpty {
            return env
        }
        let relative = "natives/\(platform)/\(defaultBasename)"
        let inRepository = repositoryRoot.appendingPathComponent(relative).path
        if FileManager.default.fileExists(atPath: inRepository) {
            return inRepository
        }
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relative).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return defaultBasename
    }

    #if os(Windows)
    typealias Handle = HMODULE

    private static func open(_ path: String) throws -> Handle {
        guard let handle = path.withCString({ LoadLibraryA($0) }) else {
            throw LibraryError.notLoadable(path: path, reason: "Windows error \(GetLastError())")
        }
        return handle
    }

    private static func symbol(_ handle: Handle, _ name: String) -> UnsafeMutableRawPointer? {
        guard let proc = GetProcAddress(handle, name) else { return nil }
        return unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
    }

    private static func closeHandle(_ handle: Handle) { FreeLibrary(handle) }
    #else
    typealias Handle = UnsafeMutableRawPointer

    private static func open(_ path: String) throws -> Handle {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            throw LibraryError.notLoadable(path: path, reason: reason)
        }
        return handle
    }

    private static func symbol(_ handle: Handle, _ name: String) -> UnsafeMutableRawPointer? {
        dlsym(handle, name)
    }

    private static func closeHandle(_ handle: Handle) { dlclose(handle) }
    #endif

    private static func bind(path: String) throws -> API {
        let handle = try open(path)
        func fn<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = symbol(handle, name) else {
                closeHandle(handle)
                throw LibraryError.notTheCoreLibrary(path: path, symbol: name)
            }
            return unsafeBitCast(p, to: T.self)
        }
        return API(
            version: try fn("licd_version", VersionFn.self),
            initialize: try fn("licd_init", InitFn.self),
            free: try fn("licd_free", FreeFn.self),
            setTrustRoot: try fn("licd_set_trust_root", BytesFn.self),
            enumerate: try fn("licd_enumerate", EnumerateFn.self),
            freeDeviceList: try fn("licd_free_device_list", FreeDeviceListFn.self),
            open: try fn("licd_open", OpenFn.self),
            openPath: try fn("licd_open_path", OpenFn.self),
            close: try fn("licd_close", FreeFn.self),
            getInfo: try fn("licd_get_info", GetInfoFn.self),
            getSerial: try fn("licd_get_serial", GetSerialFn.self),
            verifyGenuine: try fn("licd_verify_genuine", VerifyGenuineFn.self),
            sessionOpen: try fn("licd_session_open", DeviceFn.self),
            sessionClose: try fn("licd_session_close", DeviceFn.self),
            writeAuth: try fn("licd_write_auth", BytesFn.self),
            writeAuthRotate: try fn("licd_write_auth_rotate", BytesFn.self),
            recordList: try fn("licd_record_list", RecordListFn.self),
            freeRecordList: try fn("licd_free_record_list", FreeRecordListFn.self),
            recordRead: try fn("licd_record_read", RecordReadFn.self),
            recordWrite: try fn("licd_record_write", RecordWriteFn.self),
            recordErase: try fn("licd_record_erase", RecordEraseFn.self),
            counterRead: try fn("licd_counter_read", CounterFn.self),
            counterIncrement: try fn("licd_counter_increment", CounterFn.self),
            appEncrypt: try fn("licd_app_encrypt", AppEncryptFn.self),
            appDecrypt: try fn("licd_app_decrypt", AppDecryptFn.self),
            freeBuffer: try fn("licd_free_buffer", FreeBufferFn.self),
            strerror: try fn("licd_strerror", StrerrorFn.self),
            errorDetail: try fn("licd_error_detail", ErrorDetailFn.self)
        )
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// The version of the loaded native library: major, minor, patch.
public func libraryVersion() throws -> (major: Int, minor: Int, patch: Int) {
    let api = try Loader.shared.api()
    var major: Int32 = 0, minor: Int32 = 0, patch: Int32 = 0
    api.version(&major, &minor, &patch)
    return (Int(major), Int(minor), Int(patch))
}

/// A NUL-terminated `char` array field of a C structure as a String.
func cString<T>(_ field: T) -> String {
    var copy = field
    return withUnsafePointer(to: &copy) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}
