package keynub.licdongle

/** A failure status the native library reports, with its numeric code. */
enum Status(val code: Int):
  case InvalidArgument extends Status(-1)
  case NoDevice extends Status(-2)
  case AccessDenied extends Status(-3)
  case Io extends Status(-4)
  case Timeout extends Status(-5)
  case Protocol extends Status(-6)
  case NotGenuine extends Status(-7)
  case CertificateInvalid extends Status(-8)
  case SessionExpired extends Status(-9)
  case TagMismatch extends Status(-10)
  case Range extends Status(-11)
  case StorageFull extends Status(-12)
  case Busy extends Status(-13)
  case NotFound extends Status(-14)
  case AuthRequired extends Status(-15)
  case FirmwareIncompatible extends Status(-16)
  case SdkTooOld extends Status(-17)
  case Cancelled extends Status(-18)
  case NotImplemented extends Status(-19)
  case Internal extends Status(-20)

object Status:
  /** The status for a numeric code; an unknown code gives [[Status.Internal]]. */
  def fromCode(code: Int): Status = values.find(_.code == code).getOrElse(Internal)

/** A failure the native library reported.
  *
  * @param status
  *   what failed, such as [[Status.NoDevice]] or [[Status.NotGenuine]]
  * @param detail
  *   the library's diagnostic text for the call, "" when it has none
  */
final class LicDongleError(val status: Status, message: String, val detail: String, cause: Throwable)
    extends RuntimeException(message, cause):
  /** The numeric status code. */
  def code: Int = status.code

/** Where the data of an [[Session.appEncrypt]] envelope can be decrypted. */
enum Scope:
  /** Only the dongle that sealed it. */
  case Device

  /** Every dongle issued to the same developer. */
  case Developer
