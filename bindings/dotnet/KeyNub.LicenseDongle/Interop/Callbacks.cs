using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace AOT
{
    /// <summary>
    /// Marks a static method that native code calls back into. Ahead-of-time compilers that need a
    /// reverse-call stub for such a method (Unity's IL2CPP) look for this attribute by name.
    /// </summary>
    [AttributeUsage(AttributeTargets.Method)]
    internal sealed class MonoPInvokeCallbackAttribute : Attribute
    {
        public MonoPInvokeCallbackAttribute(Type type)
        {
            Type = type;
        }

        public Type Type { get; }
    }
}

namespace KeyNub.LicenseDongle.Interop
{
    /// <summary>
    /// The native callbacks: static methods, with the managed target passed through the native
    /// <c>user</c> pointer as a <see cref="GCHandle"/>.
    /// </summary>
    internal static class Callbacks
    {
        /// <summary>The log callback registered with <c>licd_set_log_callback</c>.</summary>
        internal static readonly LicdLogCallback Log = OnLog;

        /// <summary>The progress callback passed to the record transfers.</summary>
        internal static readonly LicdProgressCallback Progress = OnProgress;

        /// <summary>What a record transfer reports progress to and checks for cancellation.</summary>
        internal sealed class ProgressTarget
        {
            internal ProgressTarget(IProgress<TransferProgress>? progress, CancellationToken cancellationToken)
            {
                Reporter = progress;
                CancellationToken = cancellationToken;
            }

            internal IProgress<TransferProgress>? Reporter { get; }

            internal CancellationToken CancellationToken { get; }
        }

        [AOT.MonoPInvokeCallback(typeof(LicdLogCallback))]
        private static void OnLog(LogLevel level, IntPtr msg, IntPtr user)
        {
            if (user != IntPtr.Zero && GCHandle.FromIntPtr(user).Target is Action<LogLevel, string> callback)
            {
                callback(level, Utf8.FromPtr(msg));
            }
        }

        [AOT.MonoPInvokeCallback(typeof(LicdProgressCallback))]
        private static int OnProgress(uint done, uint total, IntPtr user)
        {
            if (user == IntPtr.Zero || !(GCHandle.FromIntPtr(user).Target is ProgressTarget target))
            {
                return 1;
            }
            if (target.CancellationToken.IsCancellationRequested)
            {
                return 0; // -> native returns LICD_E_CANCELLED
            }
            target.Reporter?.Report(new TransferProgress(done, total));
            return 1;
        }
    }
}
