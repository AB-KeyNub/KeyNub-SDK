// KeyNub SDK - Kotlin sample: take ownership of a new dongle.
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
//     gradle rotateWriteKey --args="../../keys/keynub-shipping-writeauth.key.der my-key.der"
//
// Kotlin on Java 17 or later. Targets real hardware: with no dongle attached it
// prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It
// cannot be recovered from the dongle, and a unit rotated to a key you have
// lost has to come back to be re-provisioned.
import com.keynub.licdongle.kotlin.LicDongle
import com.keynub.licdongle.kotlin.LicDongleException
import com.keynub.licdongle.kotlin.LibraryException
import java.io.File
import java.io.IOException
import kotlin.system.exitProcess

fun main(args: Array<String>) {
    if (args.size != 2) {
        println("usage: rotateWriteKey <current-key.der> <new-key.der>")
        exitProcess(2)
    }
    try {
        val current = File(args[0]).readBytes()
        val replacement = File(args[1]).readBytes()
        if (LicDongle.devices().isEmpty()) {
            println("Connect a KeyNub dongle and re-run.")
            return
        }
        LicDongle.withDongle { dongle ->
            println("Dongle ${dongle.serial}")
            if (dongle.info().writeAuthRotated) {
                println("This dongle's write key has already been rotated away from the factory one.")
            }
            dongle.withSession { session ->
                session.authorizeWrite(current) // the key the dongle accepts today
                session.rotateWriteKey(replacement) // from the next session: only the new one
            }
            println("Write key rotated: ${if (dongle.info().writeAuthRotated) "yes" else "no"}")
        }
    } catch (e: LicDongleException) {
        println("KeyNub error: ${e.message}")
        exitProcess(1)
    } catch (e: LibraryException) {
        println("KeyNub error: ${e.message}")
        exitProcess(1)
    } catch (e: IOException) {
        println("KeyNub error: ${e.message}")
        exitProcess(1)
    }
}
