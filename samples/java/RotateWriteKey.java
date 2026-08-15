import com.keynub.licdongle.Dongle;
import com.keynub.licdongle.LicenseDongleContext;
import com.keynub.licdongle.LicenseDongleException;
import com.keynub.licdongle.Session;

import java.nio.file.Files;
import java.nio.file.Path;

/**
 * KeyNub SDK - Java sample: take ownership of a new dongle.
 *
 * A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so that from the
 * next session onward only your key can write records, erase them or increment counters. Run it
 * once per dongle, when it arrives.
 *
 * Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
 *   openssl ecparam -name prime256v1 -genkey -noout |
 *     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
 *
 * Run with the binding + JNA on the classpath, e.g. (from bindings/java after `mvn package`):
 *   javac -cp "target/keynub-licdongle-1.0.0.jar;&lt;jna.jar&gt;" ../../samples/java/RotateWriteKey.java -d /tmp/s
 *   java  -cp "/tmp/s;target/keynub-licdongle-1.0.0.jar;&lt;jna.jar&gt;" RotateWriteKey ../../keys/keynub-shipping-writeauth.key.der my-key.der
 *
 * Targets real hardware; prints guidance and exits 0 when no dongle is attached.
 *
 * The replacement key is worth what your licence-signing key is worth. It cannot be recovered
 * from the dongle, and a unit rotated to a key you have lost has to come back to be
 * re-provisioned.
 */
public final class RotateWriteKey {

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("usage: RotateWriteKey <current-key.der> <new-key.der>");
            System.exit(2);
        }
        byte[] current = Files.readAllBytes(Path.of(args[0]));
        byte[] replacement = Files.readAllBytes(Path.of(args[1]));

        try (LicenseDongleContext ctx = new LicenseDongleContext()) {
            if (ctx.enumerate().isEmpty()) {
                System.out.println("Connect a KeyNub dongle and re-run.");
                return;
            }

            try (Dongle dongle = ctx.open()) {
                System.out.println("dongle " + dongle.getSerial());

                try (Session session = dongle.openSession()) {
                    session.authorizeWrite(current);
                    session.rotateWriteKey(replacement);
                    System.out.println("rotated: this dongle now answers only to your key");
                }

                // A fresh session is the only place the change is observable: the session
                // above keeps the role it was already granted.
                try (Session session = dongle.openSession()) {
                    try {
                        session.authorizeWrite(current);
                        System.err.println("WARNING: the old key still works -- do not ship this unit");
                        System.exit(1);
                    } catch (LicenseDongleException expected) {
                        System.out.println("confirmed: the old key no longer elevates");
                    }
                    session.authorizeWrite(replacement);
                    System.out.println("confirmed: your key elevates");
                }
            }
        } catch (LicenseDongleException err) {
            System.err.println("KeyNub error: " + err.getMessage());
            System.exit(1);
        }

        System.out.println();
        System.out.println("Keep the replacement key safe. Every future write to this dongle needs it.");
    }

    private RotateWriteKey() {}
}
