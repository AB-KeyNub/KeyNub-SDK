// KeyNub License Dongle SDK — C++ binding.
//
// Header-only RAII wrapper over the C ABI (`include/licdongle.h`). No library
// to link beyond the core itself, nothing to build, no dependencies past the
// standard library. C++11 or newer — deliberately not C++17, because the desktop
// engineering applications this dongle is sold to are frequently pinned to an
// older toolchain.
//
//     #include <keynub/licdongle.hpp>
//
//     keynub::Context ctx;
//     keynub::Dongle dongle = ctx.open();
//     dongle.verifyGenuine();                       // throws if it is not
//     keynub::Session session = dongle.openSession();
//     std::vector<uint8_t> data = session.appDecrypt(blob);
//
// Errors are exceptions carrying the status code and the SDK's diagnostic detail;
// resources are released by destructors, including the session. Everything is
// move-only: a dongle handle is not a value to copy.
//
// Read docs/integration-security.md before writing the check. The dongle proves a
// genuine device is attached; it cannot stop an attacker patching the code that
// asks. `if (isGenuine())` in a stripped release binary is a one-byte patch —
// route something the program needs through appEncrypt/appDecrypt instead.

#ifndef KEYNUB_LICDONGLE_HPP
#define KEYNUB_LICDONGLE_HPP

#include <cstdint>
#include <cstring>
#include <exception>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "licdongle.h"

namespace keynub {

// ============================================================================
// Status and errors
// ============================================================================

enum class Status : int {
    Ok = LICD_OK,
    InvalidArgument = LICD_E_INVALID_ARG,
    NoDevice = LICD_E_NO_DEVICE,
    AccessDenied = LICD_E_ACCESS_DENIED,
    Io = LICD_E_IO,
    Timeout = LICD_E_TIMEOUT,
    Protocol = LICD_E_PROTOCOL,
    NotGenuine = LICD_E_NOT_GENUINE,
    CertificateInvalid = LICD_E_CERT_INVALID,
    SessionExpired = LICD_E_SESSION_EXPIRED,
    TagMismatch = LICD_E_TAG_MISMATCH,
    Range = LICD_E_RANGE,
    StorageFull = LICD_E_STORAGE_FULL,
    Busy = LICD_E_BUSY,
    NotFound = LICD_E_NOT_FOUND,
    AuthRequired = LICD_E_AUTH_REQUIRED,
    FirmwareIncompatible = LICD_E_FW_INCOMPATIBLE,
    SdkTooOld = LICD_E_SDK_TOO_OLD,
    Cancelled = LICD_E_CANCELLED,
    NotImplemented = LICD_E_NOT_IMPLEMENTED,
    Internal = LICD_E_INTERNAL,
};

enum class Scope : int {
    Device = LICD_SCOPE_DEVICE,       // only this one physical dongle can decrypt
    Developer = LICD_SCOPE_DEVELOPER, // any dongle from the same developer batch
};

/// Thrown by every operation that fails. Catch this, or one of the subclasses
/// below when a specific failure needs its own handling.
class Error : public std::runtime_error {
public:
    Error(Status status, const std::string &message, std::string detail)
        : std::runtime_error(message), status_(status), detail_(std::move(detail)) {}

    Status status() const noexcept { return status_; }
    /// The SDK's thread-local diagnostic detail, or empty. Log it; do not parse it.
    const std::string &detail() const noexcept { return detail_; }

private:
    Status status_;
    std::string detail_;
};

// Subclasses exist only where a caller plausibly branches on the reason.
#define KEYNUB_DEFINE_ERROR(Name)                                                        \
    class Name : public Error {                                                          \
    public:                                                                              \
        Name(Status s, const std::string &m, std::string d) : Error(s, m, std::move(d)) {} \
    }

KEYNUB_DEFINE_ERROR(NotGenuineError);
KEYNUB_DEFINE_ERROR(CertificateInvalidError);
KEYNUB_DEFINE_ERROR(WriteAuthorizationRequiredError);
KEYNUB_DEFINE_ERROR(SessionExpiredError);
KEYNUB_DEFINE_ERROR(DeviceNotFoundError);
KEYNUB_DEFINE_ERROR(RecordNotFoundError);
KEYNUB_DEFINE_ERROR(CancelledError);

#undef KEYNUB_DEFINE_ERROR

// ============================================================================
// Plain results
// ============================================================================

struct Version {
    int major = 0;
    int minor = 0;
    int patch = 0;

