package com.keynub.licdongle;

import com.sun.jna.Pointer;

/** Maps native status codes to exceptions. */
final class Errors {
    private Errors() {
    }

    /** Throw the appropriate exception when {@code rc} is not OK. {@code ctx} may be null. */
    static void check(int rc, Pointer ctx, String operation) {
        if (rc == 0) {
            return;
        }
        LicdStatus status = LicdStatus.fromCode(rc);
        if (status == LicdStatus.CANCELLED) {
            throw new OperationCancelledException(operation + " was cancelled");
        }
        String detail = ctx != null ? nullToEmpty(LicdLibrary.INSTANCE.licd_error_detail(ctx)) : "";
        String strerr = nullToEmpty(LicdLibrary.INSTANCE.licd_strerror(rc));
        String message = detail.isEmpty()
                ? operation + ": " + strerr
                : operation + ": " + strerr + " - " + detail;
        throw LicenseDongleException.of(status, message, detail.isEmpty() ? null : detail);
    }

    private static String nullToEmpty(String s) {
        return s == null ? "" : s;
    }
}
