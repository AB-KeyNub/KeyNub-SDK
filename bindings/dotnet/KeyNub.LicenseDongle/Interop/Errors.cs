using System;

namespace KeyNub.LicenseDongle.Interop
{
    /// <summary>Maps native status codes to managed exceptions.</summary>
    internal static class Errors
    {
        /// <summary>
        /// Throws the appropriate exception when <paramref name="rc"/> is not
        /// <see cref="LicdStatus.Ok"/>. <paramref name="ctx"/> (may be null) is used to read the
        /// thread-local error detail; <paramref name="operation"/> names the failed call.
        /// </summary>
        public static void Check(int rc, LicdContextHandle? ctx, string operation)
        {
            if (rc == 0)
            {
                return;
            }

            var status = (LicdStatus)rc;

            // A progress callback returning "cancel" is a first-class .NET concept.
            if (status == LicdStatus.Cancelled)
            {
                throw new OperationCanceledException($"{operation} was cancelled.");
            }

            string detail = string.Empty;
            if (ctx != null && !ctx.IsInvalid)
            {
                detail = Utf8.FromPtr(NativeMethods.licd_error_detail(ctx));
            }
            string strerr = Utf8.FromPtr(NativeMethods.licd_strerror(rc));
            string message = detail.Length > 0
                ? $"{operation}: {strerr} - {detail}"
                : $"{operation}: {strerr}";

            throw Create(status, message, detail.Length > 0 ? detail : null);
        }

        private static LicenseDongleException Create(LicdStatus status, string message, string? detail)
        {
            switch (status)
            {
                case LicdStatus.NotGenuine:
                    return new NotGenuineException(status, message, detail);
                case LicdStatus.CertificateInvalid:
                    return new CertificateInvalidException(status, message, detail);
                case LicdStatus.AuthRequired:
                    return new WriteAuthorizationRequiredException(status, message, detail);
                case LicdStatus.SessionExpired:
                    return new SessionExpiredException(status, message, detail);
                case LicdStatus.NoDevice:
                    return new DeviceNotFoundException(status, message, detail);
                case LicdStatus.NotFound:
                    return new RecordNotFoundException(status, message, detail);
                default:
                    return new LicenseDongleException(status, message, detail);
            }
        }
    }
}
