// KeyNub SDK - Groovy sample: take ownership of a new dongle.
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
//     groovy samples/groovy/RotateWriteKey.groovy keys/keynub-shipping-writeauth.key.der my-key.der
//
// Groovy 4 or later on Java 17 or later. Targets real hardware: with no dongle
// attached it prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It
// cannot be recovered from the dongle, and a unit rotated to a key you have
// lost has to come back to be re-provisioned.
@Grab('com.keynub:keynub-licdongle:1.1.1')
import com.keynub.licdongle.Dongle
import com.keynub.licdongle.LicenseDongleContext
import com.keynub.licdongle.LicenseDongleException
import com.keynub.licdongle.Session

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

if (args.length != 2) {
    println 'usage: RotateWriteKey <current-key.der> <new-key.der>'
    System.exit(2)
}

String chosen = System.getenv('KEYNUB_LICDONGLE_LIBRARY') ?: libraryInClone()
if (chosen && !System.getProperty('keynub.licdongle.library')) {
    System.setProperty('keynub.licdongle.library', chosen)
}

try {
    byte[] current = new File(args[0]).bytes
    byte[] replacement = new File(args[1]).bytes
    new LicenseDongleContext().withCloseable { context ->
        if (context.enumerate().isEmpty()) {
            println 'Connect a KeyNub dongle and re-run.'
            return
        }
        context.open().withCloseable { Dongle dongle ->
            println "Dongle ${dongle.serial}"
            if (dongle.info.writeauthRotated()) {
                println "This dongle's write key has already been rotated away from the factory one."
            }
            dongle.openSession().withCloseable { Session session ->
                session.authorizeWrite(current)        // the key the dongle accepts today
                session.rotateWriteKey(replacement)    // from the next session: only the new one
            }
            println "Write key rotated: ${dongle.info.writeauthRotated() ? 'yes' : 'no'}"
        }
    }
} catch (LicenseDongleException | IOException e) {
    println "KeyNub error: ${e.message}"
    System.exit(1)
}