    std::string toString() const {
        return std::to_string(major) + "." + std::to_string(minor) + "." + std::to_string(patch);
    }
};

struct DeviceInfo {
    std::string serial;
    std::string path; ///< opaque; pass to Context::openPath
    uint16_t vendorId = 0;
    uint16_t productId = 0;
};

struct Info {
    uint8_t protocolMajor = 0;
    uint8_t protocolMinor = 0;
    uint8_t firmwareMajor = 0;
    uint8_t firmwareMinor = 0;
    uint8_t firmwarePatch = 0;
    bool seReady = false;
    bool provisioned = false;
    uint32_t dataCapacity = 0;
    uint32_t dataFree = 0;
    /// The dongle's *previous* boot ended in a watchdog timeout: the firmware hung
    /// and reset itself. Worth logging — it is the only trace a field hang leaves
    /// behind, and a power cycle clears it.
    bool watchdogReboot = false;
    /// Whether the dongle confirmed at boot that its USB and parsing code is fenced off
    /// from keys and storage. The software simulator reports false.
    bool isolated = false;
};

struct GenuineResult {
    bool genuine = false;
    std::string serial;
    std::string batch;
    std::string provisionedDate; ///< "YYYY-MM-DD", or empty
};

struct RecordInfo {
    std::string name;
    uint32_t size = 0;
};

using Bytes = std::vector<uint8_t>;

/// Progress callback: return false to cancel the transfer. An exception thrown
/// from it cancels the transfer and is rethrown once the SDK has unwound.
using ProgressCallback = std::function<bool(uint32_t done, uint32_t total)>;

// ============================================================================
// Internals
// ============================================================================

namespace detail {

inline std::string errorDetail(licd_ctx *ctx) {
    if (ctx == nullptr) {
        return std::string();
    }
    const char *d = licd_error_detail(ctx);
    return (d != nullptr) ? std::string(d) : std::string();
}

[[noreturn]] inline void throwStatus(licd_ctx *ctx, int rc, const char *operation) {
    const char *what = licd_strerror(rc);
    std::string detail = errorDetail(ctx);
    std::string message = std::string(operation) + ": " + (what != nullptr ? what : "unknown");
    if (!detail.empty()) {
        message += " (" + detail + ")";
    }
    const Status status = static_cast<Status>(rc);
    switch (rc) {
    case LICD_E_NOT_GENUINE:
        throw NotGenuineError(status, message, std::move(detail));
    case LICD_E_CERT_INVALID:
        throw CertificateInvalidError(status, message, std::move(detail));
    case LICD_E_AUTH_REQUIRED:
        throw WriteAuthorizationRequiredError(status, message, std::move(detail));
    case LICD_E_SESSION_EXPIRED:
        throw SessionExpiredError(status, message, std::move(detail));
    case LICD_E_NO_DEVICE:
        throw DeviceNotFoundError(status, message, std::move(detail));
    case LICD_E_NOT_FOUND:
        throw RecordNotFoundError(status, message, std::move(detail));
    case LICD_E_CANCELLED:
        throw CancelledError(status, message, std::move(detail));
    default:
        throw Error(status, message, std::move(detail));
    }
}

inline void check(licd_ctx *ctx, int rc, const char *operation) {
    if (rc != LICD_OK) {
        throwStatus(ctx, rc, operation);
    }
}

/// Shared between a Dongle and any Session taken from it, so that a Session
/// outliving its Dongle is merely inert rather than a use-after-free.
struct DeviceState {
    licd_device *device = nullptr;
    licd_ctx *ctx = nullptr;

    DeviceState(licd_device *d, licd_ctx *c) : device(d), ctx(c) {}
    DeviceState(const DeviceState &) = delete;
    DeviceState &operator=(const DeviceState &) = delete;

    void close() {
        if (device != nullptr) {
            licd_device *d = device;
            device = nullptr;
            licd_close(d);
        }
    }

    ~DeviceState() { close(); }

