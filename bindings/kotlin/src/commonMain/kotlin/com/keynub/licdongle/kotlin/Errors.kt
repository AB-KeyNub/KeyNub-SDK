package com.keynub.licdongle.kotlin

/** A status the native library reports, with its numeric code. */
public enum class Status(public val code: Int) {
    InvalidArgument(-1),
    NoDevice(-2),
    AccessDenied(-3),
    Io(-4),
    Timeout(-5),
    Protocol(-6),
    NotGenuine(-7),
    CertificateInvalid(-8),
    SessionExpired(-9),
    TagMismatch(-10),
    Range(-11),
    StorageFull(-12),
    Busy(-13),
    NotFound(-14),
    AuthRequired(-15),
    FirmwareIncompatible(-16),
    SdkTooOld(-17),
    Cancelled(-18),
    NotImplemented(-19),
    Internal(-20),
    ;

    public companion object {
        /** The status for a numeric code, or null for a code this library does not know. */
        public fun fromCode(code: Int): Status? = entries.firstOrNull { it.code == code }
    }
}

/**
 * A failed dongle call.
 *
 * @property status what failed, or null for a code this library does not know
 * @property code the raw status code
 * @property operation the flat API function that failed
 * @property detail the library's diagnostic text for the call, "" when it has none
 */
public open class LicDongleException(
    public val status: Status?,
    public val code: Int,
    public val operation: String,
    public val detail: String,
) : RuntimeException(
    "$operation: ${status?.name ?: "unknown"} ($code)" + if (detail.isEmpty()) "" else ": $detail",
)

/** The native library could not be loaded, or does not export the flat API. */
public class LibraryException(message: String) : RuntimeException(message)
