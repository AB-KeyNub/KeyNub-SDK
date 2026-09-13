"""
    KeyNubLicenseDongle

Julia binding for the KeyNub USB-C license dongle.

```julia
using KeyNubLicenseDongle

ctx = Context()
try
    dongle = open_dongle(ctx)          # first dongle, or open_dongle(ctx, serial)
    verify_genuine(dongle)             # throws unless genuine
    session(dongle) do s
        data = app_decrypt(s, blob)    # <- build your licence check on this
    end
finally
    close(ctx)
end
```

No packages: `ccall` is part of the language, so this has no dependencies outside
the standard library. The native library comes with the package; set
`ENV["KEYNUB_LICDONGLE_LIBRARY"]` to a path before the first call to use a
specific one.

Read `docs/integration-security.md` before writing the check. `if
is_genuine(dongle)` is one line to delete, and Julia ships as source — even a
sysimage only raises the effort. Route something the program needs through
[`app_encrypt`](@ref)/[`app_decrypt`](@ref), so removing the check removes the
data. For a Julia package that is usually the interesting part anyway: a
correlation table, fitted parameters, a proprietary model's coefficients.
"""
module KeyNubLicenseDongle

using Artifacts

export Context, Dongle, Session, Scope, DEVICE, DEVELOPER
export LicenseDongleError, NotGenuineError, CertificateInvalidError,
       WriteAuthorizationRequiredError, SessionExpiredError, DeviceNotFoundError,
       RecordNotFoundError, OperationCancelledError
export library_version, enumerate_dongles, open_dongle, open_path, set_trust_root!,
       last_error_detail, info, serial, verify_genuine, is_genuine, session,
       authorize_write, rotate_write_key, list_records, read_record, write_record, erase_record,
       erase_all_records, read_counter, increment_counter, app_encrypt, app_decrypt

# --- library discovery -------------------------------------------------------

function _default_basename()
    Sys.iswindows() && return "keynub_licdongle.dll"
    Sys.isapple() && return "libkeynub_licdongle.dylib"
    return "libkeynub_licdongle.so"
end

"""The natives/<rid> directory name for this Julia process."""
function _repo_rid()
    os = Sys.iswindows() ? "win" : (Sys.isapple() ? "osx" : "linux")
    arch = if Sys.ARCH === :x86_64
        "x64"
    elseif Sys.ARCH === :i686
        "x86"
    elseif Sys.ARCH === :aarch64
        "arm64"
    else
        "unknown"
    end
    return string(os, "-", arch)
end

"""The native library this binding calls, as a path or a bare name for the system
loader. Set in `__init__`: `ENV["KEYNUB_LICDONGLE_LIBRARY"]` names a specific file,
otherwise the library for this platform comes from the SDK tree (see
[`sdk_root`](@ref)). Julia binds each call to the library on its first use, so a
different value only takes effect when assigned before the first call."""
LIB::String = ""

"""
    sdk_root() -> Union{String,Nothing}

The SDK tree this binding reads `natives/<platform>/` and `include/` from: the
repository when the package is used from a clone of it, otherwise the SDK release
the package's artifact downloads. `nothing` if neither is available.
"""
function sdk_root()
    checkout = normpath(joinpath(@__DIR__, "..", "..", ".."))
    isdir(joinpath(checkout, "natives")) && return checkout
    root = try
        artifact"keynub_sdk"
    catch
        return nothing
    end
    entries = readdir(root)
    return length(entries) == 1 ? joinpath(root, first(entries)) : root
end

function _resolve_library()
    override = get(ENV, "KEYNUB_LICDONGLE_LIBRARY", "")
    isempty(override) || return override
    root = sdk_root()
    if root !== nothing
        candidate = joinpath(root, "natives", _repo_rid(), _default_basename())
        if isfile(candidate)
            _make_loadable(candidate)
            return candidate
        end
    end
    return _default_basename()
end

