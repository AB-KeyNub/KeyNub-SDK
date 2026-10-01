package keynub.licdongle

/** An attached dongle, found without opening it.
  *
  * @param path
  *   the operating system's device path, for [[LicDongle.openPath]]
  */
final case class Device(serial: String, path: String, vendorId: Int, productId: Int)

/** A dongle's protocol and firmware versions, storage and status flags. Capacities are in bytes. */
final case class Info(
    protocolMajor: Int,
    protocolMinor: Int,
    firmwareMajor: Int,
    firmwareMinor: Int,
    firmwarePatch: Int,
    seReady: Boolean,
    provisioned: Boolean,
    dataCapacity: Long,
    dataFree: Long,
    watchdogReboot: Boolean,
    isolated: Boolean,
    writeAuthRotated: Boolean
)

/** The result of [[Dongle.verifyGenuine]].
  *
  * @param provisionedDate
  *   the date the dongle was provisioned, as YYYY-MM-DD
  */
final case class Verification(genuine: Boolean, serial: String, provisionedDate: String)

/** A record on the dongle and its size in bytes. */
final case class Record(name: String, size: Long)
