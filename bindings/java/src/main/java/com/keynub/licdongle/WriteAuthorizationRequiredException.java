package com.keynub.licdongle;

/** The operation needs the write role (grant it with {@link Session#authorizeWrite}). */
public class WriteAuthorizationRequiredException extends LicenseDongleException {
    public WriteAuthorizationRequiredException(LicdStatus status, String message, String detail) {
        super(status, message, detail);
    }
}
