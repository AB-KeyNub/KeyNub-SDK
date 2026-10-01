package keynub.licdongle

import com.keynub.licdongle as j

import java.io.File
import java.nio.charset.StandardCharsets.UTF_8
import java.util.Locale
import scala.jdk.CollectionConverters.*

/** Client for the KeyNub USB license dongle, over the Java binding com.keynub:keynub-licdongle (JNA).
  *
  * {{{
  * import keynub.licdongle.*
  *
  * val secret = LicDongle.withDongle { dongle =>
  *   dongle.verifyGenuine()               // throws unless genuine
  *   dongle.withSession { session =>      // closed on every exit path
  *     session.appDecrypt(sealedBytes)    // build the licence check on this
  *   }
  * }
  * }}}
  *
  * Every failure the native library reports is thrown as a [[LicDongleError]] whose [[Status]] says what failed;
  * the Java exception is its cause.
  */
object LicDongle:

  // --- the native library -------------------------------------------------

  /** The system property the Java binding loads the native library from. */
  val LibraryProperty: String = "keynub.licdongle.library"

  /** The environment variable that names the native library file. */
  val LibraryEnvironmentVariable: String = "KEYNUB_LICDONGLE_LIBRARY"

  /** The natives/<platform> folder name of the SDK repository and the library's file name, for this JVM. */
  private[licdongle] def platform(osName: String, osArch: String): (String, String) =
    val os = osName.toLowerCase(Locale.ROOT)
    val cpu = osArch.toLowerCase(Locale.ROOT) match
      case "amd64" | "x86_64"                        => "x64"
      case "aarch64" | "arm64"                       => "arm64"
      case "x86" | "i386" | "i486" | "i586" | "i686" => "x86"
      case other                                     => other
    if os.startsWith("windows") then (s"win-$cpu", "keynub_licdongle.dll")
    else if os.startsWith("mac") || os.contains("darwin") then (s"osx-$cpu", "libkeynub_licdongle.dylib")
    else (s"linux-$cpu", "libkeynub_licdongle.so")

  /** natives/<platform>/<file> in the working directory or one of its parents, as in a clone of the SDK. */
  private def findInClone(): Option[String] =
    val (folder, file) = platform(System.getProperty("os.name"), System.getProperty("os.arch"))
    Iterator
      .iterate(new File(System.getProperty("user.dir")).getAbsoluteFile)(_.getParentFile)
      .takeWhile(_ != null)
      .take(8)
      .map(dir => new File(new File(new File(dir, "natives"), folder), file))
      .find(_.isFile)
      .map(_.getPath)

  private def nonEmpty(s: String): Option[String] = Option(s).filter(_.nonEmpty)

  /** The library this process uses, chosen once before the Java binding's first call: the system property, else
    * KEYNUB_LICDONGLE_LIBRARY, else natives/<platform> of a clone, else None for the bare name that JNA resolves
    * along jna.library.path and the system search path.
    */
  private lazy val chosen: Option[String] =
    nonEmpty(System.getProperty(LibraryProperty)).orElse {
      val found = nonEmpty(System.getenv(LibraryEnvironmentVariable)).orElse(findInClone())
      found.foreach(System.setProperty(LibraryProperty, _))
      found
    }

  @volatile private var resolved = false

  private def ensureLibrary(): Unit =
    chosen
    resolved = true

  /** Names the native library file to load. Must come before the first call that needs the library; a process
    * loads it once, so naming a different file afterwards throws [[Status.InvalidArgument]].
    */
  def setLibraryPath(path: String): Unit =
    require(path != null && path.nonEmpty, "the library path must be a non-empty string")
    if resolved && !chosen.contains(path) then
      throw LicDongleError(
        Status.InvalidArgument,
        s"the KeyNub library is already chosen: ${chosen.getOrElse("keynub_licdongle")}; a process loads it once",
        "",
        null
      )
    System.setProperty(LibraryProperty, path)

  /** The library file this process loads, or None when JNA resolves the bare name keynub_licdongle. */
  def libraryPath: Option[String] =
    ensureLibrary()
    chosen

  // --- errors -------------------------------------------------------------

  private def statusOf(s: j.LicdStatus): Status = Status.fromCode(s.code)

  /** Evaluates body; a failure the native library reports becomes a [[LicDongleError]]. */
  private[licdongle] def licd[A](body: => A): A =
    try body
    catch
      case e: j.LicenseDongleException =>
        throw LicDongleError(statusOf(e.getStatus), e.getMessage, Option(e.getDetail).getOrElse(""), e)
      case e: j.OperationCancelledException =>
        throw LicDongleError(Status.Cancelled, e.getMessage, "", e)

  private[licdongle] def utf8(text: String): Array[Byte] =
    require(text != null, "the text must not be null")
    text.getBytes(UTF_8)

  private[licdongle] def bytes(data: Array[Byte], what: String): Array[Byte] =
    require(data != null, s"$what must not be null")
    data

  // --- library and context ------------------------------------------------

  private lazy val context: j.LicenseDongleContext =
    ensureLibrary()
    licd(new j.LicenseDongleContext())

  /** The version of the native library, which is the SDK version it was built from, such as "1.1.1". */
  def libraryVersion: String =
    ensureLibrary()
    licd(j.LicenseDongleContext.libraryVersion())

  /** The native library's diagnostic text for the last call that failed on this thread, "" when it succeeded. */
  def lastErrorDetail: String = Option(context.lastErrorDetail()).getOrElse("")

  /** Replaces the root certificate (DER) that dongle certificates are verified against, for every later
    * verification in this process. Applications do not need this: the native library embeds the KeyNub production
    * root.
    */
  def setTrustRoot(der: Array[Byte]): Unit = licd(context.setTrustRoot(bytes(der, "der")))

  // --- dongles ------------------------------------------------------------

  /** The attached dongles, without opening any. */
  def devices: Vector[Device] =
    licd(context.enumerate()).asScala.toVector.map(d => Device(d.serial, d.path, d.vendorId, d.productId))

  /** Opens the first attached dongle. Close it, or use [[withDongle]]. */
  def open(): Dongle = Dongle(licd(context.open()))

  /** Opens the dongle with the given serial. */
  def open(serial: String): Dongle =
    require(serial != null && serial.nonEmpty, "the serial must be a non-empty string")
    Dongle(licd(context.open(serial)))

  /** Opens the dongle at a device path from [[devices]]. */
  def openPath(path: String): Dongle =
    require(path != null && path.nonEmpty, "the path must be a non-empty string")
    Dongle(licd(context.openPath(path)))

  /** Opens the first dongle, passes it to f and closes it on every exit path. Returns what f returns. */
  def withDongle[A](f: Dongle => A): A = using(open())(f)

  /** Opens the dongle with the given serial, passes it to f and closes it on every exit path. */
  def withDongle[A](serial: String)(f: Dongle => A): A = using(open(serial))(f)

  private[licdongle] def using[R <: AutoCloseable, A](resource: R)(f: R => A): A =
    try f(resource)
    finally resource.close()

