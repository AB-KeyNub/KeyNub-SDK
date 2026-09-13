# Tests against a stand-in for the C ABI (stub/licd_stub.c), run by runtests.jl in
# a Julia process whose KEYNUB_LICDONGLE_LIBRARY names the compiled stand-in.
# Every call of the binding is exercised end to end, without a dongle.

using Libdl
using Test
using KeyNubLicenseDongle

const KN = KeyNubLicenseDongle

const FACTORY_KEY = UInt8[0x30, 0x10, 0x01, 0x02, 0x03]
const REPLACEMENT_KEY = UInt8[0x30, 0x11, 0x09, 0x08, 0x07, 0x06]

"""Runs `body(ctx, dongle)` against the stand-in device and always tears down."""
function with_device(body)
    ctx = Context()
    try
        dongle = open_dongle(ctx)
        try
            return body(ctx, dongle)
        finally
            close(dongle)
        end
    finally
        close(ctx)
    end
end

@testset "against the ABI stand-in" begin
    @test KN.LIB == ENV["KEYNUB_LICDONGLE_LIBRARY"]
    @test library_version() == (9, 8, 7)

    @testset "structure layouts match the C compiler" begin
        info_size, device_size, genuine_size = Ref{Cint}(0), Ref{Cint}(0), Ref{Cint}(0)
        sizes = Libdl.dlsym(Libdl.dlopen(KN.LIB), :licd_stub_sizes)
        ccall(sizes, Cvoid, (Ref{Cint}, Ref{Cint}, Ref{Cint}), info_size, device_size, genuine_size)
        @test sizeof(KN.CInfo) == info_size[]
        @test sizeof(KN.CDeviceInfo) == device_size[]
        @test sizeof(KN.CGenuineResult) == genuine_size[]
    end

    @testset "enumerate and open" begin
        ctx = Context()
        devices = enumerate_dongles(ctx)
        @test length(devices) == 1
        @test devices[1].serial == "04A1B2C3D4E5F6"
        @test devices[1].path == "stub:0"
        @test devices[1].vendor_id == 0x1234
        @test devices[1].product_id == 0xABCD

        err = try
            open_dongle(ctx, "nope")
        catch e
            e
        end
        @test err isa DeviceNotFoundError
        @test err.operation == "licd_open"
        @test err.detail == "no dongle with that serial"
        @test last_error_detail(ctx) == "no dongle with that serial"
        @test_throws DeviceNotFoundError open_path(ctx, "stub:9")

        for dongle in (open_dongle(ctx), open_dongle(ctx, "04A1B2C3D4E5F6"), open_path(ctx, "stub:0"))
            @test isopen(dongle)
            @test serial(dongle) == "04A1B2C3D4E5F6"
            close(dongle)
            @test !isopen(dongle)
        end
        close(ctx)
    end

    @testset "info, serial and genuine" begin
        with_device() do _, dongle
            i = info(dongle)
            @test i.protocol_version == (1, 0)
            @test i.firmware_version == (2, 3, 4)
            @test i.se_ready && i.provisioned && i.isolated
            @test i.data_capacity == 1024 * 1024
            @test i.data_free == 1000000
            @test i.watchdog_reboot === false
            @test i.writeauth_rotated === false

            result = verify_genuine(dongle)
            @test result.genuine
            @test result.serial == "04A1B2C3D4E5F6"
            @test result.provisioned_date == "2026-08-15"
            @test is_genuine(dongle)
        end
    end

    @testset "the trust root is consulted" begin
        with_device() do ctx, dongle
            @test_throws LicenseDongleError set_trust_root!(ctx, UInt8[])
            @test_throws CertificateInvalidError set_trust_root!(ctx, UInt8[0x02, 0x01, 0x00])
            set_trust_root!(ctx, vcat(UInt8[0x30, 0x82, 0x01, 0x00], fill(UInt8(0xAB), 128)))
            @test_throws CertificateInvalidError verify_genuine(dongle)
            @test !is_genuine(dongle)
            set_trust_root!(ctx, vcat(UInt8[0x30, 0x82, 0x01, 0x00], fill(UInt8(0x01), 128)))
            @test is_genuine(dongle)
        end
    end

    @testset "records, counters and app-crypto" begin
        with_device() do _, dongle
            session(dongle) do s
                @test isopen(s)
                payload = Vector{UInt8}(codeunits("license-blob-0123456789"))
                @test_throws WriteAuthorizationRequiredError write_record(s, "lic", payload)
                @test_throws NotGenuineError authorize_write(s, UInt8[0x30, 0x00])
                @test_throws LicenseDongleError authorize_write(s, UInt8[])
                authorize_write(s, FACTORY_KEY)
                write_record(s, "lic", payload)
                @test read_record(s, "lic") == payload

                write_record(s, "cfg", "cfgdata")
                records = list_records(s)
                @test length(records) == 2
                @test sort([r.name for r in records]) == ["cfg", "lic"]
                @test first(r.size for r in records if r.name == "lic") == length(payload)

                @test_throws RecordNotFoundError read_record(s, "nope")
                @test_throws RecordNotFoundError erase_record(s, "nope")
                @test_throws ArgumentError erase_record(s, "")
                @test length(list_records(s)) == 2
                erase_record(s, "cfg")
                @test [r.name for r in list_records(s)] == ["lic"]

                write_record(s, "empty", UInt8[])
                @test isempty(read_record(s, "empty"))

                before = read_counter(s, 0)
                @test increment_counter(s, 0) == before + 1
                @test read_counter(s, 0) == before + 1
                @test read_counter(s, 1) == 0
                err = try
                    read_counter(s, 7)
                catch e
                    e
                end
                @test err isa LicenseDongleError
                @test err.status == KN.E_RANGE

                secret = UInt8[(i * 3 + 7) % 256 for i in 0:99]
                for scope in (DEVICE, DEVELOPER)
                    blob = app_encrypt(s, scope, secret)
                    @test length(blob) > length(secret)
                    @test blob[1] == Integer(scope)
                    @test app_decrypt(s, blob) == secret
                    tampered = copy(blob)
                    tampered[end] = xor(tampered[end], 0x01)
                    err = try
                        app_decrypt(s, tampered)
                    catch e
                        e
                    end
                    @test err isa LicenseDongleError
                    @test err.status == KN.E_TAG_MISMATCH
                end
                @test app_decrypt(s, app_encrypt(s, DEVICE, "text")) == codeunits("text")
                @test isempty(app_decrypt(s, app_encrypt(s, DEVICE, UInt8[])))

                erase_all_records(s)
                @test isempty(list_records(s))
            end
        end
    end

    @testset "rotation replaces the key that elevates" begin
        with_device() do _, dongle
            session(dongle) do s
                @test_throws WriteAuthorizationRequiredError rotate_write_key(s, REPLACEMENT_KEY)
                authorize_write(s, FACTORY_KEY)
                @test_throws LicenseDongleError rotate_write_key(s, UInt8[])
                rotate_write_key(s, REPLACEMENT_KEY)
                write_record(s, "lic", "still-writable")
            end
            @test info(dongle).writeauth_rotated
            session(dongle) do s
                @test_throws NotGenuineError authorize_write(s, FACTORY_KEY)
                authorize_write(s, REPLACEMENT_KEY)
                write_record(s, "lic", "new-key-writes")
                @test String(read_record(s, "lic")) == "new-key-writes"
            end
        end
    end

    @testset "progress and cancellation" begin
        with_device() do _, dongle
            session(dongle) do s
                authorize_write(s, FACTORY_KEY)
                blob = UInt8[(i * 31 + 5) % 256 for i in 0:1999]
                writes = Tuple{Int,Int}[]
                write_record(s, "big", blob; progress = (done, total) -> begin
                    push!(writes, (done, total))
                    true
                end)
                @test last(writes) == (2000, 2000)
                @test_throws OperationCancelledError write_record(s, "big2", blob;
                                                                 progress = (_, _) -> false)

                ticks = Tuple{Int,Int}[]
                data = read_record(s, "big"; progress = (done, total) -> begin
                    push!(ticks, (done, total))
                    true
                end)
                @test data == blob
                @test length(ticks) == 4
                @test last(ticks) == (2000, 2000)
                @test_throws OperationCancelledError read_record(s, "big"; progress = (_, _) -> false)
                @test read_record(s, "big"; progress = (_, _) -> nothing) == blob
                @test_throws OperationCancelledError read_record(s, "big";
                                                                progress = (_, _) -> error("boom"))
                @test read_record(s, "big") == blob
            end
        end
    end

    @testset "closed session and dongle are refused" begin
        ctx = Context()
        dongle = open_dongle(ctx)
        s = session(dongle)
        close(s)
        close(s)
        @test !isopen(s)
        @test_throws SessionExpiredError read_record(s, "lic")

        second = session(dongle)
        close(dongle)
        @test_throws LicenseDongleError read_record(second, "lic")
        close(second)
        close(ctx)
    end
end
