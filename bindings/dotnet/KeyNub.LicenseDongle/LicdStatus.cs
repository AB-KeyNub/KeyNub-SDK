namespace KeyNub.LicenseDongle
{
    /// <summary>
    /// Status codes returned by the native core. <see cref="Ok"/> is success (0);
    /// every failure is negative and surfaces as a <see cref="LicenseDongleException"/>.
    /// Mirrors <c>licd_status</c> in <c>licdongle.h</c>.
    /// </summary>
    public enum LicdStatus
    {
        /// <summary>Operation succeeded.</summary>
        Ok = 0,
        /// <summary>A caller argument was invalid.</summary>
        InvalidArgument = -1,
        /// <summary>No matching dongle was found or present.</summary>
        NoDevice = -2,
        /// <summary>The OS denied access to the device (see the error detail: udev rule / macOS TCC).</summary>
        AccessDenied = -3,
        /// <summary>A transport read/write failed.</summary>
        Io = -4,
        /// <summary>The device did not respond in time.</summary>
        Timeout = -5,
        /// <summary>The protocol response was malformed or unexpected.</summary>
        Protocol = -6,
        /// <summary>The authenticity (challenge-response) check failed.</summary>
        NotGenuine = -7,
        /// <summary>The device certificate or its chain was invalid.</summary>
        CertificateInvalid = -8,
        /// <summary>No active session for an operation that requires one.</summary>
        SessionExpired = -9,
        /// <summary>An AEAD tag / MAC verification failed.</summary>
        TagMismatch = -10,
        /// <summary>An offset or length was out of range.</summary>
        Range = -11,
        /// <summary>The dongle data area is exhausted.</summary>
        StorageFull = -12,
        /// <summary>The device is busy with a prior operation.</summary>
        Busy = -13,
        /// <summary>The named record does not exist.</summary>
        NotFound = -14,
        /// <summary>The operation needs a session or the write role.</summary>
        AuthRequired = -15,
        /// <summary>The firmware protocol is newer than this SDK understands.</summary>
        FirmwareIncompatible = -16,
        /// <summary>This SDK is too old for the firmware (alias of <see cref="FirmwareIncompatible"/>).</summary>
        SdkTooOld = -17,
        /// <summary>The operation was cancelled via a progress callback.</summary>
        Cancelled = -18,
        /// <summary>Declared in the ABI but not implemented in this build.</summary>
        NotImplemented = -19,
        /// <summary>An internal or unknown error occurred.</summary>
        Internal = -20,
    }
}