"""Windows loads a DLL only from a file that grants execute permission; a file
installed from an artifact carries none, since the archive stores it as a plain
read-only file. Grants it, leaving the file read-only."""
function _make_loadable(path::AbstractString)
    Sys.iswindows() || return nothing
    Sys.isexecutable(path) && return nothing
    try
        chmod(path, filemode(path) | 0o111)
    catch
    end
    return nothing
end

function __init__()
    global LIB = _resolve_library()
    return nothing
end

# --- status codes and errors -------------------------------------------------

const OK = Cint(0)
const E_INVALID_ARG = Cint(-1)
const E_NO_DEVICE = Cint(-2)
const E_ACCESS_DENIED = Cint(-3)
const E_IO = Cint(-4)
const E_TIMEOUT = Cint(-5)
const E_PROTOCOL = Cint(-6)
const E_NOT_GENUINE = Cint(-7)
const E_CERT_INVALID = Cint(-8)
const E_SESSION_EXPIRED = Cint(-9)
const E_TAG_MISMATCH = Cint(-10)
const E_RANGE = Cint(-11)
const E_STORAGE_FULL = Cint(-12)
const E_BUSY = Cint(-13)
const E_NOT_FOUND = Cint(-14)
const E_AUTH_REQUIRED = Cint(-15)
const E_FW_INCOMPATIBLE = Cint(-16)
const E_SDK_TOO_OLD = Cint(-17)
const E_CANCELLED = Cint(-18)
const E_NOT_IMPLEMENTED = Cint(-19)
const E_INTERNAL = Cint(-20)

"""
    LicenseDongleError

Thrown when a dongle operation fails. `status` is the numeric `licd_status`,
`operation` the C function, and `detail` the SDK's diagnostic text — log it, do
not parse it.
"""
struct LicenseDongleError <: Exception
    status::Cint
    operation::String
    message::String
    detail::String
end

for name in (:NotGenuineError, :CertificateInvalidError, :WriteAuthorizationRequiredError,
             :SessionExpiredError, :DeviceNotFoundError, :RecordNotFoundError,
             :OperationCancelledError)
    @eval struct $name <: Exception
        status::Cint
        operation::String
        message::String
        detail::String
    end
end

const _AnyError = Union{LicenseDongleError,NotGenuineError,CertificateInvalidError,
                        WriteAuthorizationRequiredError,SessionExpiredError,
                        DeviceNotFoundError,RecordNotFoundError,OperationCancelledError}

function Base.showerror(io::IO, e::_AnyError)
    print(io, "$(nameof(typeof(e))): $(e.operation): $(e.message)")
    isempty(e.detail) || print(io, " ($(e.detail))")
end

_status_text(status::Integer) = unsafe_string(ccall((:licd_strerror, LIB), Cstring, (Cint,), status))

function _error_type(status::Cint)
    status == E_NOT_GENUINE && return NotGenuineError
    status == E_CERT_INVALID && return CertificateInvalidError
    status == E_AUTH_REQUIRED && return WriteAuthorizationRequiredError
    status == E_SESSION_EXPIRED && return SessionExpiredError
    status == E_NO_DEVICE && return DeviceNotFoundError
    status == E_NOT_FOUND && return RecordNotFoundError
    status == E_CANCELLED && return OperationCancelledError
    return LicenseDongleError
end

"""Raises the mapped exception for `status`, which the binding produced itself."""
function _fail(status::Cint, operation::AbstractString, detail::AbstractString = "")
    throw(_error_type(status)(status, String(operation), _status_text(status), String(detail)))
end

# --- C structs ---------------------------------------------------------------
# Layout mirrors licdongle.h. Julia computes the padding from the field types the
# same way C does, so these do not carry hand-written offsets.

struct CInfo
    proto_major::UInt8
    proto_minor::UInt8
    fw_major::UInt8
    fw_minor::UInt8
    fw_patch::UInt8
    se_ready::Cint
    provisioned::Cint
    data_capacity::UInt32
    data_free::UInt32
    watchdog_reboot::Cint
    isolated::Cint
    writeauth_rotated::Cint
