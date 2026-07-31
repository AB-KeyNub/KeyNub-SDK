package com.keynub.licdongle;

/** Severity of a diagnostic log message. */
public enum LogLevel {
    ERROR(0),
    WARN(1),
    INFO(2),
    DEBUG(3);

    private final int code;

    LogLevel(int code) {
        this.code = code;
    }

    /** The status for a numeric level, or {@link #INFO} if unrecognized. */
    public static LogLevel fromCode(int code) {
        for (LogLevel l : values()) {
            if (l.code == code) {
                return l;
            }
        }
        return INFO;
    }
}