/** An open dongle. Closing it also ends its session. Safe to close more than once. */
final class Dongle private[licdongle] (val underlying: j.Dongle) extends AutoCloseable:
  import LicDongle.licd

  /** The dongle's protocol and firmware versions, storage and status flags. */
  def info: Info =
    val i = licd(underlying.getInfo())
    Info(
      i.protocolMajor,
      i.protocolMinor,
      i.firmwareMajor,
      i.firmwareMinor,
      i.firmwarePatch,
      i.seReady,
      i.provisioned,
      i.dataCapacity,
      i.dataFree,
      i.watchdogReboot,
      i.isolated,
      i.writeauthRotated
    )

  /** The dongle's serial, a hex string. */
  def serial: String = licd(underlying.getSerial())

  /** Proves that the dongle is genuine: verifies its certificate chain against the trusted root and runs a live
    * challenge-response against the key inside it. A dongle that fails throws with [[Status.NotGenuine]] or
    * [[Status.CertificateInvalid]].
    */
  def verifyGenuine(): Verification =
    val g = licd(underlying.verifyGenuine())
    Verification(g.genuine, g.serial, g.provisionedDate)

  /** true when the dongle proves genuine, false otherwise. Fails closed: every failure, a closed dongle included,
    * gives false.
    *
    * `if !dongle.isGenuine then sys.exit(1)` is one branch to patch out. Put data the program needs through
    * [[Session.appEncrypt]] and ship only the sealed form.
    */
  def isGenuine: Boolean =
    try underlying.verifyGenuine().genuine
    catch case _: Throwable => false

  /** Opens the encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM) that records, counters and app encryption
    * need. A dongle has one session at a time: opening another ends the one before it.
    */
  def openSession(): Session = Session(licd(underlying.openSession()))

  /** Opens a session, passes it to f and closes it on every exit path. Returns what f returns. */
  def withSession[A](f: Session => A): A = LicDongle.using(openSession())(f)

  override def close(): Unit = underlying.close()