end

struct CGenuineResult
    genuine::Cint
    serial::NTuple{15,UInt8}
    provisioned_date::NTuple{11,UInt8}
end

struct CDeviceInfo
    serial::NTuple{15,UInt8}
    path::NTuple{512,UInt8}
    vendor_id::UInt16
    product_id::UInt16
end

_from_c(bytes::NTuple{N,UInt8}) where {N} = begin
    v = collect(bytes)
    stop = findfirst(iszero, v)
    String(v[1:(stop === nothing ? N : stop - 1)])
end

# --- public plain types ------------------------------------------------------

"""Who can decrypt data produced by [`app_encrypt`](@ref)."""
@enum Scope DEVICE = 0 DEVELOPER = 1

"""One discovered dongle. `path` is opaque; pass it to [`open_path`](@ref)."""
struct DeviceInfo
    serial::String
    path::String
    vendor_id::UInt16
    product_id::UInt16
end

"""
Plaintext device info. `watchdog_reboot` means the dongle's *previous* boot ended
in a watchdog timeout — the firmware hung and reset itself. It is the only trace a
field hang leaves behind, and a power cycle clears it, so log it.

`isolated` means the dongle confirmed at boot that its USB and parsing code is fenced off
from keys and storage. Anything that is not a dongle reports false.
"""
struct Info
    protocol_version::Tuple{Int,Int}
    firmware_version::Tuple{Int,Int,Int}
    se_ready::Bool
    provisioned::Bool
    data_capacity::UInt32
    data_free::UInt32
    watchdog_reboot::Bool
    isolated::Bool
    writeauth_rotated::Bool
end

struct GenuineResult
    genuine::Bool
    serial::String
    provisioned_date::String
end

struct RecordInfo
    name::String
    size::UInt32
end

# --- Context -----------------------------------------------------------------

"""
    Context()

The library context: the entry point for finding and opening dongles. `close` it
when done, after the dongles it opened.
"""
mutable struct Context
    handle::Ptr{Cvoid}
    Context() = begin
        out = Ref{Ptr{Cvoid}}(C_NULL)
        rc = ccall((:licd_init, LIB), Cint, (Ref{Ptr{Cvoid}},), out)
        rc == OK || _fail(rc, "licd_init")
        new(out[])
    end
end

Base.isopen(ctx::Context) = ctx.handle != C_NULL

function Base.close(ctx::Context)
    if ctx.handle != C_NULL
        handle = ctx.handle
        ctx.handle = C_NULL
        ccall((:licd_free, LIB), Cvoid, (Ptr{Cvoid},), handle)
    end
    return nothing
end

function _handle(ctx::Context)
    ctx.handle == C_NULL && _fail(E_INVALID_ARG, "context", "the context has been closed")
    return ctx.handle
end

"""The SDK's diagnostic detail for the most recent failure on this thread."""
last_error_detail(ctx::Context) =
    unsafe_string(ccall((:licd_error_detail, LIB), Cstring, (Ptr{Cvoid},), _handle(ctx)))

function _check(ctx::Context, rc::Cint, operation::AbstractString)
    rc == OK && return nothing
    detail = ctx.handle == C_NULL ? "" : last_error_detail(ctx)
    _fail(rc, operation, detail)
end

"""The native core library's version, as `(major, minor, patch)`."""
function library_version()
    major, minor, patch = Ref{Cint}(0), Ref{Cint}(0), Ref{Cint}(0)
    ccall((:licd_version, LIB), Cvoid, (Ref{Cint}, Ref{Cint}, Ref{Cint}), major, minor, patch)
    return (Int(major[]), Int(minor[]), Int(patch[]))
end

