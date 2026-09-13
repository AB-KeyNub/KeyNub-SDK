# KeyNub SDK - Julia sample: take ownership of a new dongle.
#
# A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
# that from the next session onward only your key can write records, erase them or
# increment counters. Run it once per dongle, when it arrives.
#
# Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
#
#   openssl ecparam -name prime256v1 -genkey -noout |
#     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
#
#   KEYNUB_LICDONGLE_LIBRARY=../../build/libkeynub_licdongle.so \
#     julia --project=../../bindings/julia rotate_write_key.jl ../../keys/keynub-shipping-writeauth.key.der my-key.der
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# The replacement key is worth what your licence-signing key is worth. It cannot be
# recovered from the dongle, and a unit rotated to a key you have lost has to come
# back to be re-provisioned.

if Base.find_package("KeyNubLicenseDongle") === nothing
    # Running from a checkout, where the package is not installed.
    push!(LOAD_PATH, joinpath(@__DIR__, "..", "..", "bindings", "julia"))
end
using KeyNubLicenseDongle

function main(args)
    if length(args) != 2
        println(stderr, "usage: julia rotate_write_key.jl <current-key.der> <new-key.der>")
        return 2
    end
    current = read(args[1])
    replacement = read(args[2])

    ctx = Context()
    try
        if isempty(enumerate_dongles(ctx))
            println("Connect a KeyNub dongle and re-run.")
            return 0
        end

        dongle = open_dongle(ctx)
        try
            println("dongle $(serial(dongle))")

            session(dongle) do s
                authorize_write(s, current)
                rotate_write_key(s, replacement)
                println("rotated: this dongle now answers only to your key")
            end

            # A fresh session is the only place the change is observable: the
            # session above keeps the role it was already granted.
            session(dongle) do s
                try
                    authorize_write(s, current)
                    println(stderr, "WARNING: the old key still works -- do not ship this unit")
                    return 1
                catch e
                    e isa LicenseDongleError || rethrow()
                    println("confirmed: the old key no longer elevates")
                end
                authorize_write(s, replacement)
                println("confirmed: your key elevates")
            end
        finally
            close(dongle)
        end
    catch e
        e isa LicenseDongleError || rethrow()
        println(stderr, "KeyNub error: $e")
        return 1
    finally
        close(ctx)
    end

    println()
    println("Keep the replacement key safe. Every future write to this dongle needs it.")
    return 0
end

exit(main(ARGS))
