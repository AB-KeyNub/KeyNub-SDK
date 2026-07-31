using System;
using System.Runtime.InteropServices;

namespace KeyNub.LicenseDongle.Interop
{
    /// <summary>Owns a native <c>licd_ctx*</c>; releases it with <c>licd_free</c>.</summary>
    internal sealed class LicdContextHandle : SafeHandle
    {
        // Public parameterless ctor: required by the marshaler for `out` parameters.
        public LicdContextHandle() : base(IntPtr.Zero, ownsHandle: true) { }

        public override bool IsInvalid => handle == IntPtr.Zero;

        protected override bool ReleaseHandle()
        {
            NativeMethods.licd_free(handle);
            return true;
        }
    }

    /// <summary>Owns a native <c>licd_device*</c>; releases it with <c>licd_close</c>.</summary>
    internal sealed class LicdDeviceHandle : SafeHandle
    {
        public LicdDeviceHandle() : base(IntPtr.Zero, ownsHandle: true) { }

        public override bool IsInvalid => handle == IntPtr.Zero;

        protected override bool ReleaseHandle()
        {
            NativeMethods.licd_close(handle);
            return true;
        }
    }
}