"""
    set_trust_root!(ctx, der)

Overrides the CA root [`verify_genuine`](@ref) checks against. Applications do not
need this: a release build embeds the KeyNub production root. It exists for dongles
provisioned against a different CA, and for vendor tooling.
"""
function set_trust_root!(ctx::Context, der::AbstractVector{UInt8})
    rc = ccall((:licd_set_trust_root, LIB), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
               _handle(ctx), der, length(der))
    _check(ctx, rc, "licd_set_trust_root")
end

"""Connected dongles. An empty vector means none are attached, which is normal."""
function enumerate_dongles(ctx::Context)
    list = Ref{Ptr{CDeviceInfo}}(C_NULL)
    count = Ref{Csize_t}(0)
    rc = ccall((:licd_enumerate, LIB), Cint, (Ptr{Cvoid}, Ref{Ptr{CDeviceInfo}}, Ref{Csize_t}),
               _handle(ctx), list, count)
    _check(ctx, rc, "licd_enumerate")
    out = DeviceInfo[]
    if list[] != C_NULL
        try
            for i in 1:count[]
                entry = unsafe_load(list[], i)
                push!(out, DeviceInfo(_from_c(entry.serial), _from_c(entry.path),
                                      entry.vendor_id, entry.product_id))
            end
        finally
            ccall((:licd_free_device_list, LIB), Cvoid, (Ptr{CDeviceInfo}, Csize_t),
                  list[], count[])
        end
    end
    return out
end

# --- Dongle ------------------------------------------------------------------

"""An open connection to a dongle. Plaintext operations here; stored data needs a [`Session`](@ref)."""
mutable struct Dongle
    handle::Ptr{Cvoid}
    ctx::Context
end

"""
    open_dongle(ctx[, serial])

Opens the dongle with this serial, or the first one found.
"""
function open_dongle(ctx::Context, serial::Union{Nothing,AbstractString} = nothing)
    out = Ref{Ptr{Cvoid}}(C_NULL)
    rc = ccall((:licd_open, LIB), Cint, (Ptr{Cvoid}, Cstring, Ref{Ptr{Cvoid}}),
               _handle(ctx), serial === nothing ? C_NULL : serial, out)
    _check(ctx, rc, "licd_open")
    return Dongle(out[], ctx)
end

"""Opens a specific dongle by the `path` from [`enumerate_dongles`](@ref)."""
function open_path(ctx::Context, path::AbstractString)
    out = Ref{Ptr{Cvoid}}(C_NULL)
    rc = ccall((:licd_open_path, LIB), Cint, (Ptr{Cvoid}, Cstring, Ref{Ptr{Cvoid}}),
               _handle(ctx), path, out)
    _check(ctx, rc, "licd_open_path")
    return Dongle(out[], ctx)
end

"""
    adopt(ctx, handle)

Takes ownership of a device opened through the C ABI directly, so this binding can
be introduced into existing `ccall` code a call at a time.
"""
adopt(ctx::Context, handle::Ptr{Cvoid}) = Dongle(handle, ctx)

Base.isopen(dongle::Dongle) = dongle.handle != C_NULL

function Base.close(dongle::Dongle)
    if dongle.handle != C_NULL
        handle = dongle.handle
        dongle.handle = C_NULL
        ccall((:licd_close, LIB), Cvoid, (Ptr{Cvoid},), handle)
    end
    return nothing
end

function _handle(dongle::Dongle)
    dongle.handle == C_NULL && _fail(E_INVALID_ARG, "dongle", "the dongle has been closed")
    return dongle.handle
end

"""Reads the plaintext device info."""
function info(dongle::Dongle)
    raw = Ref{CInfo}()
    rc = ccall((:licd_get_info, LIB), Cint, (Ptr{Cvoid}, Ref{CInfo}), _handle(dongle), raw)
    _check(dongle.ctx, rc, "licd_get_info")
    v = raw[]
    return Info((Int(v.proto_major), Int(v.proto_minor)),
                (Int(v.fw_major), Int(v.fw_minor), Int(v.fw_patch)),
                v.se_ready != 0, v.provisioned != 0,
                v.data_capacity, v.data_free, v.watchdog_reboot != 0,
                v.isolated != 0,
                v.writeauth_rotated != 0)
