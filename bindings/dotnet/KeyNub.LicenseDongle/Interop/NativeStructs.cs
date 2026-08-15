using System.Runtime.InteropServices;

namespace KeyNub.LicenseDongle.Interop
{
    // Blittable mirror of licd_info (all bytes + ints; natural alignment matches C).
    [StructLayout(LayoutKind.Sequential)]
    internal struct LicdInfoNative
    {
        public byte proto_version_major;
        public byte proto_version_minor;
        public byte fw_version_major;
        public byte fw_version_minor;
        public byte fw_version_patch;
        public int se_ready;
        public int provisioned;
        public uint data_capacity;
        public uint data_free;
        public int watchdog_reboot;
        public int isolated;
        public int writeauth_rotated;
    }

    // Mirror of licd_genuine_result. ByValTStr copies each NUL-terminated field.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    internal struct LicdGenuineResultNative
    {
        public int genuine;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 15)]
        public string serial;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 11)]
        public string provisioned_date;
    }

    // Mirror of licd_device_info. Read from the enumerate array with
    // Marshal.PtrToStructure; the marshaled size is the array stride.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    internal struct LicdDeviceInfoNative
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 15)]
        public string serial;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)]
        public string path;

        public ushort vendor_id;
        public ushort product_id;
    }
}
