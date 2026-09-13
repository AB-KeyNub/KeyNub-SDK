# Tests for the Julia binding. None of them need a dongle.
#
# This file runs against the shipped native library: loading it, the version,
# enumeration, the status-code mapping and closed handles. It then compiles a
# stand-in for the C ABI (stub/licd_stub.c) with the C compiler on the path and
# runs stub_tests.jl in a second Julia process whose KEYNUB_LICDONGLE_LIBRARY
# names it, which exercises every call end to end.

using Test
using KeyNubLicenseDongle

const KN = KeyNubLicenseDongle

const STATUS_TYPES = [
    (KN.E_INVALID_ARG, LicenseDongleError),
    (KN.E_NO_DEVICE, DeviceNotFoundError),
    (KN.E_ACCESS_DENIED, LicenseDongleError),
    (KN.E_IO, LicenseDongleError),
    (KN.E_TIMEOUT, LicenseDongleError),
    (KN.E_PROTOCOL, LicenseDongleError),
    (KN.E_NOT_GENUINE, NotGenuineError),
    (KN.E_CERT_INVALID, CertificateInvalidError),
    (KN.E_SESSION_EXPIRED, SessionExpiredError),
    (KN.E_TAG_MISMATCH, LicenseDongleError),
    (KN.E_RANGE, LicenseDongleError),
    (KN.E_STORAGE_FULL, LicenseDongleError),
    (KN.E_BUSY, LicenseDongleError),
    (KN.E_NOT_FOUND, RecordNotFoundError),
    (KN.E_AUTH_REQUIRED, WriteAuthorizationRequiredError),
    (KN.E_FW_INCOMPATIBLE, LicenseDongleError),
    (KN.E_SDK_TOO_OLD, LicenseDongleError),
    (KN.E_CANCELLED, OperationCancelledError),
    (KN.E_NOT_IMPLEMENTED, LicenseDongleError),
    (KN.E_INTERNAL, LicenseDongleError),
]

const SOME_KEY = UInt8[0x30, 0x10, 0x01, 0x02, 0x03]

"""Compiles the ABI stand-in and returns its path, or `nothing` without a C compiler."""
function build_stub()
    root = KN.sdk_root()
    root === nothing && return nothing
    include_dir = joinpath(root, "include")
    isfile(joinpath(include_dir, "licdongle.h")) || return nothing
    compiler = something(Sys.which("gcc"), Sys.which("cc"), Sys.which("clang"), Some(nothing))
    compiler === nothing && return nothing
    ext = Sys.iswindows() ? "dll" : (Sys.isapple() ? "dylib" : "so")
    out = joinpath(mktempdir(), "licd_stub.$ext")
    src = joinpath(@__DIR__, "stub", "licd_stub.c")
    pic = Sys.iswindows() ? String[] : ["-fPIC"]
    try
        run(`$compiler -shared $pic -O1 -DLICD_BUILD_SHARED -I$include_dir -o $out $src`)
    catch err
        @warn "the ABI stand-in did not compile" compiler err
        return nothing
    end
    return out
end

