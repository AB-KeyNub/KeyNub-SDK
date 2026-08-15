using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using KeyNub.LicenseDongle.Interop;

namespace KeyNub.LicenseDongle
{
    /// <summary>
    /// An open encrypted session on a <see cref="Dongle"/>. Carries the operations that require a
    /// session: record and counter access, app-data envelope encryption, and write-role elevation.
    /// Obtain one from <see cref="Dongle.OpenSession"/>; dispose it to end the session.
    /// </summary>
    public sealed class Session : IDisposable
    {
        private readonly Dongle _dongle;
        private bool _closed;

        internal Session(Dongle dongle)
        {
            _dongle = dongle;
        }

        /// <summary>Whether this session has been closed.</summary>
        public bool IsClosed => _closed;

        private LicdContextHandle Ctx => _dongle.ContextHandle;

        private void EnsureOpen()
        {
            if (_closed)
            {
                throw new ObjectDisposedException(nameof(Session), "The session has been closed.");
            }
        }

        private static byte[] RequireName(string name)
        {
            if (string.IsNullOrEmpty(name))
            {
                throw new ArgumentException("Record name must be non-empty.", nameof(name));
            }
            return Utf8.ToNullTerminated(name)!;
        }

        /// <summary>
        /// Elevates the session to the write role by proving possession of the developer master key
        /// (a DER-encoded EC private key). Required before <see cref="WriteRecord"/>,
        /// <see cref="EraseRecord"/>, <see cref="EraseAllRecords"/>, and <see cref="IncrementCounter"/>.
        /// This belongs in your licence-issuing tooling; never ship that key in the application
        /// your users run.
        /// </summary>
        public void AuthorizeWrite(byte[] masterKeyDer)
        {
            EnsureOpen();
            if (masterKeyDer == null)
            {
                throw new ArgumentNullException(nameof(masterKeyDer));
            }
            int rc = NativeMethods.licd_write_auth(_dongle.Handle, masterKeyDer, new UIntPtr((uint)masterKeyDer.Length));
            Errors.Check(rc, Ctx, "licd_write_auth");
        }

        /// <summary>
        /// Replaces the dongle's write-auth key with your own (a DER EC private key).
        /// Call <see cref="AuthorizeWrite"/> with the current key first. From the next
        /// session on, only the new key elevates.
        /// </summary>
        public void RotateWriteKey(byte[] newKeyDer)
        {
            EnsureOpen();
            if (newKeyDer == null)
            {
                throw new ArgumentNullException(nameof(newKeyDer));
            }
            int rc = NativeMethods.licd_write_auth_rotate(_dongle.Handle, newKeyDer, new UIntPtr((uint)newKeyDer.Length));
            Errors.Check(rc, Ctx, "licd_write_auth_rotate");
        }

        /// <summary>Lists the record names and sizes stored on the dongle.</summary>
        public IReadOnlyList<RecordInfo> ListRecords()
        {
            EnsureOpen();
            int rc = NativeMethods.licd_record_list(_dongle.Handle, out IntPtr names, out IntPtr sizes, out UIntPtr countN);
            Errors.Check(rc, Ctx, "licd_record_list");

            int count = checked((int)countN.ToUInt64());
            var result = new RecordInfo[count];
            try
            {
                for (int i = 0; i < count; i++)
                {
                    IntPtr namePtr = Marshal.ReadIntPtr(names, i * IntPtr.Size);
                    string name = Utf8.FromPtr(namePtr);
                    uint size = unchecked((uint)Marshal.ReadInt32(sizes, i * sizeof(int)));
                    result[i] = new RecordInfo(name, size);
                }
            }
            finally
            {
                NativeMethods.licd_free_record_list(names, sizes, countN);
            }
            return result;
        }

        /// <summary>
        /// Reads the entire named record, optionally reporting progress and honoring cancellation.
        /// Cancellation takes effect at the next chunk boundary.
        /// </summary>
        /// <exception cref="RecordNotFoundException">If no record with that name exists.</exception>
        /// <exception cref="OperationCanceledException">If cancelled via <paramref name="cancellationToken"/>.</exception>
        public byte[] ReadRecord(string name, IProgress<TransferProgress>? progress = null,
            CancellationToken cancellationToken = default)
        {
            EnsureOpen();
            byte[] nameUtf8 = RequireName(name);
            cancellationToken.ThrowIfCancellationRequested();

            // Learn the total size (no progress on the tiny probe), then read the whole record in one
            // ranged call so reported progress is monotonic from 0 to total.
            var probe = new byte[1];
            int rc = NativeMethods.licd_record_read(_dongle.Handle, nameUtf8, 0, probe, (uint)probe.Length,
                out uint _, out uint total, null, IntPtr.Zero);
            Errors.Check(rc, Ctx, "licd_record_read");
            if (total == 0)
            {
                progress?.Report(new TransferProgress(0, 0));
                return Array.Empty<byte>();
            }

            var full = new byte[total];
            LicdProgressCallback? bridge = MakeBridge(progress, cancellationToken);
            rc = NativeMethods.licd_record_read(_dongle.Handle, nameUtf8, 0, full, (uint)full.Length,
                out uint len, out uint _, bridge, IntPtr.Zero);
            GC.KeepAlive(bridge);
            ThrowIfCancelled(rc, cancellationToken);
            Errors.Check(rc, Ctx, "licd_record_read");
            return Trim(full, len);
        }

