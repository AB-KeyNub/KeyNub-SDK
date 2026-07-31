# KeyNub dongle check from Julia: enumerate -> open -> verify -> session ->
# read a record -> app-crypto round trip.
#
#   KEYNUB_LICDONGLE_LIBRARY=../../build/keynub_licdongle.dll \
#     julia --project=. verify_and_read.jl
#
# No packages: ccall is part of the language, so nothing sits in the path of the
# licence check that a customer could substitute.
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# READ FIRST: docs/integration-security.md. This sample prints whether the dongle
# is genuine, which is the one thing a real licence check must not do — a printed
# boolean is a deleted line away from nothing. protect_something shows the shape
# that actually protects something. For a Julia package that is usually easy,
# because the valuable part is normally data: a correlation set, fitted parameters,
# a proprietary model's coefficients.

using KeyNubLicDongle

function report(dongle)
    i = info(dongle)
    pmaj, pmin = i.protocol_version
    fmaj, fmin, fpatch = i.firmware_version
    println("Protocol v$pmaj.$pmin, firmware v$fmaj.$fmin.$fpatch, " *
            "$(i.data_free) of $(i.data_capacity) bytes free.")

    if i.watchdog_reboot
        # The only trace a firmware hang leaves behind. Worth reporting to support.
        println("WARNING: this dongle's previous boot ended in a watchdog reset.")
    end

    r = verify_genuine(dongle)
    println("Genuine: $(r.genuine) (serial $(r.serial), batch $(r.batch), " *
            "provisioned $(r.provisioned_date))")
end

function read_records(s)
    records = list_records(s)
    println("$(length(records)) record(s) on the dongle:")
    for rec in records
        println("  " * rpad(rec.name, 16) * lpad(string(rec.size), 6) * " bytes")
    end

    # A missing record is a normal state, not an error.
    if any(rec -> rec.name == "license", records)
        data = read_record(s, "license")
        println("Read $(length(data)) bytes from the license record.")
    end
end

# The part that actually protects something. At licence-issue time you would call
# app_encrypt once, with a developer dongle, and ship only the blob; the package
# then cannot proceed without a dongle, because it holds no other copy of the data.
# DEVELOPER lets any dongle from your batch decrypt it, so one file serves every
# customer; DEVICE locks it to one dongle.
function protect_something(s)
    needed = Vector{UInt8}("the data this program cannot run without")

    sealed = app_encrypt(s, DEVELOPER, needed)
    recovered = app_decrypt(s, sealed)

    outcome = recovered == needed ? "recovered intact" : "MISMATCH"
    println("App-crypto round trip: $(length(needed)) bytes -> " *
            "$(length(sealed)) sealed -> $outcome")
end

function main()
    # library_version returns a plain tuple, not a struct.
    major, minor, patch = library_version()
    println("KeyNub SDK $major.$minor.$patch")

    ctx = Context()
    try
        devices = enumerate_dongles(ctx)
        println("Found $(length(devices)) KeyNub dongle(s).")
        for (i, d) in enumerate(devices)
            println("  [$(i - 1)] serial $(d.serial) " *
                    "(VID $(string(d.vendor_id, base = 16, pad = 4)) " *
                    "PID $(string(d.product_id, base = 16, pad = 4)))")
        end
        if isempty(devices)
            println("No dongle attached; nothing to do.")
            return 0
        end

        # No serial = first dongle found; pass one to pick a specific dongle.
        dongle = open_dongle(ctx)
        try
            report(dongle)
            # The do-block form closes the session on every exit path, including
            # when an exception unwinds through it.
            session(dongle) do s
                read_records(s)
                protect_something(s)
            end
        finally
            close(dongle)
        end
    catch e
        # The error type distinguishes the cases; showerror prints the SDK's own
        # diagnostic text, which is what tells "no dongle" from "certificate rejected".
        if e isa LicenseDongleError
            println(stderr, "KeyNub error: ", sprint(showerror, e))
            return 1
        end
        rethrow()
    finally
        close(ctx)
    end
    return 0
end

exit(main())
