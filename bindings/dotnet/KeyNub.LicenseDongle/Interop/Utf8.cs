using System;
using System.Runtime.InteropServices;
using System.Text;

namespace KeyNub.LicenseDongle.Interop
{
    /// <summary>UTF-8 marshaling helpers that behave identically on every target framework.</summary>
    internal static class Utf8
    {
        /// <summary>Encodes <paramref name="s"/> as a NUL-terminated UTF-8 buffer, or <c>null</c> if <paramref name="s"/> is null.</summary>
        public static byte[]? ToNullTerminated(string? s)
        {
            if (s == null)
            {
                return null;
            }
            int n = Encoding.UTF8.GetByteCount(s);
            var buf = new byte[n + 1];
            Encoding.UTF8.GetBytes(s, 0, s.Length, buf, 0);
            buf[n] = 0; // terminator
            return buf;
        }

        /// <summary>Reads a NUL-terminated UTF-8 C string from native memory.</summary>
        public static string FromPtr(IntPtr p)
        {
            if (p == IntPtr.Zero)
            {
                return string.Empty;
            }
            int len = 0;
            while (Marshal.ReadByte(p, len) != 0)
            {
                len++;
            }
            if (len == 0)
            {
                return string.Empty;
            }
            var buf = new byte[len];
            Marshal.Copy(p, buf, 0, len);
            return Encoding.UTF8.GetString(buf);
        }

        /// <summary>Reads a NUL-terminated UTF-8 string from a fixed-size buffer (stops at the first NUL or the end).</summary>
        public static string FromFixedBuffer(byte[] buf)
        {
            int len = 0;
            while (len < buf.Length && buf[len] != 0)
            {
                len++;
            }
            return len == 0 ? string.Empty : Encoding.UTF8.GetString(buf, 0, len);
        }
    }
}