        /// <summary>
        /// Writes (atomically replaces) the named record. Requires the write role. The dongle writes a
        /// record in a single transaction, so <paramref name="progress"/> reports one completion tick
        /// and cancellation only applies before the call starts.
        /// </summary>
        /// <exception cref="WriteAuthorizationRequiredException">If the write role has not been granted.</exception>
        public void WriteRecord(string name, byte[] data, IProgress<TransferProgress>? progress = null,
            CancellationToken cancellationToken = default)
        {
            EnsureOpen();
            if (data == null)
            {
                throw new ArgumentNullException(nameof(data));
            }
            byte[] nameUtf8 = RequireName(name);
            cancellationToken.ThrowIfCancellationRequested();
            LicdProgressCallback? bridge = MakeBridge(progress, cancellationToken);
            int rc = NativeMethods.licd_record_write(_dongle.Handle, nameUtf8, data, (uint)data.Length,
                bridge, IntPtr.Zero);
            GC.KeepAlive(bridge);
            ThrowIfCancelled(rc, cancellationToken);
            Errors.Check(rc, Ctx, "licd_record_write");
        }

        /// <summary>Erases the named record. Requires the write role.</summary>
        public void EraseRecord(string name)
        {
            EnsureOpen();
            byte[] nameUtf8 = RequireName(name);
            int rc = NativeMethods.licd_record_erase(_dongle.Handle, nameUtf8);
            Errors.Check(rc, Ctx, "licd_record_erase");
        }

        /// <summary>Erases all records. Requires the write role.</summary>
        public void EraseAllRecords()
        {
            EnsureOpen();
            int rc = NativeMethods.licd_record_erase(_dongle.Handle, null);
            Errors.Check(rc, Ctx, "licd_record_erase");
        }

        /// <summary>Reads a hardware monotonic counter.</summary>
        public uint ReadCounter(byte counterId)
        {
            EnsureOpen();
            int rc = NativeMethods.licd_counter_read(_dongle.Handle, counterId, out uint value);
            Errors.Check(rc, Ctx, "licd_counter_read");
            return value;
        }

        /// <summary>Increments a hardware monotonic counter and returns the new value. Requires the write role.</summary>
        public uint IncrementCounter(byte counterId)
        {
            EnsureOpen();
            int rc = NativeMethods.licd_counter_increment(_dongle.Handle, counterId, out uint value);
            Errors.Check(rc, Ctx, "licd_counter_increment");
            return value;
        }

        /// <summary>
        /// Encrypts <paramref name="plaintext"/> so it can only be decrypted with a dongle of the given
        /// <paramref name="scope"/>. The bulk crypto runs locally; only a small key is wrapped by the
        /// dongle. Returns an opaque packed blob for <see cref="AppDecrypt"/>.
        /// </summary>
        public byte[] AppEncrypt(Scope scope, byte[] plaintext)
        {
            EnsureOpen();
            if (plaintext == null)
            {
                throw new ArgumentNullException(nameof(plaintext));
            }
            int rc = NativeMethods.licd_app_encrypt(_dongle.Handle, (int)scope, plaintext, (uint)plaintext.Length,
                out IntPtr outBuf, out uint outLen);
            Errors.Check(rc, Ctx, "licd_app_encrypt");
            return CopyAndFree(outBuf, outLen);
        }

        /// <summary>
        /// Decrypts a blob produced by <see cref="AppEncrypt"/> using the dongle. A tampered blob or a
        /// dongle outside the encrypting scope fails with <see cref="LicdStatus.TagMismatch"/>.
        /// </summary>
        public byte[] AppDecrypt(byte[] packed)
        {
            EnsureOpen();
            if (packed == null)
            {
                throw new ArgumentNullException(nameof(packed));
            }
            int rc = NativeMethods.licd_app_decrypt(_dongle.Handle, packed, (uint)packed.Length,
                out IntPtr outBuf, out uint outLen);
            Errors.Check(rc, Ctx, "licd_app_decrypt");
            return CopyAndFree(outBuf, outLen);
        }

        // --- Async variants -------------------------------------------------------------------
        // The native core is blocking; these run it on the thread pool so callers can await without
        // blocking a UI thread. As with the dongle itself, do not run two operations concurrently.