end

"""Reads the dongle serial as hex."""
function serial(dongle::Dongle)
    buffer = zeros(UInt8, 15)
    rc = ccall((:licd_get_serial, LIB), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
               _handle(dongle), buffer, length(buffer))
    _check(dongle.ctx, rc, "licd_get_serial")
    stop = findfirst(iszero, buffer)
    return String(buffer[1:(stop === nothing ? length(buffer) : stop - 1)])
end

"""
    verify_genuine(dongle)

Proves authenticity: the certificate chain to the trusted root plus a live ECDSA
challenge-response. Throws unless the dongle is genuine.
"""
function verify_genuine(dongle::Dongle)
    raw = Ref{CGenuineResult}()
    rc = ccall((:licd_verify_genuine, LIB), Cint, (Ptr{Cvoid}, Ref{CGenuineResult}),
               _handle(dongle), raw)
    _check(dongle.ctx, rc, "licd_verify_genuine")
    v = raw[]
    return GenuineResult(v.genuine != 0, _from_c(v.serial),
                         _from_c(v.provisioned_date))
end

"""
    is_genuine(dongle) -> Bool

The non-throwing form, for a licence gate. Fails closed: a missing dongle, an I/O
error and an invalid certificate all return `false`.
"""
function is_genuine(dongle::Dongle)
    try
        return verify_genuine(dongle).genuine
    catch
        return false
    end
end

# --- Session -----------------------------------------------------------------

"""An open encrypted session: records, counters and app-crypto."""
mutable struct Session
    dongle::Dongle
    open::Bool
end

"""
    session(dongle) -> Session
    session(f, dongle)

Opens an encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM). The two-argument
form closes it afterwards, whatever happens.
"""
function session(dongle::Dongle)
    rc = ccall((:licd_session_open, LIB), Cint, (Ptr{Cvoid},), _handle(dongle))
    _check(dongle.ctx, rc, "licd_session_open")
    return Session(dongle, true)
end

function session(f::Function, dongle::Dongle)
    s = session(dongle)
    try
        return f(s)
    finally
        close(s)
    end
end

Base.isopen(s::Session) = s.open

"""Ends the session, zeroizing the session keys on the dongle. Never throws."""
function Base.close(s::Session)
    if s.open
        s.open = false
        isopen(s.dongle) && ccall((:licd_session_close, LIB), Cint, (Ptr{Cvoid},), s.dongle.handle)
    end
    return nothing
end

function _device(s::Session)
    s.open || _fail(E_SESSION_EXPIRED, "session", "the session has been closed")
    return _handle(s.dongle)
end

_check(s::Session, rc::Cint, operation::AbstractString) = _check(s.dongle.ctx, rc, operation)

function _require_name(name::AbstractString)
    isempty(name) && throw(ArgumentError("the record name must not be empty"))
    return name
end

"""
Elevates to the write role with the developer master key (a DER EC private key).
This belongs in your licence-issuing tooling; never ship that key
in the application your users run.
"""
function authorize_write(s::Session, master_key_der::AbstractVector{UInt8})
    rc = ccall((:licd_write_auth, LIB), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
               _device(s), master_key_der, length(master_key_der))
    _check(s, rc, "licd_write_auth")
end

"""
Replaces the dongle's write-auth key with your own (a DER EC private key). Call
`authorize_write` with the current key first. From the next session on, only the
new key elevates.
"""
function rotate_write_key(s::Session, new_key_der::AbstractVector{UInt8})
    rc = ccall((:licd_write_auth_rotate, LIB), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
               _device(s), new_key_der, length(new_key_der))
    _check(s, rc, "licd_write_auth_rotate")
