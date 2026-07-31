using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using KeyNub.LicenseDongle.Interop;

namespace KeyNub.LicenseDongle
{
    /// <summary>
    /// The library context: the entry point for enumerating and opening dongles. Thread-safe.
    /// Create one with <see cref="Create"/> and dispose it when done (after the dongles it opened).
    /// </summary>
    public sealed class LicenseDongleContext : IDisposable
    {
        private readonly LicdContextHandle _handle;

        // Kept alive for the context lifetime so the native side can call it.
        private LicdLogCallback? _logThunk;

        private LicenseDongleContext(LicdContextHandle handle)
        {
            _handle = handle;
        }

        internal LicdContextHandle Handle => _handle;

        /// <summary>The native core library version (semantic).</summary>
        public static Version LibraryVersion
        {
            get
            {
                NativeMethods.licd_version(out int major, out int minor, out int patch);
                return new Version(major, minor, patch);
            }
        }

        /// <summary>Creates a new library context.</summary>
        /// <exception cref="LicenseDongleException">If the core failed to initialize.</exception>
        public static LicenseDongleContext Create()
        {
            int rc = NativeMethods.licd_init(out LicdContextHandle handle);
            Errors.Check(rc, handle.IsInvalid ? null : handle, "licd_init");
            return new LicenseDongleContext(handle);
        }

        /// <summary>
        /// Sets (or with <c>null</c>, clears) a diagnostic log callback. Invoked by the core on the
        /// calling thread during other operations; keep it fast and non-throwing.
        /// </summary>
        public void SetLogCallback(Action<LogLevel, string>? callback)
        {
            if (callback == null)
            {
                _logThunk = null;
                NativeMethods.licd_set_log_callback(_handle, null, IntPtr.Zero);
                return;
            }

            // Wrap once and retain, so the delegate outlives the native registration.
            _logThunk = (level, msgPtr, _) => callback(level, Utf8.FromPtr(msgPtr));
            NativeMethods.licd_set_log_callback(_handle, _logThunk, IntPtr.Zero);
        }

        /// <summary>
        /// Overrides the CA root that <see cref="Dongle.VerifyGenuine"/> checks the device
        /// certificate chain against, given a DER-encoded X.509 CA certificate.
        /// </summary>
        /// <remarks>
        /// Applications do not need this: a release build embeds the KeyNub production root.
        /// It exists for dongles provisioned against a <em>development</em> CA
        /// samples) and for vendor tooling and hardware tests. This is not a security
        /// boundary — see <c>docs/integration-security.md</c>.
        /// </remarks>
        public void SetTrustRoot(byte[] der)
        {
            if (der == null)
            {
                throw new ArgumentNullException(nameof(der));
            }
            int rc = NativeMethods.licd_set_trust_root(_handle, der, (UIntPtr)der.Length);
            Errors.Check(rc, _handle, "licd_set_trust_root");
        }

        /// <summary>Enumerates the connected dongles. Returns an empty list when none are present.</summary>
        public IReadOnlyList<DeviceInfo> Enumerate()
        {
            int rc = NativeMethods.licd_enumerate(_handle, out IntPtr list, out UIntPtr countN);
            Errors.Check(rc, _handle, "licd_enumerate");

            int count = checked((int)countN.ToUInt64());
            var result = new DeviceInfo[count];
            if (count > 0)
            {
                int stride = Marshal.SizeOf<LicdDeviceInfoNative>();
                try
                {
                    for (int i = 0; i < count; i++)
                    {
                        var raw = Marshal.PtrToStructure<LicdDeviceInfoNative>(list + i * stride);
                        result[i] = new DeviceInfo(raw.serial ?? string.Empty, raw.path ?? string.Empty,
                            raw.vendor_id, raw.product_id);
                    }
                }
                finally
                {
                    NativeMethods.licd_free_device_list(list, countN);
                }
            }
            return result;
        }

        /// <summary>Opens the dongle with the given serial, or the first one if <paramref name="serial"/> is null.</summary>
        /// <exception cref="DeviceNotFoundException">If no matching dongle is present.</exception>
        public Dongle Open(string? serial = null)
        {
            int rc = NativeMethods.licd_open(_handle, Utf8.ToNullTerminated(serial), out LicdDeviceHandle dev);
            Errors.Check(rc, _handle, "licd_open");
            return new Dongle(this, dev);
        }

        /// <summary>Opens a specific dongle by the <see cref="DeviceInfo.Path"/> from <see cref="Enumerate"/>.</summary>
        public Dongle OpenByPath(string path)
        {
            if (path == null)
            {
                throw new ArgumentNullException(nameof(path));
            }
            byte[] pathUtf8 = Utf8.ToNullTerminated(path)!;
            int rc = NativeMethods.licd_open_path(_handle, pathUtf8, out LicdDeviceHandle dev);
            Errors.Check(rc, _handle, "licd_open_path");
            return new Dongle(this, dev);
        }

        /// <summary>The thread-local diagnostic detail for the most recent failure on this thread, or empty.</summary>
        public string LastErrorDetail =>
            _handle.IsInvalid ? string.Empty : Utf8.FromPtr(NativeMethods.licd_error_detail(_handle));

        /// <summary>Releases the context.</summary>
        public void Dispose()
        {
            _logThunk = null;
            _handle.Dispose();
        }
    }
}
