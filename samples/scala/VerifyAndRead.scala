// KeyNub SDK - Scala sample: verify a dongle and read what it holds.
//
//     scala-cli run samples/scala/VerifyAndRead.scala      (from the repository root)
//
// Scala 3.3 or later on Java 17 or later. Run from a clone, the library is found
// in natives/<platform>/. Targets real hardware: with no dongle attached it
// prints guidance and exits 0.

//> using scala 3.3
//> using dep com.keynub::keynub-licdongle-scala:1.1.1

import keynub.licdongle.*

import java.nio.charset.StandardCharsets.UTF_8

def report(dongle: Dongle): Unit =
  val i = dongle.info
  println(
    f"Protocol v${i.protocolMajor}%d.${i.protocolMinor}%d, firmware v${i.firmwareMajor}%d.${i.firmwareMinor}%d.${i.firmwarePatch}%d, ${i.dataFree}%d of ${i.dataCapacity}%d bytes free."
  )
  // The only trace a firmware hang leaves behind. Worth reporting to support.
  if i.watchdogReboot then println("WARNING: this dongle's previous boot ended in a watchdog reset.")
  val g = dongle.verifyGenuine()
  println(s"Genuine: yes (serial ${g.serial}, provisioned ${g.provisionedDate})")

def readRecords(session: Session): Unit =
  val records = session.records
  println(s"${records.length} record(s) on the dongle:")
  for r <- records do println(f"  ${r.name}%-16s ${r.size}%d bytes")
  // A missing record is a normal state, not an error.
  if records.exists(_.name == "license") then
    println(s"Read ${session.read("license").length} bytes from the license record.")

// The part that protects something. At licence-issue time you would call
// appEncrypt once, with a developer dongle, and ship only the sealed data; the
// program then cannot proceed without a dongle, because it holds no other copy.
// Scope.Developer lets any dongle you have issued decrypt it, so one file serves
// every customer; Scope.Device locks it to one dongle.
def protectSomething(session: Session): Unit =
  val needed = "the data this program cannot run without"
  val sealedData = session.appEncrypt(Scope.Developer, needed)
  val recovered = String(session.appDecrypt(sealedData), UTF_8)
  val outcome = if recovered == needed then "recovered intact" else "MISMATCH"
  println(s"App-crypto round trip: ${needed.length} bytes -> ${sealedData.length} sealed -> $outcome")

@main def verifyAndRead(): Unit =
  try
    println(s"KeyNub library v${LicDongle.libraryVersion}")
    if LicDongle.devices.isEmpty then println("Connect a KeyNub dongle and re-run.")
    else
      LicDongle.withDongle { dongle => // the first dongle, or withDongle(serial) { ... }
        report(dongle)
        dongle.withSession { session => // closed on every exit path
          readRecords(session)
          protectSomething(session)
        }
      }
  catch
    case e: LicDongleError =>
      println(s"KeyNub error: ${e.getMessage}")
      sys.exit(1)
