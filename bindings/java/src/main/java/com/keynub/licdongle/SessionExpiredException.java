package com.keynub.licdongle;

/** No active session for an operation that requires one. */
public class SessionExpiredException extends LicenseDongleException {
    public SessionExpiredException(LicdStatus status, String message, String detail) {
        super(status, message, detail);
    }
}
