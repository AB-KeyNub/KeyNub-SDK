// KeyNub SDK - Groovy sample: verify a dongle and read what it holds.
//
//     groovy samples/groovy/VerifyAndRead.groovy      (from the repository root)
//
// Groovy 4 or later on Java 17 or later, over the Java binding
// com.keynub:keynub-licdongle from Maven Central. Run from a clone, the library
// is found in natives/<platform>/. Targets real hardware: with no dongle
// attached it prints guidance and exits 0.
@Grab('com.keynub:keynub-licdongle:1.1.1')
import com.keynub.licdongle.Dongle
import com.keynub.licdongle.LicenseDongleContext
import com.keynub.licdongle.LicenseDongleException
import com.keynub.licdongle.Scope
import com.keynub.licdongle.Session

import java.nio.charset.StandardCharsets

// The Java binding loads the library named by the system property
// keynub.licdongle.library; in a clone it sits in natives/<platform>/.
static String libraryInClone() {
    String os = System.getProperty('os.name').toLowerCase()
    String arch = System.getProperty('os.arch').toLowerCase()
    String cpu = arch in ['amd64', 'x86_64'] ? 'x64' : arch in ['aarch64', 'arm64'] ? 'arm64' : 'x86'
    def (folder, file) = os.startsWith('windows') ? ["win-$cpu", 'keynub_licdongle.dll'] :
            (os.startsWith('mac') ? ["osx-$cpu", 'libkeynub_licdongle.dylib'] : ["linux-$cpu", 'libkeynub_licdongle.so'])
    for (File dir = new File(System.getProperty('user.dir')).absoluteFile; dir != null; dir = dir.parentFile) {
        File candidate = new File(dir, "natives/$folder/$file")
        if (candidate.isFile()) return candidate.path
    }
    return null
}

String chosen = System.getenv('KEYNUB_LICDONGLE_LIBRARY') ?: libraryInClone()
if (chosen && !System.getProperty('keynub.licdongle.library')) {
    System.setProperty('keynub.licdongle.library', chosen)
}

static void report(Dongle dongle) {
    def i = dongle.info
    println "Protocol v${i.protocolMajor()}.${i.protocolMinor()}, firmware v${i.firmwareMajor()}." +
            "${i.firmwareMinor()}.${i.firmwarePatch()}, ${i.dataFree()} of ${i.dataCapacity()} bytes free."
    // The only trace a firmware hang leaves behind. Worth reporting to support.
    if (i.watchdogReboot()) println "WARNING: this dongle's previous boot ended in a watchdog reset."
    def g = dongle.verifyGenuine()
    println "Genuine: yes (serial ${g.serial()}, provisioned ${g.provisionedDate()})"
}

static void readRecords(Session session) {
    def records = session.listRecords()
    println "${records.size()} record(s) on the dongle:"
    records.each { r -> println String.format('  %-16s %d bytes', r.name(), r.size()) }
    // A missing record is a normal state, not an error.
    if (records.any { it.name() == 'license' }) {
        println "Read ${session.readRecord('license').length} bytes from the license record."
    }
}

// The part that protects something. At licence-issue time you would call
// appEncrypt once, with a developer dongle, and ship only the sealed data; the
// program then cannot proceed without a dongle, because it holds no other copy.
// Scope.DEVELOPER lets any dongle you have issued decrypt it, so one file serves
// every customer; Scope.DEVICE locks it to one dongle.
static void protectSomething(Session session) {
    String needed = 'the data this program cannot run without'
    byte[] sealedData = session.appEncrypt(Scope.DEVELOPER, needed.getBytes(StandardCharsets.UTF_8))
    String recovered = new String(session.appDecrypt(sealedData), StandardCharsets.UTF_8)
    String outcome = recovered == needed ? 'recovered intact' : 'MISMATCH'
    println "App-crypto round trip: ${needed.length()} bytes -> ${sealedData.length} sealed -> $outcome"
}

try {
    println "KeyNub library v${LicenseDongleContext.libraryVersion()}"
    new LicenseDongleContext().withCloseable { context ->
        if (context.enumerate().isEmpty()) {
            println 'Connect a KeyNub dongle and re-run.'
            return
        }
        context.open().withCloseable { Dongle dongle ->   // the first dongle, or open(serial)
            report(dongle)
            dongle.openSession().withCloseable { Session session ->   // closed on every exit path
                readRecords(session)
                protectSomething(session)
            }
        }
    }
} catch (LicenseDongleException e) {
    println "KeyNub error: ${e.message}"
    System.exit(1)
}
