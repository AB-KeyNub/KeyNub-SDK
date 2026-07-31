package com.keynub.licdongle;

/** The dongle failed its authenticity (challenge-response) check. */
public class NotGenuineException extends LicenseDongleException {
    public NotGenuineException(LicdStatus status, String message, String detail) {
        super(status, message, detail);
    }
}
