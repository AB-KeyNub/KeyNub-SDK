using KeyNub.LicenseDongle;

// KeyNub SDK - C# sample: take ownership of a new dongle.
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
//   dotnet run --project samples/csharp/rotate_write_key -- keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware; prints guidance and exits 0 when no dongle is attached.
//
// The replacement key is worth what your licence-signing key is worth. It cannot be
// recovered from the dongle, and a unit rotated to a key you have lost has to come
// back to be re-provisioned.

if (args.Length != 2)
{
    Console.Error.WriteLine("usage: rotate_write_key <current-key.der> <new-key.der>");
    return 2;
}

byte[] current = File.ReadAllBytes(args[0]);
byte[] replacement = File.ReadAllBytes(args[1]);

try
{
    using var ctx = LicenseDongleContext.Create();

    if (ctx.Enumerate().Count == 0)
    {
        Console.WriteLine("Connect a KeyNub dongle and re-run.");
        return 0;
    }

    using Dongle dongle = ctx.Open(); // first attached dongle
    Console.WriteLine($"dongle {dongle.GetSerial()}");

    using (Session session = dongle.OpenSession())
    {
        session.AuthorizeWrite(current);
        session.RotateWriteKey(replacement);
        Console.WriteLine("rotated: this dongle now answers only to your key");
    }

    // A fresh session is the only place the change is observable: the session
    // above keeps the role it was already granted.
    using (Session session = dongle.OpenSession())
    {
        try
        {
            session.AuthorizeWrite(current);
            Console.Error.WriteLine("WARNING: the old key still works -- do not ship this unit");
            return 1;
        }
        catch (LicenseDongleException)
        {
            Console.WriteLine("confirmed: the old key no longer elevates");
        }
        session.AuthorizeWrite(replacement);
        Console.WriteLine("confirmed: your key elevates");
    }
}
catch (LicenseDongleException err)
{
    Console.Error.WriteLine($"KeyNub error: {err.Message}");
    return 1;
}

Console.WriteLine();
Console.WriteLine("Keep the replacement key safe. Every future write to this dongle needs it.");
return 0;