end

"""Records stored on the dongle."""
function list_records(s::Session)
    names = Ref{Ptr{Ptr{UInt8}}}(C_NULL)
    sizes = Ref{Ptr{UInt32}}(C_NULL)
    count = Ref{Csize_t}(0)
    rc = ccall((:licd_record_list, LIB), Cint,
               (Ptr{Cvoid}, Ref{Ptr{Ptr{UInt8}}}, Ref{Ptr{UInt32}}, Ref{Csize_t}),
               _device(s), names, sizes, count)
    _check(s, rc, "licd_record_list")
    out = RecordInfo[]
    if names[] != C_NULL
        try
            for i in 1:count[]
                push!(out, RecordInfo(unsafe_string(unsafe_load(names[], i)),
                                      unsafe_load(sizes[], i)))
            end
        finally
            ccall((:licd_free_record_list, LIB), Cvoid,
                  (Ptr{Ptr{UInt8}}, Ptr{UInt32}, Csize_t), names[], sizes[], count[])
        end
    end
    return out
end

# The C callback signature. @cfunction needs a top-level function, so the Julia
# callback travels through a task-local slot rather than a closure.
const _PROGRESS = Ref{Any}(nothing)

function _progress_shim(done::UInt32, total::UInt32, ::Ptr{Cvoid})::Cint
    callback = _PROGRESS[]
    callback === nothing && return Cint(1)
    try
        # Anything but an explicit false continues, so a callback that only draws a
        # progress bar is safe.
        return callback(Int(done), Int(total)) === false ? Cint(0) : Cint(1)
    catch
        # Throwing through the C frames would skip the SDK's own cleanup and strand
        # the device mid-transfer; cancel instead and let the status surface.
        return Cint(0)
    end
end

function _with_progress(f::Function, progress)
    progress === nothing && return f(C_NULL)
    previous = _PROGRESS[]
    _PROGRESS[] = progress
    shim = @cfunction(_progress_shim, Cint, (UInt32, UInt32, Ptr{Cvoid}))
    try
        return f(shim)
    finally
        _PROGRESS[] = previous
    end
end

"""
    read_record(session, name; progress = nothing)

Reads a record. `progress` is called as `progress(done, total)`; return `false` to
cancel, which throws `OperationCancelledError`.
"""
function read_record(s::Session, name::AbstractString; progress = nothing)
    _require_name(name)
    device = _device(s)
    got, total = Ref{UInt32}(0), Ref{UInt32}(0)

    # Probe for the size first, so progress runs monotonically from 0 to total.
    probe = zeros(UInt8, 1)
    rc = ccall((:licd_record_read, LIB), Cint,
               (Ptr{Cvoid}, Cstring, UInt32, Ptr{UInt8}, UInt32, Ref{UInt32}, Ref{UInt32},
                Ptr{Cvoid}, Ptr{Cvoid}),
               device, name, 0, probe, 1, got, total, C_NULL, C_NULL)
    _check(s, rc, "licd_record_read")
    total[] == 0 && return UInt8[]

    buffer = zeros(UInt8, total[])
    rc = _with_progress(progress) do shim
        ccall((:licd_record_read, LIB), Cint,
              (Ptr{Cvoid}, Cstring, UInt32, Ptr{UInt8}, UInt32, Ref{UInt32}, Ref{UInt32},
               Ptr{Cvoid}, Ptr{Cvoid}),
              device, name, 0, buffer, total[], got, total, shim, C_NULL)
    end
    _check(s, rc, "licd_record_read")
    return buffer[1:got[]]
end

"""Atomically replaces a record. Requires the write role."""
function write_record(s::Session, name::AbstractString, data::AbstractVector{UInt8};
                      progress = nothing)
    _require_name(name)
    device = _device(s)
    rc = _with_progress(progress) do shim
        ccall((:licd_record_write, LIB), Cint,
              (Ptr{Cvoid}, Cstring, Ptr{UInt8}, UInt32, Ptr{Cvoid}, Ptr{Cvoid}),
              device, name, data, length(data), shim, C_NULL)
    end
    _check(s, rc, "licd_record_write")
