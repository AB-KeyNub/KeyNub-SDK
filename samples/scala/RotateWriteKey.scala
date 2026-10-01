// KeyNub SDK - Scala sample: take ownership of a new dongle.
//
// A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
// so that from the next session onward only your key can write records, erase
// them or increment counters. Run it once per dongle, when it arrives.
//
// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//
//     openssl ecparam -name prime256v1 -genkey -noout |
//       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//
//     scala-cli run samples/scala/RotateWriteKey.scala -- keys/keynub-shipping-writeauth.key.der my-key.der
//
// Scala 3.3 or later on Java 17 or later. Targets real hardware: with no dongle
// attached it prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It
// cannot be recovered from the dongle, and a unit rotated to a key you have
// lost has to come back to be re-provisioned.

//> using scala 3.3
//> using dep com.keynub::keynub-licdongle-scala:1.1.1

import keynub.licdongle.*

import java.io.IOException
import java.nio.file.{Files, Path}

@main def rotateWriteKey(args: String*): Unit =
  if args.length != 2 then
    println("usage: RotateWriteKey <current-key.der> <new-key.der>")
    sys.exit(2)
  try
    val current = Files.readAllBytes(Path.of(args(0)))
    val replacement = Files.readAllBytes(Path.of(args(1)))
    if LicDongle.devices.isEmpty then println("Connect a KeyNub dongle and re-run.")
    else
      LicDongle.withDongle { dongle =>
        println(s"Dongle ${dongle.serial}")
        if dongle.info.writeAuthRotated then
          println("This dongle's write key has already been rotated away from the factory one.")
        dongle.withSession { session =>
          session.authorizeWrite(current) // the key the dongle accepts today
          session.rotateWriteKey(replacement) // from the next session: only the new one
        }
        println(s"Write key rotated: ${if dongle.info.writeAuthRotated then "yes" else "no"}")
      }
  catch
    case e: LicDongleError =>
      println(s"KeyNub error: ${e.getMessage}")
      sys.exit(1)
    case e: IOException =>
      println(s"KeyNub error: ${e.getMessage}")
      sys.exit(1)