    licd_device *checked() const {
        if (device == nullptr) {
            throw Error(Status::InvalidArgument, "the dongle has been closed", std::string());
        }
        return device;
    }
};

/// Carries a std::function across the C callback boundary, holding any exception
/// it throws until the SDK has finished unwinding its own transfer.
struct ProgressBridge {
    const ProgressCallback *callback = nullptr;
    std::exception_ptr error;
    bool cancelled = false;
};

inline int progressTrampoline(uint32_t done, uint32_t total, void *user) {
    auto *bridge = static_cast<ProgressBridge *>(user);
    if (bridge->error) {
        return 0;
    }
    try {
        if (!(*bridge->callback)(done, total)) {
            bridge->cancelled = true;
            return 0;
        }
    } catch (...) {
        // Letting this propagate through C would skip the SDK's own cleanup and
        // strand the device mid-transfer.
        bridge->error = std::current_exception();
        return 0;
    }
    return 1;
}

inline licd_progress_cb progressFor(const ProgressBridge &bridge) {
    return (bridge.callback != nullptr) ? progressTrampoline : nullptr;
}

inline void finishProgress(ProgressBridge &bridge, licd_ctx *ctx, int rc, const char *operation) {
    if (bridge.error) {
        std::rethrow_exception(bridge.error);
    }
    check(ctx, rc, operation);
}

/// Frees a buffer the SDK allocated, whatever happens next.
struct BufferGuard {
    uint8_t *buffer = nullptr;
    explicit BufferGuard(uint8_t *b) : buffer(b) {}
    BufferGuard(const BufferGuard &) = delete;
    BufferGuard &operator=(const BufferGuard &) = delete;
    ~BufferGuard() {
        if (buffer != nullptr) {
            licd_free_buffer(buffer);
        }
    }
};

} // namespace detail

// ============================================================================
// Session
// ============================================================================

/// An open encrypted session: records, counters, app-crypto and write-role
/// elevation. Ends when it goes out of scope.
class Session {
public:
    Session(const Session &) = delete;
    Session &operator=(const Session &) = delete;

    Session(Session &&other) noexcept : state_(std::move(other.state_)), open_(other.open_) {
        other.open_ = false;
    }

    Session &operator=(Session &&other) noexcept {
        if (this != &other) {
            close();
            state_ = std::move(other.state_);
            open_ = other.open_;
            other.open_ = false;
        }
        return *this;
    }

    ~Session() { close(); }

    bool isOpen() const noexcept { return open_ && state_ && state_->device != nullptr; }

    /// Ends the session, zeroizing the session keys on the dongle. Idempotent, and
    /// never throws: teardown is local state, and this runs from a destructor.
    void close() noexcept {
        if (open_) {
            open_ = false;
            if (state_ && state_->device != nullptr) {
                licd_session_close(state_->device);
            }
        }
    }

    /// Elevates to the write role with the developer master key (DER EC private
    /// key). Vendor tooling only — never ship that key in an application.
    void authorizeWrite(const Bytes &masterKeyDer) {
        licd_device *dev = device();
        detail::check(ctx(), licd_write_auth(dev, masterKeyDer.data(),
                                            masterKeyDer.size()),
                      "licd_write_auth");
    }

    std::vector<RecordInfo> listRecords() {
        licd_device *dev = device();
        char **names = nullptr;
        uint32_t *sizes = nullptr;
        size_t count = 0;
        detail::check(ctx(), licd_record_list(dev, &names, &sizes, &count), "licd_record_list");
        std::vector<RecordInfo> result;
        try {
            result.reserve(count);
            for (size_t i = 0; i < count; ++i) {
                RecordInfo info;
                info.name = (names[i] != nullptr) ? names[i] : "";
                info.size = sizes[i];
                result.push_back(std::move(info));
            }
        } catch (...) {
            licd_free_record_list(names, sizes, count);
            throw;
        }
        licd_free_record_list(names, sizes, count);
        return result;
    }

    Bytes readRecord(const std::string &name, ProgressCallback progress = nullptr) {
        licd_device *dev = device();
        requireName(name);

        // Probe for the size first, then read the whole record, so reported
        // progress runs monotonically from 0 to total.
        uint8_t probe = 0;
        uint32_t got = 0;
        uint32_t total = 0;
        detail::check(ctx(),
                      licd_record_read(dev, name.c_str(), 0, &probe, 1, &got, &total, nullptr,
                                       nullptr),
                      "licd_record_read");
        if (total == 0) {
            return Bytes();
        }

        Bytes buffer(total);
        detail::ProgressBridge bridge;
        bridge.callback = progress ? &progress : nullptr;
        int rc = licd_record_read(dev, name.c_str(), 0, buffer.data(), total, &got, &total,
                                  detail::progressFor(bridge), &bridge);
        detail::finishProgress(bridge, ctx(), rc, "licd_record_read");
        buffer.resize(got);
        return buffer;
    }

    /// Atomically replaces the named record. Requires the write role.
    void writeRecord(const std::string &name, const Bytes &data,
                     ProgressCallback progress = nullptr) {
        licd_device *dev = device();
        requireName(name);
        detail::ProgressBridge bridge;
        bridge.callback = progress ? &progress : nullptr;
        int rc = licd_record_write(dev, name.c_str(), data.data(),
                                   static_cast<uint32_t>(data.size()),
                                   detail::progressFor(bridge), &bridge);
        detail::finishProgress(bridge, ctx(), rc, "licd_record_write");
    }

