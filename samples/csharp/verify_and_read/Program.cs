using System.Text;
using KeyNub.LicenseDongle;

// KeyNub SDK - C# sample: enumerate a dongle, verify authenticity, open an encrypted
// session, read a "license" record, and round-trip app-data encryption. Targets real
// hardware; prints guidance and exits 0 when no dongle is attached.

Console.WriteLine($"KeyNub SDK {LicenseDongleContext.LibraryVersion}");

using var ctx = LicenseDongleContext.Create();

var devices = ctx.Enumerate();
Console.WriteLine($"Dongles found: {devices.Count}");
if (devices.Count == 0)
{
    Console.WriteLine("Connect a KeyNub dongle and re-run.");
    return 0;
}

using Dongle dongle = ctx.Open(); // first attached dongle

DongleInfo info = dongle.GetInfo();
Console.WriteLine($"protocol {info.ProtocolVersion}, firmware {info.FirmwareVersion}, capacity {info.DataCapacity} bytes");
Console.WriteLine($"serial {dongle.GetSerial()}");

// Authenticity: cert chain to the trusted root + a live challenge-response.
GenuineResult id = dongle.VerifyGenuine();
Console.WriteLine($"genuine: {id.IsGenuine}, cert serial {id.Serial}");
if (!id.IsGenuine)
{
    return 2;
}

// Encrypted session for the data + app-crypto operations.
using Session session = dongle.OpenSession();

try
{
    byte[] license = session.ReadRecord("license");
    Console.WriteLine($"license record: {license.Length} bytes");
}
catch (RecordNotFoundException)
{
    Console.WriteLine("no 'license' record on this dongle");
}

// App-data envelope encryption: the blob only decrypts with this dongle attached.
byte[] secret = Encoding.UTF8.GetBytes("hello-keynub");
byte[] packed = session.AppEncrypt(Scope.Device, secret);
byte[] plain = session.AppDecrypt(packed);
bool ok = plain.AsSpan().SequenceEqual(secret);
Console.WriteLine($"app-crypto round-trip {(ok ? "OK" : "FAILED")} ({secret.Length} plaintext -> {packed.Length} packed bytes)");

return ok ? 0 : 4;