@testset "KeyNubLicenseDongle" begin
    @testset "the library loads" begin
        @test !isempty(KN.LIB)
        occursin(Base.Filesystem.path_separator, KN.LIB) && @test isfile(KN.LIB)
        major, minor, patch = library_version()
        @test (major, minor, patch) >= (1, 1, 1)
        @test KN._repo_rid() in ("win-x64", "win-x86", "win-arm64", "linux-x64",
                                 "linux-arm64", "osx-x64", "osx-arm64", "linux-unknown")
        @test endswith(KN._default_basename(), Sys.iswindows() ? ".dll" : (Sys.isapple() ? ".dylib" : ".so"))
        @test KN.sdk_root() === nothing || isdir(joinpath(KN.sdk_root(), "natives"))
    end

    @testset "status codes map to exception types" begin
        for (status, T) in STATUS_TYPES
            @test KN._error_type(status) === T
            @test !isempty(KN._status_text(status))
            err = try
                KN._fail(status, "licd_op", "the detail")
                nothing
            catch e
                e
            end
            @test err isa T
            @test err.status == status
            @test err.operation == "licd_op"
            @test err.message == KN._status_text(status)
            @test err.detail == "the detail"
            text = sprint(showerror, err)
            @test occursin(string(nameof(T)), text)
            @test occursin("licd_op", text)
            @test occursin(err.message, text)
            @test occursin("(the detail)", text)
        end
        @test KN._error_type(Cint(-99)) === LicenseDongleError
        @test !occursin("(", sprint(showerror, LicenseDongleError(KN.E_IO, "op", "I/O error", "")))
        @test KN._status_text(KN.OK) != KN._status_text(KN.E_INVALID_ARG)
    end

    @testset "C string fields" begin
        @test KN._from_c((UInt8('a'), UInt8('b'), 0x00, UInt8('z'))) == "ab"
        @test KN._from_c((UInt8('a'), UInt8('b'))) == "ab"
        @test KN._from_c((0x00, 0x00)) == ""
    end

    @testset "progress shim" begin
        KN._PROGRESS[] = nothing
        @test KN._progress_shim(UInt32(1), UInt32(2), C_NULL) == 1
        @test KN._with_progress(shim -> shim, nothing) == C_NULL
        calls = Tuple{Int,Int}[]
        KN._with_progress((done, total) -> (push!(calls, (done, total)); true)) do shim
            @test shim != C_NULL
            @test KN._progress_shim(UInt32(3), UInt32(9), C_NULL) == 1
        end
        @test calls == [(3, 9)]
        @test KN._PROGRESS[] === nothing
        KN._with_progress((_, _) -> false) do _
            @test KN._progress_shim(UInt32(1), UInt32(1), C_NULL) == 0
        end
        KN._with_progress((_, _) -> error("inside the callback")) do _
            @test KN._progress_shim(UInt32(1), UInt32(1), C_NULL) == 0
        end
        KN._with_progress((_, _) -> nothing) do _
            @test KN._progress_shim(UInt32(1), UInt32(1), C_NULL) == 1
        end
    end

    @testset "context" begin
        ctx = Context()
        @test isopen(ctx)
        @test last_error_detail(ctx) isa String
        @test_throws LicenseDongleError set_trust_root!(ctx, UInt8[])
        close(ctx)
        close(ctx)
        @test !isopen(ctx)
        err = try
            enumerate_dongles(ctx)
        catch e
            e
        end
        @test err isa LicenseDongleError
        @test err.status == KN.E_INVALID_ARG
        @test err.detail == "the context has been closed"
        @test_throws LicenseDongleError last_error_detail(ctx)
        @test_throws LicenseDongleError set_trust_root!(ctx, UInt8[0x30])
        @test_throws LicenseDongleError open_dongle(ctx)
        @test_throws LicenseDongleError open_path(ctx, "anything")
    end

    @testset "enumeration without a dongle" begin
        ctx = Context()
        try
            devices = enumerate_dongles(ctx)
            @test devices isa Vector{KN.DeviceInfo}
            isempty(devices) && @test_throws DeviceNotFoundError open_dongle(ctx)
            @test_throws DeviceNotFoundError open_dongle(ctx, "00000000000000")
            @test_throws KN._AnyError open_path(ctx, "no-such-device-path")
        finally
            close(ctx)
        end
    end

    @testset "closed dongle and session" begin
        ctx = Context()
        dongle = KN.adopt(ctx, C_NULL)
        @test !isopen(dongle)
        close(dongle)
        for f in (info, serial, verify_genuine, session)
            err = try
                f(dongle)
            catch e
                e
            end
            @test err isa LicenseDongleError
            @test err.status == KN.E_INVALID_ARG
            @test err.detail == "the dongle has been closed"
        end
        @test is_genuine(dongle) == false
        @test_throws LicenseDongleError session(s -> s, dongle)

        s = KN.Session(dongle, false)
        @test !isopen(s)
        close(s)
        @test_throws SessionExpiredError authorize_write(s, SOME_KEY)
        @test_throws SessionExpiredError rotate_write_key(s, SOME_KEY)
        @test_throws SessionExpiredError list_records(s)
        @test_throws SessionExpiredError read_record(s, "lic")
        @test_throws SessionExpiredError write_record(s, "lic", UInt8[1])
        @test_throws SessionExpiredError write_record(s, "lic", "text")
        @test_throws SessionExpiredError erase_record(s, "lic")
        @test_throws SessionExpiredError erase_all_records(s)
        @test_throws SessionExpiredError read_counter(s, 0)
        @test_throws SessionExpiredError increment_counter(s, 0)
        @test_throws SessionExpiredError app_encrypt(s, DEVICE, UInt8[1])
        @test_throws SessionExpiredError app_encrypt(s, DEVELOPER, "text")
        @test_throws SessionExpiredError app_decrypt(s, UInt8[1])

        # An open session whose dongle has gone reports the dongle, not freed memory.
        gone = KN.Session(dongle, true)
        @test_throws LicenseDongleError read_record(gone, "lic")
        close(gone)
        @test !isopen(gone)

        @test_throws ArgumentError erase_record(s, "")
        @test_throws ArgumentError read_record(s, "")
        @test_throws ArgumentError write_record(s, "", UInt8[])
        close(ctx)
    end

    @testset "every call, against the ABI stand-in" begin
        stub = build_stub()
        if stub === nothing
            @info "no C compiler on the path: stub_tests.jl is skipped"
        else
            script = joinpath(@__DIR__, "stub_tests.jl")
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $script`
            cmd = addenv(cmd, "KEYNUB_LICDONGLE_LIBRARY" => stub)
            @test success(pipeline(cmd; stdout = stdout, stderr = stderr))
        end
    end
end
