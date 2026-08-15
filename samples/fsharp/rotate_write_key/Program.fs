// KeyNub SDK - F# sample: take ownership of a new dongle.
//
// A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
// that from the next session onward only your key can write records, erase them or
// increment counters. Run it once per dongle, when it arrives.
//
// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//
//   openssl ecparam -name prime256v1 -genkey -noout |
//     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//
//   dotnet run --project samples/fsharp/rotate_write_key -- keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It cannot be
// recovered from the dongle, and a unit rotated to a key you have lost has to come
// back to be re-provisioned.

module KeyNub.Samples.RotateWriteKey

open System
open System.IO
open KeyNub.LicenseDongle

let private rotate (current: byte[]) (replacement: byte[]) =
    use ctx = LicenseDongleContext.Create()

    if ctx.Enumerate().Count = 0 then
        printfn "Connect a KeyNub dongle and re-run."
        0
    else
        use dongle = ctx.Open()
        printfn "dongle %s" (dongle.GetSerial())

        (use session = dongle.OpenSession()
         session.AuthorizeWrite(current)
         session.RotateWriteKey(replacement)
         printfn "rotated: this dongle now answers only to your key")

        // A fresh session is the only place the change is observable: the session
        // above keeps the role it was already granted.
        use session = dongle.OpenSession()
        let oldKeyStillWorks =
            try
                session.AuthorizeWrite(current)
                true
            with :? LicenseDongleException ->
                printfn "confirmed: the old key no longer elevates"
                false

        if oldKeyStillWorks then
            eprintfn "WARNING: the old key still works -- do not ship this unit"
            1
        else
            session.AuthorizeWrite(replacement)
            printfn "confirmed: your key elevates"
            printfn ""
            printfn "Keep the replacement key safe. Every future write to this dongle needs it."
            0

[<EntryPoint>]
let main argv =
    if argv.Length <> 2 then
        eprintfn "usage: rotate_write_key <current-key.der> <new-key.der>"
        2
    else
        try
            rotate (File.ReadAllBytes argv.[0]) (File.ReadAllBytes argv.[1])
        with :? LicenseDongleException as err ->
            eprintfn "KeyNub error: %s" err.Message
            1
