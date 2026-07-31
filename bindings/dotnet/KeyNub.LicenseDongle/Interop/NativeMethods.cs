using System;
using System.Runtime.InteropServices;

namespace KeyNub.LicenseDongle.Interop
{
    // Diagnostic log callback: level, NUL-terminated UTF-8 message, opaque user ptr.
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void LicdLogCallback(LogLevel level, IntPtr msg, IntPtr user);

    // Progress callback: return nonzero to continue, zero to cancel the transfer.
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int LicdProgressCallback(uint done, uint total, IntPtr user);

    /// <summary>
    /// The raw P/Invoke surface for the <c>keynub_licdongle</c> core. All functions use the
    /// C calling convention and the exact C entry-point names. Strings cross the boundary as
    /// NUL-terminated UTF-8 (<c>byte[]</c>); <c>size_t</c> is <see cref="UIntPtr"/>.
    /// </summary>
    internal static class NativeMethods
    {
        // Base name; the runtime adds the platform prefix/extension
        // (keynub_licdongle.dll / libkeynub_licdongle.so / .dylib).
        internal const string Lib = "keynub_licdongle";

        private const CallingConvention Cc = CallingConvention.Cdecl;

        // --- Version / context -------------------------------------------------
        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern void licd_version(out int major, out int minor, out int patch);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_init(out LicdContextHandle ctx);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern void licd_free(IntPtr ctx);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern void licd_set_log_callback(LicdContextHandle ctx, LicdLogCallback? cb, IntPtr user);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_set_trust_root(LicdContextHandle ctx, byte[] der, UIntPtr len);

        // --- Enumerate / open / close -----------------------------------------
        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_enumerate(LicdContextHandle ctx, out IntPtr list, out UIntPtr count);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern void licd_free_device_list(IntPtr list, UIntPtr count);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_open(LicdContextHandle ctx, byte[]? serialOrNull, out LicdDeviceHandle dev);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_open_path(LicdContextHandle ctx, byte[] path, out LicdDeviceHandle dev);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern void licd_close(IntPtr dev);

        // --- Info --------------------------------------------------------------
        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_get_info(LicdDeviceHandle dev, out LicdInfoNative info);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_get_serial(LicdDeviceHandle dev, byte[] outSerial, UIntPtr serialSize);

        // --- Authenticity / session -------------------------------------------
        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_verify_genuine(LicdDeviceHandle dev, out LicdGenuineResultNative result);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_session_open(LicdDeviceHandle dev);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_session_close(LicdDeviceHandle dev);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_write_auth(LicdDeviceHandle dev, byte[] masterKeyDer, UIntPtr len);

        // --- Records -----------------------------------------------------------
        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_record_list(LicdDeviceHandle dev, out IntPtr names, out IntPtr sizes, out UIntPtr count);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern void licd_free_record_list(IntPtr names, IntPtr sizes, UIntPtr count);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_record_read(LicdDeviceHandle dev, byte[] name, uint offset,
            byte[] buf, uint bufSize, out uint outLen, out uint outTotal,
            LicdProgressCallback? progress, IntPtr user);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_record_write(LicdDeviceHandle dev, byte[] name, byte[] data, uint len,
            LicdProgressCallback? progress, IntPtr user);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_record_erase(LicdDeviceHandle dev, byte[]? name);

        // --- Counters ----------------------------------------------------------
        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_counter_read(LicdDeviceHandle dev, byte counterId, out uint value);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_counter_increment(LicdDeviceHandle dev, byte counterId, out uint value);

        // --- App-data envelope encryption -------------------------------------
        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_app_encrypt(LicdDeviceHandle dev, int scope, byte[] plaintext, uint len,
            out IntPtr outBuf, out uint outLen);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern int licd_app_decrypt(LicdDeviceHandle dev, byte[] packed, uint packedLen,
            out IntPtr outBuf, out uint outLen);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern void licd_free_buffer(IntPtr buf);

        // --- Errors ------------------------------------------------------------
        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern IntPtr licd_strerror(int status);

        [DllImport(Lib, CallingConvention = Cc, ExactSpelling = true)]
        internal static extern IntPtr licd_error_detail(LicdContextHandle ctx);
    }
}
