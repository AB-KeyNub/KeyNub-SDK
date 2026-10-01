package keynub.licdongle

import java.io.{File, IOException}
import java.nio.charset.StandardCharsets.UTF_8
import java.util.Locale
import scala.collection.mutable.ArrayBuffer
import scala.util.control.NonFatal

/** Every call of the Scala API against a stand-in for the C ABI (bindings/julia/test/stub/licd_stub.c): one
  * imaginary dongle held in memory, compiled into a shared library in the temp directory with the first C compiler
  * found of cc, gcc, clang, zig cc and cl. The stand-in keeps records, counters and the write key per opened device.
  *
  * {{{
  * mvn test        (in bindings/scala)
  * }}}
  *
  * KEYNUB_SDK_ROOT names the SDK sources when the test does not run inside a clone; KEYNUB_LICDONGLE_LIBRARY names
  * an already compiled stand-in.
  */
object StandInTest:

  // --- the stand-in -------------------------------------------------------

  private def sdkRoot(): File =
    Option(System.getenv("KEYNUB_SDK_ROOT")).filter(_.nonEmpty).map(File(_)).getOrElse {
      Iterator
        .iterate(File(System.getProperty("user.dir")).getAbsoluteFile)(_.getParentFile)
        .takeWhile(_ != null)
        .find(dir => File(dir, "bindings/flat/licd_flat.c").isFile)
        .getOrElse(
          throw IllegalStateException("the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT")
        )
    }

  private def succeeds(dir: File, command: Seq[String]): Boolean =
    try
      val p = ProcessBuilder(command*).directory(dir).redirectErrorStream(true).start()
      p.getInputStream.readAllBytes()
      p.waitFor() == 0
    catch case _: IOException => false

  private def buildStandIn(): String =
    val root = sdkRoot()
    val os = System.getProperty("os.name").toLowerCase(Locale.ROOT)
    val windows = os.startsWith("windows")
    val dir = File(System.getProperty("java.io.tmpdir"), "keynub-standin-scala")
    // Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf name.
    val out = File(
      dir,
      if windows then "keynub_licdongle_standin.dll"
      else if os.contains("mac") then "libkeynub_licdongle_standin.dylib"
      else "libkeynub_licdongle_standin.so"
    )
    val core = File(root, "core/include")
    val include = if File(core, "licdongle.h").isFile then core else File(root, "include")
    val source = File(root, "bindings/julia/test/stub/licd_stub.c")
    val gcc = Seq("-shared", "-O1", "-DLICD_BUILD_SHARED", s"-I$include", "-o", out.toString, source.toString) ++
      (if windows then Nil else Seq("-fPIC"))
    val cl = Seq("/nologo", "/LD", "/O1", "/DLICD_BUILD_SHARED", s"/I$include", s"/Fe:$out", source.toString)
    dir.mkdirs()
    Seq(Seq("cc") ++ gcc, Seq("gcc") ++ gcc, Seq("clang") ++ gcc, Seq("zig", "cc") ++ gcc, Seq("cl") ++ cl)
      .find(command => succeeds(dir, command) && out.isFile)
      .map(_ => out.toString)
      .getOrElse(
        throw IllegalStateException(
          "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path"
        )
      )

  // --- checks -------------------------------------------------------------

  private val failures = ArrayBuffer.empty[String]
  private var checks = 0

  private def check(ok: Boolean, what: String): Unit =
    checks += 1
    if !ok then
      failures += what
      println(s"FAILED: $what")

  private def statusOf(f: => Any): Option[Status] =
    try
      f
      None
    catch case e: LicDongleError => Some(e.status)

  private def fails(status: Status, what: String)(f: => Any): Unit =
    val got = statusOf(f)
    check(got.contains(status), s"$what: expected $status, got ${got.getOrElse("no failure")}")

  private def throwsA[E <: Throwable](what: String)(f: => Any)(using tag: scala.reflect.ClassTag[E]): Unit =
    val thrown =
      try
        f
        false
      catch case e: Throwable => tag.runtimeClass.isInstance(e)
    check(thrown, s"$what: expected ${tag.runtimeClass.getSimpleName}")

  private def utf8(s: String): Array[Byte] = s.getBytes(UTF_8)
  private def same(a: Array[Byte], b: Array[Byte]): Boolean = java.util.Arrays.equals(a, b)

  private val serial = "04A1B2C3D4E5F6"
  private val factoryKey = Array[Byte](0x30, 0x10, 0x01, 0x02, 0x03)
  private val replacementKey = Array[Byte](0x30, 0x11, 0x09, 0x08, 0x07, 0x06)

  // --- the tests ----------------------------------------------------------

  private def devicesAndOpen(): Unit =
    check(LicDongle.libraryVersion == "9.8.7", "libraryVersion")
    check(LicDongle.devices == Vector(Device(serial, "stub:0", 0x1234, 0xabcd)), "devices")
    val e =
      try
        LicDongle.open("nope")
        null
      catch case e: LicDongleError => e
    check(e != null && e.status == Status.NoDevice && e.code == -2, "open by unknown serial")
    check(e != null && e.detail == "no dongle with that serial", "the error carries the detail")
    check(e != null && e.getCause.isInstanceOf[com.keynub.licdongle.DeviceNotFoundException], "the Java cause")
    check(LicDongle.lastErrorDetail == "no dongle with that serial", "lastErrorDetail")
    fails(Status.NoDevice, "open by unknown path")(LicDongle.openPath("stub:9"))
    LicDongle.withDongle(d => check(d.serial == serial, "withDongle"))
    LicDongle.withDongle(serial)(d => check(d.serial == serial, "withDongle by serial"))
    val d = LicDongle.openPath("stub:0")
    check(d.serial == serial, "openPath")
    d.close()
    d.close()
    val loaded = LicDongle.libraryPath.get
    LicDongle.setLibraryPath(loaded)
    fails(Status.InvalidArgument, "a second library is refused")(LicDongle.setLibraryPath("some/other/library"))

  private def infoAndGenuine(): Unit =
    val d = LicDongle.open()
    check(
      d.info == Info(1, 0, 2, 3, 4, true, true, 1024 * 1024, 1000000, false, true, false),
      s"info: ${d.info}"
    )
    check(d.isGenuine, "isGenuine")
    check(d.verifyGenuine() == Verification(true, serial, "2026-08-15"), "verifyGenuine")
    d.close()
    check(!d.isGenuine, "isGenuine fails closed on a closed dongle")

  private def recordsAndWriteRole(): Unit =
    LicDongle.withDongle { d =>
      d.withSession { s =>
        val payload = "license-blob-0123456789"
        fails(Status.AuthRequired, "write without the write role")(s.write("lic", payload))
        fails(Status.AuthRequired, "erase without the write role")(s.erase("lic"))
        fails(Status.AuthRequired, "eraseAll without the write role")(s.eraseAll())
        fails(Status.AuthRequired, "increment without the write role")(s.incrementCounter(0))
        fails(Status.NotGenuine, "a wrong write key")(s.authorizeWrite(Array[Byte](0x30, 0x00)))

        s.authorizeWrite(factoryKey)
        s.write("lic", payload)
        check(s.readString("lic") == payload, "write and read text")
        s.write("cfg", utf8("cfgdata"))
        val rs = s.records.sortBy(_.name)
        check(rs.map(_.name) == Vector("cfg", "lic"), "records")
        check(rs(1).size == payload.length, "record size")
        check(same(s.read("cfg"), utf8("cfgdata")), "read bytes")
        fails(Status.NotFound, "read a missing record")(s.read("nope"))
        fails(Status.NotFound, "erase a missing record")(s.erase("nope"))
        throwsA[IllegalArgumentException]("an empty name is refused for read")(s.read(""))
        throwsA[IllegalArgumentException]("an empty name is refused for erase")(s.erase(""))
        check(s.records.length == 2, "an empty name erased nothing")
        s.erase("cfg")
        check(s.records.map(_.name) == Vector("lic"), "erase one record")

        s.write("empty", Array.emptyByteArray)
        check(s.read("empty").isEmpty, "an empty record")
        s.write("empty", "")
        check(s.read("empty").isEmpty, "an empty text record")

        val big = Array.tabulate[Byte](3000)(i => (5 + 31 * i).toByte)
        val writes = ArrayBuffer.empty[(Long, Long)]
        val reads = ArrayBuffer.empty[(Long, Long)]
        s.write("big", big, (done, total) => { writes += ((done, total)); true })
        check(writes.lastOption.contains((3000L, 3000L)), "write progress")
        check(same(s.read("big", (done, total) => { reads += ((done, total)); true }), big), "read with progress")
        check(reads.lastOption.contains((3000L, 3000L)), "read progress")
        fails(Status.Cancelled, "a cancelled read")(s.read("big", (_, _) => false))
        fails(Status.Cancelled, "a cancelled write")(s.write("big2", big, (_, _) => false))
        check(same(s.read("big"), big), "the dongle is usable after a cancel")

        s.eraseAll()
        check(s.records.isEmpty, "eraseAll")
      }
    }

  private def counters(): Unit =
    LicDongle.withDongle { d =>
      d.withSession { s =>
        s.authorizeWrite(factoryKey)
        val before = s.readCounter(0)
        check(s.incrementCounter(0) == before + 1, "incrementCounter")
        check(s.readCounter(0) == before + 1, "readCounter after an increment")
        check(s.readCounter(1) == 0, "a fresh counter")
        fails(Status.Range, "read an unknown counter")(s.readCounter(7))
        fails(Status.Range, "increment an unknown counter")(s.incrementCounter(7))
      }
    }

  private def appCrypto(): Unit =
    LicDongle.withDongle { d =>
      d.withSession { s =>
        val secret = Array.tabulate[Byte](100)(i => ((7 + 3 * i) % 256).toByte)
        for (scope, code) <- Seq(Scope.Device -> 0, Scope.Developer -> 1) do
          val blob = s.appEncrypt(scope, secret)
          check(blob.length > secret.length, s"$scope envelope size")
          check(blob(0) == code, s"$scope: the envelope names its scope")
          check(same(s.appDecrypt(blob), secret), s"$scope round trip")
          val tampered = blob.clone()
          tampered(tampered.length - 1) = (tampered.last ^ 1).toByte
          fails(Status.TagMismatch, s"$scope: altered data")(s.appDecrypt(tampered))
        check(String(s.appDecrypt(s.appEncrypt(Scope.Developer, "the data")), UTF_8) == "the data", "text")
        check(s.appDecrypt(s.appEncrypt(Scope.Device, Array.emptyByteArray)).isEmpty, "empty data")
      }
    }

  private def writeKeyRotation(): Unit =
    LicDongle.withDongle { d =>
      d.withSession { s =>
        fails(Status.AuthRequired, "rotate without the write role")(s.rotateWriteKey(replacementKey))
        s.authorizeWrite(factoryKey)
        s.rotateWriteKey(replacementKey)
        s.write("lic", "still-writable")
      }
      check(d.info.writeAuthRotated, "writeAuthRotated")
      d.withSession { s =>
        fails(Status.NotGenuine, "the factory key no longer elevates")(s.authorizeWrite(factoryKey))
        s.authorizeWrite(replacementKey)
        s.write("lic", "new-key-writes")
        check(s.readString("lic") == "new-key-writes", "the new key writes")
      }
    }

  private def sessionLifetime(): Unit =
    val d = LicDongle.open()
    var kept: Session = null
    check(d.withSession { s => kept = s; 42 } == 42, "withSession returns the value of its body")
    check(kept.isClosed, "and closes the session")
    val message =
      try d.withSession { s => kept = s; throw RuntimeException("inside") }
      catch case NonFatal(e) => e.getMessage
    check(message == "inside", "an exception inside withSession propagates")
    check(kept.isClosed, "and the session is closed after it")
    val stale = d.openSession()
    val s = d.openSession()
    s.close()
    fails(Status.SessionExpired, "a new session ends the one before it")(stale.records)
    stale.close()
    s.close()
    throwsA[IllegalStateException]("a closed session refuses calls")(s.readCounter(0))
    val orphan = d.openSession()
    d.close()
    throwsA[IllegalStateException]("a session ends with its dongle")(orphan.records)
    orphan.close()
    d.close()

  // The trust root belongs to the one context of the process, so its test runs last.
  private def trustRoot(): Unit =
    LicDongle.withDongle { d =>
      fails(Status.CertificateInvalid, "a malformed trust root")(LicDongle.setTrustRoot(Array[Byte](0x02, 0x01, 0x00)))
      val root = Array.fill[Byte](132)(0xab.toByte)
      root(0) = 0x30
      root(1) = 0x82.toByte
      root(2) = 0x01
      root(3) = 0x00
      LicDongle.setTrustRoot(root)
      fails(Status.CertificateInvalid, "verify against another root")(d.verifyGenuine())
      check(!d.isGenuine, "isGenuine against another root")
      for k <- 4 until 132 do root(k) = 0x01
      LicDongle.setTrustRoot(root)
      check(d.isGenuine, "isGenuine against the stand-in's root")
    }

  def main(args: Array[String]): Unit =
    LicDongle.setLibraryPath(
      Option(System.getenv("KEYNUB_LICDONGLE_LIBRARY")).filter(_.nonEmpty).getOrElse(buildStandIn())
    )
    val tests = Seq(
      devicesAndOpen _,
      infoAndGenuine _,
      recordsAndWriteRole _,
      counters _,
      appCrypto _,
      writeKeyRotation _,
      sessionLifetime _,
      trustRoot _
    )
    for t <- tests do
      try t()
      catch case NonFatal(e) => check(false, s"unexpected ${e.getClass.getSimpleName}: ${e.getMessage}")
    if failures.isEmpty then
      println(
        s"keynub-licdongle-scala: every call passed against the ABI stand-in ($checks checks, Java ${Runtime.version()})"
      )
    else
      println(s"keynub-licdongle-scala: ${failures.length} of $checks check(s) failed")
      System.exit(1)
