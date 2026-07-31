import com.keynub.licdongle.Dongle;
import com.keynub.licdongle.DongleInfo;
import com.keynub.licdongle.GenuineResult;
import com.keynub.licdongle.LicenseDongleContext;
import com.keynub.licdongle.RecordNotFoundException;
import com.keynub.licdongle.Scope;
import com.keynub.licdongle.Session;

import java.util.Arrays;

/**
 * KeyNub SDK - Java sample: enumerate a dongle, verify authenticity, open an encrypted session,
 * read a "license" record, and round-trip app-data encryption. Targets real hardware; prints
 * guidance and exits 0 when no dongle is attached.
 *
 * Run with the binding + JNA on the classpath, e.g. (from bindings/java after `mvn package`):
 *   javac -cp "target/keynub-licdongle-1.0.0.jar;<jna.jar>" ../../samples/java/VerifyAndRead.java -d /tmp/s
 *   java  -cp "/tmp/s;target/keynub-licdongle-1.0.0.jar;<jna.jar>" VerifyAndRead
 */
public final class VerifyAndRead {

    public static void main(String[] args) {
        System.out.println("KeyNub SDK " + LicenseDongleContext.libraryVersion());

        try (LicenseDongleContext ctx = new LicenseDongleContext()) {
            var devices = ctx.enumerate();
            System.out.println("Dongles found: " + devices.size());
            if (devices.isEmpty()) {
                System.out.println("Connect a KeyNub dongle and re-run.");
                return;
            }

            try (Dongle dongle = ctx.open()) {
                DongleInfo info = dongle.getInfo();
                System.out.printf("protocol %d.%d, firmware %d.%d.%d, capacity %d bytes%n",
                        info.protocolMajor(), info.protocolMinor(),
                        info.firmwareMajor(), info.firmwareMinor(), info.firmwarePatch(),
                        info.dataCapacity());
                System.out.println("serial " + dongle.getSerial());

                GenuineResult id = dongle.verifyGenuine();
                System.out.println("genuine: " + id.genuine() + ", cert serial " + id.serial());
                if (!id.genuine()) {
                    System.exit(2);
                }

                try (Session session = dongle.openSession()) {
                    try {
                        byte[] license = session.readRecord("license");
                        System.out.println("license record: " + license.length + " bytes");
                    } catch (RecordNotFoundException e) {
                        System.out.println("no 'license' record on this dongle");
                    }

                    // App-data envelope encryption: only decryptable with this dongle.
                    byte[] secret = "hello-keynub".getBytes();
                    byte[] packed = session.appEncrypt(Scope.DEVICE, secret);
                    boolean ok = Arrays.equals(session.appDecrypt(packed), secret);
                    System.out.printf("app-crypto round-trip %s (%d plaintext -> %d packed bytes)%n",
                            ok ? "OK" : "FAILED", secret.length, packed.length);
                }
            }
        }
    }
}