    void eraseRecord(const std::string &name) {
        licd_device *dev = device();
        requireName(name); // an empty name would erase everything
        detail::check(ctx(), licd_record_erase(dev, name.c_str()), "licd_record_erase");
    }

    void eraseAllRecords() {
        detail::check(ctx(), licd_record_erase(device(), nullptr), "licd_record_erase");
    }

    uint32_t readCounter(uint8_t counterId) {
        uint32_t value = 0;
        detail::check(ctx(), licd_counter_read(device(), counterId, &value), "licd_counter_read");
        return value;
    }

    /// Irreversible: the counter is monotonic in hardware. Requires the write role.
    uint32_t incrementCounter(uint8_t counterId) {
        uint32_t value = 0;
        detail::check(ctx(), licd_counter_increment(device(), counterId, &value),
                      "licd_counter_increment");
        return value;
    }

    /// Encrypts so that only a dongle of `scope` can decrypt. The bulk crypto stays
    /// on the host; only a small key is wrapped by the dongle.
    ///
    /// This is the operation to build a licence check around: put something the
    /// program genuinely needs through it, so removing the check removes the data.
    Bytes appEncrypt(Scope scope, const Bytes &plaintext) {
        uint8_t *out = nullptr;
        uint32_t outLen = 0;
        detail::check(ctx(),
                      licd_app_encrypt(device(), static_cast<licd_scope>(scope), plaintext.data(),
                                       static_cast<uint32_t>(plaintext.size()), &out, &outLen),
                      "licd_app_encrypt");
        detail::BufferGuard guard(out);
        return Bytes(out, out + outLen);
    }

    Bytes appDecrypt(const Bytes &packed) {
        uint8_t *out = nullptr;
        uint32_t outLen = 0;
        detail::check(ctx(),
                      licd_app_decrypt(device(), packed.data(),
                                       static_cast<uint32_t>(packed.size()), &out, &outLen),
                      "licd_app_decrypt");
        detail::BufferGuard guard(out);
        return Bytes(out, out + outLen);
    }

private:
    friend class Dongle;

    explicit Session(std::shared_ptr<detail::DeviceState> state)
        : state_(std::move(state)), open_(true) {}

    licd_device *device() const {
        if (!open_) {
            throw Error(Status::SessionExpired, "the session has been closed", std::string());
        }
        return state_->checked();
    }

    licd_ctx *ctx() const { return state_ ? state_->ctx : nullptr; }

    static void requireName(const std::string &name) {
        if (name.empty()) {
            throw Error(Status::InvalidArgument, "the record name must not be empty",
                        std::string());
        }
    }

    std::shared_ptr<detail::DeviceState> state_;
    bool open_ = false;
};

// ============================================================================
// Dongle
// ============================================================================

/// An open connection to a dongle. Plaintext operations here; stored data needs
/// a Session.
class Dongle {
public:
    Dongle(const Dongle &) = delete;
    Dongle &operator=(const Dongle &) = delete;
    Dongle(Dongle &&) noexcept = default;
    Dongle &operator=(Dongle &&) noexcept = default;
    ~Dongle() = default;

    bool isOpen() const noexcept { return state_ && state_->device != nullptr; }

    /// Closes the dongle. Any Session taken from it becomes inert rather than
    /// dangling.
    void close() noexcept {
        if (state_) {
            state_->close();
        }
    }

    Info getInfo() const {
        licd_info raw;
        std::memset(&raw, 0, sizeof(raw));
        detail::check(ctx(), licd_get_info(device(), &raw), "licd_get_info");
        Info info;
        info.protocolMajor = raw.proto_version_major;
        info.protocolMinor = raw.proto_version_minor;
        info.firmwareMajor = raw.fw_version_major;
        info.firmwareMinor = raw.fw_version_minor;
        info.firmwarePatch = raw.fw_version_patch;
        info.seReady = raw.se_ready != 0;
        info.provisioned = raw.provisioned != 0;
        info.dataCapacity = raw.data_capacity;
        info.dataFree = raw.data_free;
        info.watchdogReboot = raw.watchdog_reboot != 0;
        info.isolated = raw.isolated != 0;
        return info;
    }

    std::string getSerial() const {
        char buffer[LICD_SERIAL_HEX_LEN + 1] = {0};
        detail::check(ctx(), licd_get_serial(device(), buffer, sizeof(buffer)), "licd_get_serial");
        return std::string(buffer);
    }

