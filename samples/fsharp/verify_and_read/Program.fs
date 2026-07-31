// KeyNub dongle check from F#: enumerate -> open -> verify -> session ->
// read a record -> app-crypto round trip.
//
//   dotnet run --project samples/fsharp/verify_and_read
//
// There is no separate F# binding: KeyNub.LicenseDongle is a .NET assembly, so C#,
// VB.NET and F# all consume the same package. This sample exists because the F#
// idioms are different enough to be worth showing — `use` bindings instead of
// nested Using blocks, pattern matching on the exception type instead of a Catch
// ladder, and structural equality on arrays, which removes the byte-comparison
// loop the C# and VB samples have to write out.
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// READ FIRST: docs/integration-security.md. This sample prints whether the
// dongle is genuine, which is the one thing a real licence check must not do — a
// printed Boolean is a deleted line away from nothing. The last section shows the
// shape that actually protects something.

module KeyNub.Samples.VerifyAndRead

open System
open System.Text
open KeyNub.LicenseDongle

let private report (dongle: Dongle) =
    let info = dongle.GetInfo()
    // %O not %s: ProtocolVersion and FirmwareVersion are System.Version, and F#'s
    // printf is type-checked, so %s would not compile here.
    printfn "Protocol v%O, firmware v%O, %d of %d bytes free."
        info.ProtocolVersion info.FirmwareVersion info.DataFree info.DataCapacity

    if info.WatchdogReboot then
        // The only trace a firmware hang leaves behind. Worth reporting to support.
        printfn "WARNING: this dongle's previous boot ended in a watchdog reset."

    let result = dongle.VerifyGenuine()
    printfn "Genuine: %b (serial %s, batch %s, provisioned %O)"
        result.IsGenuine result.Serial result.Batch result.ProvisionedDate

let private readRecords (session: Session) =
    let records = session.ListRecords()
    printfn "%d record(s) on the dongle:" records.Count
    for record in records do
        printfn "  %-16s %6d bytes" record.Name record.Size

    // tryFind rather than a loop with a break: if the record is absent that is a
    // normal state, not an error, and Option makes that explicit at the call site.
    records
    |> Seq.tryFind (fun r -> r.Name = "license")
    |> Option.iter (fun _ ->
        let data = session.ReadRecord("license")
        printfn "Read %d bytes from the license record." data.Length)

/// The part that actually protects something. At licence-issue time you would call
/// AppEncrypt once, with a developer dongle, and ship only the blob; the application
/// then cannot proceed without a dongle, because it holds no other copy of the data.
/// Scope.Developer lets any dongle from your batch decrypt it, so one file serves
/// every customer; Scope.Device locks it to one dongle.
let private protectSomething (session: Session) =
    let needed = Encoding.UTF8.GetBytes("the data this program cannot run without")

    let sealedBlob = session.AppEncrypt(Scope.Developer, needed)
    let recovered = session.AppDecrypt(sealedBlob)

    // F# arrays compare structurally, so this is the whole check — the C# and VB
    // samples need an explicit element loop for the same assertion.
    let outcome = if recovered = needed then "recovered intact" else "MISMATCH"
    printfn "App-crypto round trip: %d bytes -> %d sealed -> %s"
        needed.Length sealedBlob.Length outcome

[<EntryPoint>]
let main _ =
    printfn "KeyNub SDK %O" LicenseDongleContext.LibraryVersion

    try
        use ctx = LicenseDongleContext.Create()

        let devices = ctx.Enumerate()
        printfn "Found %d KeyNub dongle(s)." devices.Count
        devices |> Seq.iteri (fun i d ->
            printfn "  [%d] serial %s (VID %04X PID %04X)" i d.Serial d.VendorId d.ProductId)

        if devices.Count = 0 then
            printfn "No dongle attached; nothing to do."
            0
        else
            // First dongle; pass a serial to Open() to pick a specific one.
            use dongle = ctx.Open()
            report dongle

            use session = dongle.OpenSession()
            readRecords session
            protectSomething session
            0

    with
    | :? DeviceNotFoundException ->
        printfn "The dongle was disconnected while we were talking to it."
        0
    | :? LicenseDongleException as ex ->
        // Status distinguishes the cases; Detail carries the SDK's diagnostic text,
        // which is what tells "no dongle" from "certificate rejected".
        eprintfn "KeyNub error (%O): %s" ex.Status ex.Message
        if not (String.IsNullOrEmpty ex.Detail) then
            eprintfn "  detail: %s" ex.Detail
        1
