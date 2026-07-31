package com.keynub.licdongle;

/** The named record does not exist on the dongle. */
public class RecordNotFoundException extends LicenseDongleException {
    public RecordNotFoundException(LicdStatus status, String message, String detail) {
        super(status, message, detail);
    }
}
