package com.keynub.licdongle;

/** Native status codes (mirrors {@code licd_status}). {@link #OK} is 0; errors are negative. */
public enum LicdStatus {
    OK(0),
    INVALID_ARGUMENT(-1),
    NO_DEVICE(-2),
    ACCESS_DENIED(-3),
    IO(-4),
    TIMEOUT(-5),
    PROTOCOL(-6),
    NOT_GENUINE(-7),
    CERTIFICATE_INVALID(-8),
    SESSION_EXPIRED(-9),
    TAG_MISMATCH(-10),
    RANGE(-11),
    STORAGE_FULL(-12),
    BUSY(-13),
    NOT_FOUND(-14),
    AUTH_REQUIRED(-15),
    FIRMWARE_INCOMPATIBLE(-16),
    SDK_TOO_OLD(-17),
    CANCELLED(-18),
    NOT_IMPLEMENTED(-19),
    INTERNAL(-20);

    private final int code;

    LicdStatus(int code) {
        this.code = code;
    }

    /** The numeric status code. */
    public int code() {
        return code;
    }

    /** The status for a numeric code, or {@link #INTERNAL} if unrecognized. */
    public static LicdStatus fromCode(int code) {
        for (LicdStatus s : values()) {
            if (s.code == code) {
                return s;
            }
        }
        return INTERNAL;
    }
}
