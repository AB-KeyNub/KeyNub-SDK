package com.keynub.licdongle;

/** No matching dongle was found or present. */
public class DeviceNotFoundException extends LicenseDongleException {
    public DeviceNotFoundException(LicdStatus status, String message, String detail) {
        super(status, message, detail);
    }
}