        /// <summary>Asynchronously elevates the session to the write role. See <see cref="AuthorizeWrite"/>.</summary>
        public Task AuthorizeWriteAsync(byte[] masterKeyDer, CancellationToken cancellationToken = default)
            => Task.Run(() => AuthorizeWrite(masterKeyDer), cancellationToken);

        /// <summary>Asynchronously lists the records. See <see cref="ListRecords"/>.</summary>
        public Task<IReadOnlyList<RecordInfo>> ListRecordsAsync(CancellationToken cancellationToken = default)
            => Task.Run(ListRecords, cancellationToken);

        /// <summary>Asynchronously reads the entire named record. See <see cref="ReadRecord"/>.</summary>
        public Task<byte[]> ReadRecordAsync(string name, IProgress<TransferProgress>? progress = null,
            CancellationToken cancellationToken = default)
            => Task.Run(() => ReadRecord(name, progress, cancellationToken), cancellationToken);

        /// <summary>Asynchronously writes the named record. See <see cref="WriteRecord"/>.</summary>
        public Task WriteRecordAsync(string name, byte[] data, IProgress<TransferProgress>? progress = null,
            CancellationToken cancellationToken = default)
            => Task.Run(() => WriteRecord(name, data, progress, cancellationToken), cancellationToken);

        /// <summary>Asynchronously erases the named record. See <see cref="EraseRecord"/>.</summary>
        public Task EraseRecordAsync(string name, CancellationToken cancellationToken = default)
            => Task.Run(() => EraseRecord(name), cancellationToken);

        /// <summary>Asynchronously erases all records. See <see cref="EraseAllRecords"/>.</summary>
        public Task EraseAllRecordsAsync(CancellationToken cancellationToken = default)
            => Task.Run(EraseAllRecords, cancellationToken);

        /// <summary>Asynchronously reads a counter. See <see cref="ReadCounter"/>.</summary>
        public Task<uint> ReadCounterAsync(byte counterId, CancellationToken cancellationToken = default)
            => Task.Run(() => ReadCounter(counterId), cancellationToken);

        /// <summary>Asynchronously increments a counter. See <see cref="IncrementCounter"/>.</summary>
        public Task<uint> IncrementCounterAsync(byte counterId, CancellationToken cancellationToken = default)
            => Task.Run(() => IncrementCounter(counterId), cancellationToken);

        /// <summary>Asynchronously encrypts app data. See <see cref="AppEncrypt"/>.</summary>
        public Task<byte[]> AppEncryptAsync(Scope scope, byte[] plaintext, CancellationToken cancellationToken = default)
            => Task.Run(() => AppEncrypt(scope, plaintext), cancellationToken);

        /// <summary>Asynchronously decrypts app data. See <see cref="AppDecrypt"/>.</summary>
        public Task<byte[]> AppDecryptAsync(byte[] packed, CancellationToken cancellationToken = default)
            => Task.Run(() => AppDecrypt(packed), cancellationToken);

        /// <summary>Ends the session, zeroizing session keys on the dongle. Safe to call more than once.</summary>
        public void Close()
        {
            if (_closed)
            {
                return;
            }
            _closed = true;
            // Session teardown is local state; ignore the status so Dispose never throws.
            NativeMethods.licd_session_close(_dongle.Handle);
            _dongle.OnSessionClosed(this);
        }

        /// <summary>Ends the session.</summary>
        public void Dispose() => Close();

        // Bridges an IProgress/CancellationToken to the native progress callback. Returns null when
        // neither is active so the core takes its no-callback fast path.
        private static LicdProgressCallback? MakeBridge(IProgress<TransferProgress>? progress, CancellationToken ct)
        {
            if (progress == null && !ct.CanBeCanceled)
            {
                return null;
            }
            return (done, total, _) =>
            {
                if (ct.IsCancellationRequested)
                {
                    return 0; // -> native returns LICD_E_CANCELLED
                }
                progress?.Report(new TransferProgress(done, total));
                return 1;
            };
        }

        private static void ThrowIfCancelled(int rc, CancellationToken ct)
        {
            if (rc == (int)LicdStatus.Cancelled)
            {
                ct.ThrowIfCancellationRequested(); // throws OperationCanceledException(ct)
                throw new OperationCanceledException();
            }
        }

        private static byte[] Trim(byte[] buf, uint len)
        {
            if (len == (uint)buf.Length)
            {
                return buf;
            }
            var exact = new byte[len];
            Array.Copy(buf, exact, checked((int)len));
            return exact;
        }

        private static byte[] CopyAndFree(IntPtr buf, uint len)
        {
            try
            {
                if (buf == IntPtr.Zero || len == 0)
                {
                    return Array.Empty<byte>();
                }
                var outArr = new byte[len];
                Marshal.Copy(buf, outArr, 0, checked((int)len));
                return outArr;
            }
            finally
            {
                if (buf != IntPtr.Zero)
                {
                    NativeMethods.licd_free_buffer(buf);
                }
            }
        }
    }
}