/** An encrypted session on a dongle. Closing the dongle ends it too. Safe to close more than once. */
final class Session private[licdongle] (val underlying: j.Session) extends AutoCloseable:
  import LicDongle.{bytes, licd, utf8}

  private def recordName(name: String): String =
    require(name != null && name.nonEmpty, "the record name must be a non-empty string")
    name

  private def callback(progress: (Long, Long) => Boolean): j.ProgressCallback =
    require(progress != null, "progress must not be null")
    (p: j.TransferProgress) => progress(p.bytesTransferred, p.totalBytes)

  /** Whether the session has been closed. */
  def isClosed: Boolean = underlying.isClosed

  /** Unlocks writing, erasing and counter increments for the rest of the session with the dongle's write key, a
    * P-256 private key in PKCS#8 DER. This belongs in your licence-issuing tooling; never ship that key with what
    * your users run. A key the dongle does not accept throws with [[Status.NotGenuine]].
    */
  def authorizeWrite(key: Array[Byte]): Unit = licd(underlying.authorizeWrite(bytes(key, "the key")))

  /** Replaces the dongle's write key with one you hold (PKCS#8 DER). Needs the write role. The session keeps the
    * write role; from the next session on only the new key elevates. Do this once per dongle, when it arrives: the
    * factory key is public.
    */
  def rotateWriteKey(key: Array[Byte]): Unit = licd(underlying.rotateWriteKey(bytes(key, "the key")))

  /** The records on the dongle. */
  def records: Vector[Record] =
    licd(underlying.listRecords()).asScala.toVector.map(r => Record(r.name, r.size))

  /** Reads a record. A record that does not exist throws with [[Status.NotFound]]. */
  def read(name: String): Array[Byte] = licd(underlying.readRecord(recordName(name)))

  /** Reads a record, calling progress(done, total) in bytes; false from progress cancels the transfer. */
  def read(name: String, progress: (Long, Long) => Boolean): Array[Byte] =
    licd(underlying.readRecord(recordName(name), callback(progress)))

  /** Reads a record as UTF-8 text. */
  def readString(name: String): String = new String(read(name), UTF_8)

  /** Creates or replaces a record atomically. Needs the write role. */
  def write(name: String, data: Array[Byte]): Unit =
    licd(underlying.writeRecord(recordName(name), bytes(data, "the data")))

  /** Creates or replaces a record with text, stored as UTF-8. Needs the write role. */
  def write(name: String, text: String): Unit = write(name, utf8(text))

  /** Creates or replaces a record, calling progress(done, total) in bytes; false from progress cancels. */
  def write(name: String, data: Array[Byte], progress: (Long, Long) => Boolean): Unit =
    licd(underlying.writeRecord(recordName(name), bytes(data, "the data"), callback(progress)))

  /** Erases one record. Needs the write role. An empty name is refused, so this never erases more than one. */
  def erase(name: String): Unit = licd(underlying.eraseRecord(recordName(name)))

  /** Erases every record on the dongle. Needs the write role. */
  def eraseAll(): Unit = licd(underlying.eraseAllRecords())

  /** Reads a monotonic counter (an id from 0 upwards). */
  def readCounter(id: Int): Long = licd(underlying.readCounter(id))

  /** Increments a monotonic counter and returns its new value. Needs the write role; an increment cannot be
    * undone.
    */
  def incrementCounter(id: Int): Long = licd(underlying.incrementCounter(id))

  /** Encrypts data so that only a dongle can decrypt it and returns the sealed bytes. Put something the program
    * needs through this and ship only the sealed form, so removing the check removes the data.
    * [[Scope.Developer]] lets any dongle you have issued decrypt it; [[Scope.Device]] locks it to this dongle.
    */
  def appEncrypt(scope: Scope, data: Array[Byte]): Array[Byte] =
    require(scope != null, "the scope must not be null")
    val s = scope match
      case Scope.Device    => j.Scope.DEVICE
      case Scope.Developer => j.Scope.DEVELOPER
    licd(underlying.appEncrypt(s, bytes(data, "the data")))

  /** Encrypts text, as UTF-8, so that only a dongle can decrypt it. */
  def appEncrypt(scope: Scope, text: String): Array[Byte] = appEncrypt(scope, utf8(text))

  /** Decrypts data from [[appEncrypt]] and returns the plaintext. Altered data throws with [[Status.TagMismatch]]. */
  def appDecrypt(sealedData: Array[Byte]): Array[Byte] = licd(underlying.appDecrypt(bytes(sealedData, "the data")))

  override def close(): Unit = underlying.close()
