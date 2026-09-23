using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace KeyNub.LicenseDongle.StandInTests
{
    /// <summary>
    /// Every call of the binding against the C ABI stand-in (see <see cref="StandIn"/>). The
    /// stand-in keeps records, counters and the write key per opened device, so each test starts
    /// from a fresh dongle.
    /// </summary>
    public sealed class StandInTests
    {
        private const string Serial = "04A1B2C3D4E5F6";
        private static readonly byte[] FactoryKey = { 0x30, 0x10, 0x01, 0x02, 0x03 };
        private static readonly byte[] ReplacementKey = { 0x30, 0x11, 0x09, 0x08, 0x07, 0x06 };

        public StandInTests()
        {
            // Compile the stand-in here, so a missing compiler fails the test with its reason.
            Assert.True(System.IO.File.Exists(StandIn.Library));
        }

        private static byte[] Bytes(string text) => System.Text.Encoding.UTF8.GetBytes(text);

        private static T Fails<T>(LicdStatus status, Action action) where T : LicenseDongleException
        {
            T e = Assert.Throws<T>(action);
            Assert.Equal(status, e.Status);
            return e;
        }

        private sealed class Ticks : IProgress<TransferProgress>
        {
            private readonly Action<TransferProgress> _onReport;
            public Ticks(Action<TransferProgress> onReport) => _onReport = onReport;
            public void Report(TransferProgress value) => _onReport(value);
        }

        [Fact]
        public void VersionDevicesAndOpen()
        {
            Assert.Equal(new Version(9, 8, 7), LicenseDongleContext.LibraryVersion);

            using var ctx = LicenseDongleContext.Create();
            ctx.SetLogCallback((level, message) => { });
            ctx.SetLogCallback(null);

            DeviceInfo device = Assert.Single(ctx.Enumerate());
            Assert.Equal(Serial, device.Serial);
            Assert.Equal("stub:0", device.Path);
            Assert.Equal(0x1234, device.VendorId);
            Assert.Equal(0xABCD, device.ProductId);

            DeviceNotFoundException e = Fails<DeviceNotFoundException>(LicdStatus.NoDevice, () => ctx.Open("nope"));
            Assert.Contains("no device", e.Message); // the SDK's status text
            Assert.Equal("no dongle with that serial", e.Detail);
            Assert.Equal("no dongle with that serial", ctx.LastErrorDetail);
            Fails<DeviceNotFoundException>(LicdStatus.NoDevice, () => ctx.OpenByPath("stub:9"));
            Assert.Throws<ArgumentNullException>(() => ctx.OpenByPath(null!));

            using (Dongle first = ctx.Open())
            {
                Assert.Equal(Serial, first.GetSerial());
            }
            using (Dongle bySerial = ctx.Open(Serial))
            {
                Assert.Equal(Serial, bySerial.GetSerial());
            }
            using (Dongle byPath = ctx.OpenByPath("stub:0"))
            {
                Assert.Equal(Serial, byPath.GetSerial());
            }
        }

        [Fact]
        public void InfoAndGenuine()
        {
            using var ctx = LicenseDongleContext.Create();
            using Dongle d = ctx.Open();
            DongleInfo i = d.GetInfo();
            Assert.Equal(new Version(1, 0), i.ProtocolVersion);
            Assert.Equal(new Version(2, 3, 4), i.FirmwareVersion);
            Assert.True(i.SeReady && i.Provisioned && i.Isolated);
            Assert.False(i.WatchdogReboot || i.WriteAuthRotated);
            Assert.Equal(1024u * 1024u, i.DataCapacity);
            Assert.Equal(1_000_000u, i.DataFree);

            GenuineResult g = d.VerifyGenuine();
            Assert.True(g.IsGenuine);
            Assert.Equal(Serial, g.Serial);
            Assert.Equal("2026-08-15", g.ProvisionedDate);
        }

        [Fact]
        public void TrustRoot()
        {
            using var ctx = LicenseDongleContext.Create();
            using Dongle d = ctx.Open();

            Fails<CertificateInvalidException>(LicdStatus.CertificateInvalid, () => ctx.SetTrustRoot(new byte[] { 0x02, 0x01, 0x00 }));
            Fails<LicenseDongleException>(LicdStatus.InvalidArgument, () => ctx.SetTrustRoot(Array.Empty<byte>()));
            Assert.Throws<ArgumentNullException>(() => ctx.SetTrustRoot(null!));

            byte[] root = new byte[132];
            root[0] = 0x30; root[1] = 0x82; root[2] = 0x01; root[3] = 0x00;
            for (int k = 4; k < root.Length; k++)
            {
                root[k] = 0xAB;
            }
            ctx.SetTrustRoot(root);
            Fails<CertificateInvalidException>(LicdStatus.CertificateInvalid, () => d.VerifyGenuine());

            for (int k = 4; k < root.Length; k++)
            {
                root[k] = 0x01;
            }
            ctx.SetTrustRoot(root);
            Assert.True(d.VerifyGenuine().IsGenuine);
        }

        [Fact]
        public void RecordsAndWriteRole()
        {
            using var ctx = LicenseDongleContext.Create();
            using Dongle d = ctx.Open();
            using Session s = d.OpenSession();

            byte[] payload = Bytes("license-blob-0123456789");
            Fails<WriteAuthorizationRequiredException>(LicdStatus.AuthRequired, () => s.WriteRecord("lic", payload));
            Fails<WriteAuthorizationRequiredException>(LicdStatus.AuthRequired, () => s.EraseRecord("lic"));
            Fails<WriteAuthorizationRequiredException>(LicdStatus.AuthRequired, () => s.EraseAllRecords());
            Fails<WriteAuthorizationRequiredException>(LicdStatus.AuthRequired, () => s.IncrementCounter(0));
            Fails<NotGenuineException>(LicdStatus.NotGenuine, () => s.AuthorizeWrite(new byte[] { 0x30, 0x00 }));
            Assert.Throws<ArgumentNullException>(() => s.AuthorizeWrite(null!));

            s.AuthorizeWrite(FactoryKey);
            s.WriteRecord("lic", payload);
            Assert.Equal(payload, s.ReadRecord("lic"));
            s.WriteRecord("cfg", Bytes("cfgdata"));
            var records = s.ListRecords();
            Assert.Equal(new[] { "cfg", "lic" }, records.Select(r => r.Name).OrderBy(n => n, StringComparer.Ordinal));
            Assert.Equal((uint)payload.Length, records.Single(r => r.Name == "lic").Size);
            Assert.Equal(Bytes("cfgdata"), s.ReadRecord("cfg"));
            Fails<RecordNotFoundException>(LicdStatus.NotFound, () => s.ReadRecord("nope"));
            Fails<RecordNotFoundException>(LicdStatus.NotFound, () => s.EraseRecord("nope"));

            // An empty name is refused by the binding, never passed on as "erase everything".
            Assert.Throws<ArgumentException>(() => s.EraseRecord(""));
            Assert.Throws<ArgumentException>(() => s.ReadRecord(""));
            Assert.Equal(2, s.ListRecords().Count);
            s.EraseRecord("cfg");
            Assert.Equal("lic", Assert.Single(s.ListRecords()).Name);

            s.WriteRecord("empty", Array.Empty<byte>());
            Assert.Empty(s.ReadRecord("empty"));

            // Bigger than one transfer chunk, with progress and cancellation.
            byte[] big = Enumerable.Range(0, 3000).Select(k => (byte)(k * 31 + 5)).ToArray();
            uint lastWrite = 0;
            s.WriteRecord("big", big, new Ticks(p => lastWrite = p.BytesTransferred));
            Assert.Equal((uint)big.Length, lastWrite);
            uint lastRead = 0;
            Assert.Equal(big, s.ReadRecord("big", new Ticks(p => lastRead = p.BytesTransferred)));
            Assert.Equal((uint)big.Length, lastRead);
            using (var cts = new CancellationTokenSource())
            {
                // Cancelled during the first chunk, so the stand-in stops at the second.
                Assert.ThrowsAny<OperationCanceledException>(
                    () => s.ReadRecord("big", new Ticks(_ => cts.Cancel()), cts.Token));
            }
            using (var cancelled = new CancellationTokenSource())
            {
                cancelled.Cancel();
                Assert.ThrowsAny<OperationCanceledException>(() => s.ReadRecord("big", null, cancelled.Token));
            }
            Assert.Equal(big, s.ReadRecord("big"));

            s.EraseAllRecords();
            Assert.Empty(s.ListRecords());
        }

        [Fact]
        public void Counters()
        {
            using var ctx = LicenseDongleContext.Create();
            using Dongle d = ctx.Open();
            using Session s = d.OpenSession();
            s.AuthorizeWrite(FactoryKey);

            uint before = s.ReadCounter(0);
            Assert.Equal(before + 1, s.IncrementCounter(0));
            Assert.Equal(before + 1, s.ReadCounter(0));
            Assert.Equal(0u, s.ReadCounter(1));
            Fails<LicenseDongleException>(LicdStatus.Range, () => s.ReadCounter(7));
            Fails<LicenseDongleException>(LicdStatus.Range, () => s.IncrementCounter(7));
        }

        [Fact]
        public void AppEncryptAndDecrypt()
        {
            using var ctx = LicenseDongleContext.Create();
            using Dongle d = ctx.Open();
            using Session s = d.OpenSession();

            byte[] secret = Enumerable.Range(0, 100).Select(k => (byte)((3 * k + 7) % 256)).ToArray();
            foreach (Scope scope in new[] { Scope.Device, Scope.Developer })
            {
                byte[] blob = s.AppEncrypt(scope, secret);
                Assert.True(blob.Length > secret.Length);
                Assert.Equal((byte)scope, blob[0]);
                Assert.Equal(secret, s.AppDecrypt(blob));

                byte[] tampered = (byte[])blob.Clone();
                tampered[tampered.Length - 1] ^= 1;
                Fails<LicenseDongleException>(LicdStatus.TagMismatch, () => s.AppDecrypt(tampered));
            }
            Assert.Empty(s.AppDecrypt(s.AppEncrypt(Scope.Device, Array.Empty<byte>())));
            Assert.Throws<ArgumentNullException>(() => s.AppEncrypt(Scope.Device, null!));
            Assert.Throws<ArgumentNullException>(() => s.AppDecrypt(null!));
        }

        [Fact]
        public void WriteKeyRotation()
        {
            using var ctx = LicenseDongleContext.Create();
            using Dongle d = ctx.Open();

            using (Session s = d.OpenSession())
            {
                Fails<WriteAuthorizationRequiredException>(LicdStatus.AuthRequired, () => s.RotateWriteKey(ReplacementKey));
                s.AuthorizeWrite(FactoryKey);
                s.RotateWriteKey(ReplacementKey);
                s.WriteRecord("lic", Bytes("still-writable")); // the session keeps its role
            }
            Assert.True(d.GetInfo().WriteAuthRotated);

            using (Session s = d.OpenSession())
            {
                Fails<NotGenuineException>(LicdStatus.NotGenuine, () => s.AuthorizeWrite(FactoryKey));
                s.AuthorizeWrite(ReplacementKey);
                s.WriteRecord("lic", Bytes("new-key-writes"));
                Assert.Equal(Bytes("new-key-writes"), s.ReadRecord("lic"));
            }
        }

        [Fact]
        public void SessionAndCloseSemantics()
        {
            using var ctx = LicenseDongleContext.Create();
            Dongle d = ctx.Open();

            Session s = d.OpenSession();
            Assert.Throws<InvalidOperationException>(() => d.OpenSession());
            Assert.False(s.IsClosed);
            s.Close();
            s.Close(); // idempotent
            Assert.True(s.IsClosed);
            Assert.Throws<ObjectDisposedException>(() => s.ReadCounter(0));

            Session orphan = d.OpenSession();
            d.Dispose();
            Assert.True(orphan.IsClosed); // a session ends with its dongle
            Assert.Throws<ObjectDisposedException>(() => orphan.ListRecords());
            Assert.Throws<ObjectDisposedException>(() => d.GetSerial());
            d.Dispose(); // idempotent
        }

        [Fact]
        public async Task AsyncVariants()
        {
            using var ctx = LicenseDongleContext.Create();
            using Dongle d = ctx.Open();
            Assert.Equal(Serial, await d.GetSerialAsync());
            Assert.Equal(new Version(2, 3, 4), (await d.GetInfoAsync()).FirmwareVersion);
            Assert.True((await d.VerifyGenuineAsync()).IsGenuine);

            using Session s = await d.OpenSessionAsync();
            await s.AuthorizeWriteAsync(FactoryKey);
            await s.WriteRecordAsync("lic", Bytes("async"));
            Assert.Equal(Bytes("async"), await s.ReadRecordAsync("lic"));
            Assert.Equal("lic", Assert.Single(await s.ListRecordsAsync()).Name);
            uint after = await s.IncrementCounterAsync(1);
            Assert.Equal(after, await s.ReadCounterAsync(1));
            byte[] blob = await s.AppEncryptAsync(Scope.Developer, Bytes("data"));
            Assert.Equal(Bytes("data"), await s.AppDecryptAsync(blob));
            await s.EraseRecordAsync("lic");
            await s.WriteRecordAsync("cfg", Bytes("x"));
            await s.EraseAllRecordsAsync();
            Assert.Empty(await s.ListRecordsAsync());
        }
    }
}
