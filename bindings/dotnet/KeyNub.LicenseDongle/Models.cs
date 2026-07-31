using System;

namespace KeyNub.LicenseDongle
{
    /// <summary>A dongle discovered by <see cref="LicenseDongleContext.Enumerate"/>.</summary>
    public readonly struct DeviceInfo
    {
        /// <summary>The device serial as hex (e.g. <c>0123456789ABCDEFEE</c>), or empty if unavailable.</summary>
        public string Serial { get; }

        /// <summary>An opaque, platform-specific path accepted by <see cref="LicenseDongleContext.OpenByPath"/>.</summary>
        public string Path { get; }

        /// <summary>The USB vendor id.</summary>
        public ushort VendorId { get; }

        /// <summary>The USB product id.</summary>
        public ushort ProductId { get; }

        /// <summary>Creates a new <see cref="DeviceInfo"/>.</summary>
        public DeviceInfo(string serial, string path, ushort vendorId, ushort productId)
        {
            Serial = serial;
            Path = path;
            VendorId = vendorId;
            ProductId = productId;
        }
    }

    /// <summary>Plaintext device info from <see cref="Dongle.GetInfo"/> (no session required).</summary>
    public readonly struct DongleInfo
    {
        /// <summary>The wire-protocol version (major.minor).</summary>
        public Version ProtocolVersion { get; }

        /// <summary>The firmware version (major.minor.patch).</summary>
        public Version FirmwareVersion { get; }

        /// <summary>Whether the secure element responded.</summary>
        public bool SeReady { get; }

        /// <summary>Whether factory provisioning is complete.</summary>
        public bool Provisioned { get; }

        /// <summary>Total user-data capacity, in bytes.</summary>
        public uint DataCapacity { get; }

        /// <summary>Free user-data space, in bytes.</summary>
        public uint DataFree { get; }

        /// <summary>
        /// Whether the dongle's <em>previous</em> boot ended in a watchdog timeout — the
        /// firmware hung and reset itself.
        /// </summary>
        /// <remarks>
        /// Normal operation and a requested reboot both leave this false, so a true value
        /// is worth logging: it is the only trace a field hang leaves behind. Cleared by a
        /// power cycle.
        /// </remarks>
        public bool WatchdogReboot { get; }

        /// <summary>Whether the dongle confirmed at boot that its USB and parsing code is fenced off
        /// from keys and storage. The software simulator reports false.</summary>
        public bool Isolated { get; }

        /// <summary>Creates a new <see cref="DongleInfo"/>.</summary>
        public DongleInfo(Version protocolVersion, Version firmwareVersion, bool seReady,
            bool provisioned, uint dataCapacity, uint dataFree, bool watchdogReboot = false,
            bool isolated = false)
        {
            ProtocolVersion = protocolVersion;
            FirmwareVersion = firmwareVersion;
            SeReady = seReady;
            Provisioned = provisioned;
            DataCapacity = dataCapacity;
            DataFree = dataFree;
            WatchdogReboot = watchdogReboot;
            Isolated = isolated;
        }
    }

    /// <summary>The verified identity from <see cref="Dongle.VerifyGenuine"/>.</summary>
    public readonly struct GenuineResult
    {
        /// <summary>Whether authenticity was proven.</summary>
        public bool IsGenuine { get; }

        /// <summary>The device serial from the certificate.</summary>
        public string Serial { get; }

        /// <summary>The batch/issuer label, or empty.</summary>
        public string Batch { get; }

        /// <summary>The provisioning date as <c>YYYY-MM-DD</c>, or empty.</summary>
        public string ProvisionedDate { get; }

        /// <summary>Creates a new <see cref="GenuineResult"/>.</summary>
        public GenuineResult(bool isGenuine, string serial, string batch, string provisionedDate)
        {
            IsGenuine = isGenuine;
            Serial = serial;
            Batch = batch;
            ProvisionedDate = provisionedDate;
        }
    }

    /// <summary>
    /// Progress of a record transfer, reported to an <see cref="System.IProgress{T}"/> during
    /// <see cref="Session.ReadRecord"/> / <see cref="Session.WriteRecord"/> and their async forms.
    /// </summary>
    public readonly struct TransferProgress
    {
        /// <summary>Bytes transferred so far.</summary>
        public uint BytesTransferred { get; }

        /// <summary>Total bytes to transfer.</summary>
        public uint TotalBytes { get; }

        /// <summary>Creates a new <see cref="TransferProgress"/>.</summary>
        public TransferProgress(uint bytesTransferred, uint totalBytes)
        {
            BytesTransferred = bytesTransferred;
            TotalBytes = totalBytes;
        }

        /// <summary>Fraction complete in <c>[0, 1]</c> (1 when <see cref="TotalBytes"/> is zero).</summary>
        public double Fraction => TotalBytes == 0 ? 1.0 : (double)BytesTransferred / TotalBytes;
    }

    /// <summary>A record name and its size, from <see cref="Session.ListRecords"/>.</summary>
    public readonly struct RecordInfo
    {
        /// <summary>The record name.</summary>
        public string Name { get; }

        /// <summary>The record size, in bytes.</summary>
        public uint Size { get; }

        /// <summary>Creates a new <see cref="RecordInfo"/>.</summary>
        public RecordInfo(string name, uint size)
        {
            Name = name;
            Size = size;
        }
    }
}