    /// Validates the device certificate chain to the trusted root and checks a
    /// live ECDSA challenge-response. Throws if the dongle is not genuine.
    GenuineResult verifyGenuine() const {
        licd_genuine_result raw;
        std::memset(&raw, 0, sizeof(raw));
        detail::check(ctx(), licd_verify_genuine(device(), &raw), "licd_verify_genuine");
        GenuineResult result;
        result.genuine = raw.genuine != 0;
        result.serial = raw.serial;
        result.batch = raw.batch;
        result.provisionedDate = raw.provisioned_date;
        return result;
    }

    /// Non-throwing form for a licence gate. Fails closed: every failure — no
    /// dongle, I/O error, invalid certificate — reports false.
    bool isGenuine() const noexcept {
        try {
            return verifyGenuine().genuine;
        } catch (...) {
            return false;
        }
    }

    Session openSession() {
        detail::check(ctx(), licd_session_open(device()), "licd_session_open");
        return Session(state_);
    }

    /// Takes ownership of a device opened through the C ABI directly, so this
    /// wrapper can be adopted incrementally in a codebase that already calls
    /// licd_open — and so that test harnesses can wrap a simulated device.
    /// The returned Dongle closes it.
    static Dongle adopt(licd_device *device, licd_ctx *ctx) { return Dongle(device, ctx); }

    /// The underlying handle, for mixing this wrapper with direct C ABI calls.
    licd_device *raw() const { return device(); }

private:
    friend class Context;

    Dongle(licd_device *device, licd_ctx *ctx)
        : state_(std::make_shared<detail::DeviceState>(device, ctx)) {}

    licd_device *device() const { return state_->checked(); }
    licd_ctx *ctx() const { return state_ ? state_->ctx : nullptr; }

    std::shared_ptr<detail::DeviceState> state_;
};

// ============================================================================
// Context
// ============================================================================

/// Library context: the entry point. Thread-safe, per the C ABI's contract; an
/// individual Dongle must be used by one thread at a time.
class Context {
public:
    Context() {
        licd_ctx *ctx = nullptr;
        detail::check(nullptr, licd_init(&ctx), "licd_init");
        ctx_.reset(ctx);
    }

    Context(const Context &) = delete;
    Context &operator=(const Context &) = delete;
    Context(Context &&) noexcept = default;
    Context &operator=(Context &&) noexcept = default;

    static Version libraryVersion() noexcept {
        Version v;
        licd_version(&v.major, &v.minor, &v.patch);
        return v;
    }

    std::vector<DeviceInfo> enumerate() {
        licd_device_info *list = nullptr;
        size_t count = 0;
        detail::check(raw(), licd_enumerate(raw(), &list, &count), "licd_enumerate");
        std::vector<DeviceInfo> result;
        try {
            result.reserve(count);
            for (size_t i = 0; i < count; ++i) {
                DeviceInfo info;
                info.serial = list[i].serial;
                info.path = list[i].path;
                info.vendorId = list[i].vendor_id;
                info.productId = list[i].product_id;
                result.push_back(std::move(info));
            }
        } catch (...) {
            licd_free_device_list(list, count);
            throw;
        }
        licd_free_device_list(list, count);
        return result;
    }

    /// Opens the dongle with this serial, or the first one found when empty.
    Dongle open(const std::string &serial = std::string()) {
        licd_device *dev = nullptr;
        detail::check(raw(), licd_open(raw(), serial.empty() ? nullptr : serial.c_str(), &dev),
                      "licd_open");
        return Dongle(dev, raw());
    }

    Dongle openPath(const std::string &path) {
        licd_device *dev = nullptr;
        detail::check(raw(), licd_open_path(raw(), path.c_str(), &dev), "licd_open_path");
        return Dongle(dev, raw());
    }

    /// Overrides the CA root verifyGenuine checks against. Applications do not
    /// need this — a release build embeds the KeyNub production root. It exists
    /// for dongles provisioned against a different CA and for vendor tooling.
    void setTrustRoot(const Bytes &der) {
        detail::check(raw(), licd_set_trust_root(raw(), der.data(), der.size()),
                      "licd_set_trust_root");
    }

    /// Diagnostic detail for the most recent failure on this thread.
    std::string lastErrorDetail() const { return detail::errorDetail(ctx_.get()); }

    /// The underlying handle, for mixing this wrapper with direct C ABI calls.
    licd_ctx *raw() const {
        if (!ctx_) {
            throw Error(Status::InvalidArgument, "the context has been closed", std::string());
        }
        return ctx_.get();
    }

private:
    struct Deleter {
        void operator()(licd_ctx *ctx) const noexcept { licd_free(ctx); }
    };
    std::unique_ptr<licd_ctx, Deleter> ctx_;
};

} // namespace keynub

#endif // KEYNUB_LICDONGLE_HPP
