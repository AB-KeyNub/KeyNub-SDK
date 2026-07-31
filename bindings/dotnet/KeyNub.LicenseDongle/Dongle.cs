using System;
using System.Threading;
using System.Threading.Tasks;
using KeyNub.LicenseDongle.Interop;

namespace KeyNub.LicenseDongle
{
    /// <summary>
    /// An open connection to a dongle. Plaintext operations (<see cref="GetInfo"/>,
    /// <see cref="GetSerial"/>, <see cref="VerifyGenuine"/>) are available immediately; the
    /// encrypted operations live on the <see cref="Session"/> returned by <see cref="OpenSession"/>.
    /// Not thread-safe: use one dongle from one thread at a time.
    /// </summary>
    public sealed class Dongle : IDisposable
    {
        private readonly LicenseDongleContext _context;
        private readonly LicdDeviceHandle _handle;
        private Session? _session;

        internal Dongle(LicenseDongleContext context, LicdDeviceHandle handle)
        {
            _context = context;
            _handle = handle;
        }

        internal LicdDeviceHandle Handle => _handle;
        internal LicdContextHandle ContextHandle => _context.Handle;

        /// <summary>Reads the plaintext device info (protocol/firmware version, flags, capacity).</summary>
        public DongleInfo GetInfo()
        {
            int rc = NativeMethods.licd_get_info(_handle, out LicdInfoNative info);
            Errors.Check(rc, ContextHandle, "licd_get_info");
            return new DongleInfo(
                new Version(info.proto_version_major, info.proto_version_minor),
                new Version(info.fw_version_major, info.fw_version_minor, info.fw_version_patch),
                info.se_ready != 0,
                info.provisioned != 0,
                info.data_capacity,
                info.data_free,
                info.watchdog_reboot != 0,
                info.isolated != 0);
        }

        /// <summary>Reads the dongle serial as hex (e.g. <c>0123456789ABCDEFEE</c>).</summary>
        public string GetSerial()
        {
            var buf = new byte[19]; // LICD_SERIAL_HEX_LEN + 1
            int rc = NativeMethods.licd_get_serial(_handle, buf, new UIntPtr((uint)buf.Length));
            Errors.Check(rc, ContextHandle, "licd_get_serial");
            return Utf8.FromFixedBuffer(buf);
        }

        /// <summary>
        /// Verifies authenticity: validates the device certificate chain to the trusted root and a
        /// live ECDSA challenge-response. Returns the identity read from the verified certificate.
        /// </summary>
        /// <exception cref="CertificateInvalidException">If the certificate/chain is invalid.</exception>
        /// <exception cref="NotGenuineException">If the challenge-response check fails.</exception>
        public GenuineResult VerifyGenuine()
        {
            int rc = NativeMethods.licd_verify_genuine(_handle, out LicdGenuineResultNative res);
            Errors.Check(rc, ContextHandle, "licd_verify_genuine");
            return new GenuineResult(res.genuine != 0, res.serial ?? string.Empty,
                res.batch ?? string.Empty, res.provisioned_date ?? string.Empty);
        }

        /// <summary>
        /// Opens an encrypted session (verifies authenticity, then performs the P-256 ECDH /
        /// HKDF / AES-256-GCM handshake). The returned <see cref="Session"/> carries the
        /// data, counter, and app-crypto operations; dispose it to end the session.
        /// </summary>
        /// <exception cref="InvalidOperationException">If a session is already open on this dongle.</exception>
        public Session OpenSession()
        {
            if (_session != null && !_session.IsClosed)
            {
                throw new InvalidOperationException("A session is already open on this dongle.");
            }
            int rc = NativeMethods.licd_session_open(_handle);
            Errors.Check(rc, ContextHandle, "licd_session_open");
            _session = new Session(this);
            return _session;
        }

        // --- Async variants -------------------------------------------------------------------
        // Run the blocking native calls on the thread pool. Do not run concurrent operations on the
        // same dongle.

        /// <summary>Asynchronously reads the device info. See <see cref="GetInfo"/>.</summary>
        public Task<DongleInfo> GetInfoAsync(CancellationToken cancellationToken = default)
            => Task.Run(GetInfo, cancellationToken);

        /// <summary>Asynchronously reads the serial. See <see cref="GetSerial"/>.</summary>
        public Task<string> GetSerialAsync(CancellationToken cancellationToken = default)
            => Task.Run(GetSerial, cancellationToken);

        /// <summary>Asynchronously verifies authenticity. See <see cref="VerifyGenuine"/>.</summary>
        public Task<GenuineResult> VerifyGenuineAsync(CancellationToken cancellationToken = default)
            => Task.Run(VerifyGenuine, cancellationToken);

        /// <summary>Asynchronously opens an encrypted session. See <see cref="OpenSession"/>.</summary>
        public Task<Session> OpenSessionAsync(CancellationToken cancellationToken = default)
            => Task.Run(OpenSession, cancellationToken);

        internal void OnSessionClosed(Session session)
        {
            if (ReferenceEquals(_session, session))
            {
                _session = null;
            }
        }

        /// <summary>Closes the session (if any) and the dongle connection.</summary>
        public void Dispose()
        {
            _session?.Dispose();
            _session = null;
            _handle.Dispose();
        }
    }
}
