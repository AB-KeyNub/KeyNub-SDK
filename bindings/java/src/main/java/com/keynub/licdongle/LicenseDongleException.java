package com.keynub.licdongle;

/**
 * Thrown when a native operation fails. {@link #getStatus()} carries the specific
 * {@link LicdStatus}; some statuses surface as more specific subclasses.
 */
public class LicenseDongleException extends RuntimeException {

    private final transient LicdStatus status;
    private final String detail;

    public LicenseDongleException(LicdStatus status, String message, String detail) {
        super(message);
        this.status = status;
        this.detail = detail;
    }

    /** The status code returned by the native core. */
    public LicdStatus getStatus() {
        return status;
    }

    /** Thread-local diagnostic detail from the core, or {@code null}. */
    public String getDetail() {
        return detail;
    }

    /** Create the appropriate exception subclass for a status. */
    static LicenseDongleException of(LicdStatus status, String message, String detail) {
        switch (status) {
            case NOT_GENUINE:
                return new NotGenuineException(status, message, detail);
            case CERTIFICATE_INVALID:
                return new CertificateInvalidException(status, message, detail);
            case AUTH_REQUIRED:
                return new WriteAuthorizationRequiredException(status, message, detail);
            case SESSION_EXPIRED:
                return new SessionExpiredException(status, message, detail);
            case NO_DEVICE:
                return new DeviceNotFoundException(status, message, detail);
            case NOT_FOUND:
                return new RecordNotFoundException(status, message, detail);
            default:
                return new LicenseDongleException(status, message, detail);
        }
    }
}
