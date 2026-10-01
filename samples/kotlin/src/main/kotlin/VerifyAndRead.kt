// KeyNub SDK - Kotlin sample: verify a dongle and read what it holds.
//
//     gradle verifyAndRead      (in samples/kotlin)
//
// Kotlin on Java 17 or later. Run from a clone, the library is found in
// natives/<platform>/. Targets real hardware: with no dongle attached it prints
// guidance and exits 0.
import com.keynub.licdongle.kotlin.Dongle
import com.keynub.licdongle.kotlin.LicDongle
import com.keynub.licdongle.kotlin.LicDongleException
import com.keynub.licdongle.kotlin.LibraryException
import com.keynub.licdongle.kotlin.Scope
import com.keynub.licdongle.kotlin.Session
import kotlin.system.exitProcess

private fun report(dongle: Dongle) {
    val i = dongle.info()
    println(
        "Protocol v${i.protocolMajor}.${i.protocolMinor}, firmware v${i.firmwareMajor}.${i.firmwareMinor}." +
            "${i.firmwarePatch}, ${i.dataFree} of ${i.dataCapacity} bytes free.",
    )
    // The only trace a firmware hang leaves behind. Worth reporting to support.
    if (i.watchdogReboot) println("WARNING: this dongle's previous boot ended in a watchdog reset.")
    val g = dongle.verifyGenuine()
    println("Genuine: yes (serial ${g.serial}, provisioned ${g.provisionedDate})")
}

private fun readRecords(session: Session) {
    val records = session.records()
    println("${records.size} record(s) on the dongle:")
    for (r in records) println("  %-16s %d bytes".format(r.name, r.size))
    // A missing record is a normal state, not an error.
    if (records.any { it.name == "license" }) {
        println("Read ${session.read("license").size} bytes from the license record.")
    }
}

// The part that protects something. At licence-issue time you would call
// appEncrypt once, with a developer dongle, and ship only the sealed data; the
// program then cannot proceed without a dongle, because it holds no other copy.
// Scope.Developer lets any dongle you have issued decrypt it, so one file serves
// every customer; Scope.Device locks it to one dongle.
private fun protectSomething(session: Session) {
    val needed = "the data this program cannot run without"
    val sealedData = session.appEncrypt(Scope.Developer, needed)
    val recovered = session.appDecrypt(sealedData).decodeToString()
    val outcome = if (recovered == needed) "recovered intact" else "MISMATCH"
    println("App-crypto round trip: ${needed.length} bytes -> ${sealedData.size} sealed -> $outcome")
}

fun main() {
    try {
        println("KeyNub library v${LicDongle.libraryVersion()}")
        if (LicDongle.devices().isEmpty()) {
            println("Connect a KeyNub dongle and re-run.")
            return
        }
        LicDongle.withDongle { dongle -> // the first dongle, or withDongle(serial) { ... }
            report(dongle)
            dongle.withSession { session -> // closed on every exit path
                readRecords(session)
                protectSomething(session)
            }
        }
    } catch (e: LicDongleException) {
        println("KeyNub error: ${e.message}")
        exitProcess(1)
    } catch (e: LibraryException) {
        println("KeyNub error: ${e.message}")
        exitProcess(1)
    }
}
