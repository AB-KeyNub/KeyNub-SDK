using System;

namespace KeyNub.LicenseDongle
{
    /// <summary>
    /// Thrown when a native core operation fails. <see cref="Status"/> carries the
    /// specific <see cref="LicdStatus"/>; some statuses surface as more specific
    /// subclasses (e.g. <see cref="NotGenuineException"/>) so callers can catch them
    /// individually. <see cref="Detail"/> holds the thread-local diagnostic string
    /// from the core, when available.
    /// </summary>
    public class LicenseDongleException : Exception
    {
        /// <summary>The status code returned by the native core.</summary>
        public LicdStatus Status { get; }

        /// <summary>Thread-local diagnostic detail from the core, or <c>null</c>.</summary>
        public string? Detail { get; }

        /// <summary>Creates a new <see cref="LicenseDongleException"/>.</summary>
        public LicenseDongleException(LicdStatus status, string message, string? detail = null)
            : base(message)
        {
            Status = status;
            Detail = detail;
        }
    }

    /// <summary>The dongle failed its authenticity (challenge-response) check.</summary>
    public sealed class NotGenuineException : LicenseDongleException
    {
        /// <summary>Creates a new <see cref="NotGenuineException"/>.</summary>
        public NotGenuineException(LicdStatus status, string message, string? detail = null)
            : base(status, message, detail) { }
    }

    /// <summary>The device certificate or its chain to the trusted root was invalid.</summary>
    public sealed class CertificateInvalidException : LicenseDongleException
    {
        /// <summary>Creates a new <see cref="CertificateInvalidException"/>.</summary>
        public CertificateInvalidException(LicdStatus status, string message, string? detail = null)
            : base(status, message, detail) { }
    }

    /// <summary>
    /// The operation requires the write role, which is granted by
    /// <see cref="Session.AuthorizeWrite"/> with the developer master key.
    /// </summary>
    public sealed class WriteAuthorizationRequiredException : LicenseDongleException
    {
        /// <summary>Creates a new <see cref="WriteAuthorizationRequiredException"/>.</summary>
        public WriteAuthorizationRequiredException(LicdStatus status, string message, string? detail = null)
            : base(status, message, detail) { }
    }

    /// <summary>No active encrypted session for an operation that requires one.</summary>
    public sealed class SessionExpiredException : LicenseDongleException
    {
        /// <summary>Creates a new <see cref="SessionExpiredException"/>.</summary>
        public SessionExpiredException(LicdStatus status, string message, string? detail = null)
            : base(status, message, detail) { }
    }

    /// <summary>No matching dongle was found or present.</summary>
    public sealed class DeviceNotFoundException : LicenseDongleException
    {
        /// <summary>Creates a new <see cref="DeviceNotFoundException"/>.</summary>
        public DeviceNotFoundException(LicdStatus status, string message, string? detail = null)
            : base(status, message, detail) { }
    }

    /// <summary>The named record does not exist on the dongle.</summary>
    public sealed class RecordNotFoundException : LicenseDongleException
    {
        /// <summary>Creates a new <see cref="RecordNotFoundException"/>.</summary>
        public RecordNotFoundException(LicdStatus status, string message, string? detail = null)
            : base(status, message, detail) { }
    }
}
