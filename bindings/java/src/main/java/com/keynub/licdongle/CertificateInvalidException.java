package com.keynub.licdongle;

/** The device certificate or its chain to the trusted root was invalid. */
public class CertificateInvalidException extends LicenseDongleException {
    public CertificateInvalidException(LicdStatus status, String message, String detail) {
        super(status, message, detail);
    }
}