end

write_record(s::Session, name::AbstractString, data::AbstractString; kwargs...) =
    write_record(s, name, Vector{UInt8}(codeunits(data)); kwargs...)

"""Erases one record. Requires the write role."""
function erase_record(s::Session, name::AbstractString)
    # A null name means "erase everything" to the C API; that is
    # `erase_all_records` here, so an empty string cannot wipe the dongle.
    _require_name(name)
    rc = ccall((:licd_record_erase, LIB), Cint, (Ptr{Cvoid}, Cstring), _device(s), name)
    _check(s, rc, "licd_record_erase")
end

"""Erases every record. Requires the write role."""
function erase_all_records(s::Session)
    rc = ccall((:licd_record_erase, LIB), Cint, (Ptr{Cvoid}, Ptr{UInt8}), _device(s), C_NULL)
    _check(s, rc, "licd_record_erase")
end

"""Reads a hardware monotonic counter."""
function read_counter(s::Session, counter_id::Integer)
    value = Ref{UInt32}(0)
    rc = ccall((:licd_counter_read, LIB), Cint, (Ptr{Cvoid}, UInt8, Ref{UInt32}),
               _device(s), UInt8(counter_id), value)
    _check(s, rc, "licd_counter_read")
    return value[]
end

"""Increments a counter and returns the new value. Irreversible: it is monotonic in hardware."""
function increment_counter(s::Session, counter_id::Integer)
    value = Ref{UInt32}(0)
    rc = ccall((:licd_counter_increment, LIB), Cint, (Ptr{Cvoid}, UInt8, Ref{UInt32}),
               _device(s), UInt8(counter_id), value)
    _check(s, rc, "licd_counter_increment")
    return value[]
end

function _take_buffer(out::Ref{Ptr{UInt8}}, len::Ref{UInt32})
    out[] == C_NULL && return UInt8[]
    try
        return len[] == 0 ? UInt8[] : copy(unsafe_wrap(Array, out[], Int(len[])))
    finally
        ccall((:licd_free_buffer, LIB), Cvoid, (Ptr{UInt8},), out[])
    end
end

"""
    app_encrypt(session, scope, plaintext)

Encrypts so that only a dongle of `scope` can decrypt. This is the pair to build a
licence check on: put something the program genuinely needs through it, so removing
the check removes the data.
"""
function app_encrypt(s::Session, scope::Scope, plaintext::AbstractVector{UInt8})
    out = Ref{Ptr{UInt8}}(C_NULL)
    out_len = Ref{UInt32}(0)
    rc = ccall((:licd_app_encrypt, LIB), Cint,
               (Ptr{Cvoid}, Cint, Ptr{UInt8}, UInt32, Ref{Ptr{UInt8}}, Ref{UInt32}),
               _device(s), Cint(Integer(scope)), plaintext, length(plaintext), out, out_len)
    _check(s, rc, "licd_app_encrypt")
    return _take_buffer(out, out_len)
end

app_encrypt(s::Session, scope::Scope, plaintext::AbstractString) =
    app_encrypt(s, scope, Vector{UInt8}(codeunits(plaintext)))

"""Decrypts a blob produced by [`app_encrypt`](@ref), using the dongle."""
function app_decrypt(s::Session, packed::AbstractVector{UInt8})
    out = Ref{Ptr{UInt8}}(C_NULL)
    out_len = Ref{UInt32}(0)
    rc = ccall((:licd_app_decrypt, LIB), Cint,
               (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ref{Ptr{UInt8}}, Ref{UInt32}),
               _device(s), packed, length(packed), out, out_len)
    _check(s, rc, "licd_app_decrypt")
    return _take_buffer(out, out_len)
end

end # module
