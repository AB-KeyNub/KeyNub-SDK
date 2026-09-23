package com.keynub.licdongle;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * Every call of the binding against the C ABI stand-in: bindings/julia/test/stub/licd_stub.c, one
 * imaginary dongle held in memory, compiled into a shared library in the temp directory with the
 * first C compiler found of cc, gcc, clang, zig cc and cl, and loaded through
 * {@code keynub.licdongle.library}. KEYNUB_SDK_ROOT names the SDK sources when the test does not
 * run inside a clone. The stand-in keeps records, counters and the write key per opened device, so
 * each test starts from a fresh dongle.
 *
 * <pre>mvn test -Dtest=StandInTest</pre>
 */
class StandInTest {

    private static final String SERIAL = "04A1B2C3D4E5F6";
    private static final byte[] FACTORY_KEY = {0x30, 0x10, 0x01, 0x02, 0x03};
    private static final byte[] REPLACEMENT_KEY = {0x30, 0x11, 0x09, 0x08, 0x07, 0x06};

    @BeforeAll
    static void loadStandIn() throws Exception {
        System.setProperty(LicdLibrary.LIBRARY_PROPERTY, buildStandIn());
    }

    private static byte[] bytes(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }

    private static <T extends LicenseDongleException> T fails(Class<T> type, LicdStatus status, Executable action) {
        T e = assertThrows(type, action);
        assertEquals(status, e.getStatus());
        return e;
    }

    @Test
    void versionDevicesAndOpen() {
        assertEquals("9.8.7", LicenseDongleContext.libraryVersion());
        try (LicenseDongleContext ctx = new LicenseDongleContext()) {
            ctx.setLogCallback((level, message) -> { });
            ctx.setLogCallback(null);

            assertEquals(List.of(new DeviceInfo(SERIAL, "stub:0", 0x1234, 0xABCD)), ctx.enumerate());

            DeviceNotFoundException e = fails(DeviceNotFoundException.class, LicdStatus.NO_DEVICE, () -> ctx.open("nope"));
            assertTrue(e.getMessage().contains("no device"), "the SDK's status text");
            assertEquals("no dongle with that serial", e.getDetail());
            assertEquals("no dongle with that serial", ctx.lastErrorDetail());
            fails(DeviceNotFoundException.class, LicdStatus.NO_DEVICE, () -> ctx.openPath("stub:9"));

            try (Dongle first = ctx.open(); Dongle bySerial = ctx.open(SERIAL); Dongle byPath = ctx.openPath("stub:0")) {
                assertEquals(SERIAL, first.getSerial());
                assertEquals(SERIAL, bySerial.getSerial());
                assertEquals(SERIAL, byPath.getSerial());
            }
        }
    }

    @Test
    void infoAndGenuine() {
        try (LicenseDongleContext ctx = new LicenseDongleContext(); Dongle d = ctx.open()) {
            assertEquals(new DongleInfo(1, 0, 2, 3, 4, true, true, 1024L * 1024L, 1_000_000L, false, true, false),
                    d.getInfo());
            assertEquals(new GenuineResult(true, SERIAL, "2026-08-15"), d.verifyGenuine());
        }
    }

    @Test
    void trustRoot() {
        try (LicenseDongleContext ctx = new LicenseDongleContext(); Dongle d = ctx.open()) {
            fails(CertificateInvalidException.class, LicdStatus.CERTIFICATE_INVALID,
                    () -> ctx.setTrustRoot(new byte[] {0x02, 0x01, 0x00}));
            fails(LicenseDongleException.class, LicdStatus.INVALID_ARGUMENT, () -> ctx.setTrustRoot(new byte[0]));
            assertThrows(IllegalArgumentException.class, () -> ctx.setTrustRoot(null));

            byte[] root = new byte[132];
            root[0] = 0x30;
            root[1] = (byte) 0x82;
            root[2] = 0x01;
            Arrays.fill(root, 4, root.length, (byte) 0xAB);
            ctx.setTrustRoot(root);
            fails(CertificateInvalidException.class, LicdStatus.CERTIFICATE_INVALID, d::verifyGenuine);

            Arrays.fill(root, 4, root.length, (byte) 0x01);
            ctx.setTrustRoot(root);
            assertTrue(d.verifyGenuine().genuine());
        }
    }

    @Test
    void recordsAndWriteRole() {
        try (LicenseDongleContext ctx = new LicenseDongleContext(); Dongle d = ctx.open(); Session s = d.openSession()) {
            byte[] payload = bytes("license-blob-0123456789");
            Class<WriteAuthorizationRequiredException> authRequired = WriteAuthorizationRequiredException.class;
            fails(authRequired, LicdStatus.AUTH_REQUIRED, () -> s.writeRecord("lic", payload));
            fails(authRequired, LicdStatus.AUTH_REQUIRED, () -> s.eraseRecord("lic"));
            fails(authRequired, LicdStatus.AUTH_REQUIRED, s::eraseAllRecords);
            fails(authRequired, LicdStatus.AUTH_REQUIRED, () -> s.incrementCounter(0));
            fails(NotGenuineException.class, LicdStatus.NOT_GENUINE, () -> s.authorizeWrite(new byte[] {0x30, 0x00}));

            s.authorizeWrite(FACTORY_KEY);
            s.writeRecord("lic", payload);
            assertArrayEquals(payload, s.readRecord("lic"));
            s.writeRecord("cfg", bytes("cfgdata"));
            List<RecordInfo> records = s.listRecords();
            assertEquals(List.of("cfg", "lic"), records.stream().map(RecordInfo::name).sorted().collect(Collectors.toList()));
            assertTrue(records.contains(new RecordInfo("lic", payload.length)), "record size");
            assertArrayEquals(bytes("cfgdata"), s.readRecord("cfg"));
            fails(RecordNotFoundException.class, LicdStatus.NOT_FOUND, () -> s.readRecord("nope"));
            fails(RecordNotFoundException.class, LicdStatus.NOT_FOUND, () -> s.eraseRecord("nope"));

            // An empty name is refused by the binding, never passed on as "erase everything".
            assertThrows(IllegalArgumentException.class, () -> s.eraseRecord(""));
            assertThrows(IllegalArgumentException.class, () -> s.readRecord(""));
            assertEquals(2, s.listRecords().size());
            s.eraseRecord("cfg");
            assertEquals(List.of(new RecordInfo("lic", payload.length)), s.listRecords());

            s.writeRecord("empty", new byte[0]);
            assertEquals(0, s.readRecord("empty").length);

            // Bigger than one transfer chunk, with progress and cancellation.
            byte[] big = new byte[3000];
            for (int k = 0; k < big.length; k++) {
                big[k] = (byte) (k * 31 + 5);
            }
            long[] last = new long[1];
            s.writeRecord("big", big, p -> {
                last[0] = p.bytesTransferred();
                return true;
            });
            assertEquals(big.length, last[0], "write progress");
            last[0] = 0;
            assertArrayEquals(big, s.readRecord("big", p -> {
                last[0] = p.bytesTransferred();
                return true;
            }));
            assertEquals(big.length, last[0], "read progress");
            assertThrows(OperationCancelledException.class, () -> s.readRecord("big", p -> false));
            assertThrows(OperationCancelledException.class, () -> s.readRecord("big", p -> {
                throw new IllegalStateException("a failing callback cancels");
            }));
            assertArrayEquals(big, s.readRecord("big"));

            s.eraseAllRecords();
            assertTrue(s.listRecords().isEmpty());
        }
    }

    @Test
    void counters() {
        try (LicenseDongleContext ctx = new LicenseDongleContext(); Dongle d = ctx.open(); Session s = d.openSession()) {
            s.authorizeWrite(FACTORY_KEY);
            long before = s.readCounter(0);
            assertEquals(before + 1, s.incrementCounter(0));
            assertEquals(before + 1, s.readCounter(0));
            assertEquals(0, s.readCounter(1));
            fails(LicenseDongleException.class, LicdStatus.RANGE, () -> s.readCounter(7));
            fails(LicenseDongleException.class, LicdStatus.RANGE, () -> s.incrementCounter(7));
        }
    }

    @Test
    void appEncryptAndDecrypt() {
        try (LicenseDongleContext ctx = new LicenseDongleContext(); Dongle d = ctx.open(); Session s = d.openSession()) {
            byte[] secret = new byte[100];
            for (int k = 0; k < secret.length; k++) {
                secret[k] = (byte) ((3 * k + 7) % 256);
            }
            for (Scope scope : Scope.values()) {
                byte[] blob = s.appEncrypt(scope, secret);
                assertTrue(blob.length > secret.length, "sealed data is longer, " + scope);
                assertEquals(scope.code(), blob[0], "scope byte, " + scope);
                assertArrayEquals(secret, s.appDecrypt(blob), "round trip, " + scope);
                byte[] tampered = blob.clone();
                tampered[tampered.length - 1] ^= 1;
                fails(LicenseDongleException.class, LicdStatus.TAG_MISMATCH, () -> s.appDecrypt(tampered));
            }
            assertEquals(0, s.appDecrypt(s.appEncrypt(Scope.DEVICE, new byte[0])).length);
        }
    }

    @Test
    void writeKeyRotation() {
        try (LicenseDongleContext ctx = new LicenseDongleContext(); Dongle d = ctx.open()) {
            try (Session s = d.openSession()) {
                fails(WriteAuthorizationRequiredException.class, LicdStatus.AUTH_REQUIRED,
                        () -> s.rotateWriteKey(REPLACEMENT_KEY));
                s.authorizeWrite(FACTORY_KEY);
                s.rotateWriteKey(REPLACEMENT_KEY);
                s.writeRecord("lic", bytes("still-writable")); // the session keeps its role
            }
            assertTrue(d.getInfo().writeauthRotated());
            try (Session s = d.openSession()) {
                fails(NotGenuineException.class, LicdStatus.NOT_GENUINE, () -> s.authorizeWrite(FACTORY_KEY));
                s.authorizeWrite(REPLACEMENT_KEY);
                s.writeRecord("lic", bytes("new-key-writes"));
                assertArrayEquals(bytes("new-key-writes"), s.readRecord("lic"));
            }
        }
    }

    @Test
    void sessionAndCloseSemantics() {
        try (LicenseDongleContext ctx = new LicenseDongleContext()) {
            Dongle d = ctx.open();

            // Closing one session ends the device's session, so the other one is refused by the device.
            Session stale = d.openSession();
            Session s = d.openSession();
            assertFalse(s.isClosed());
            s.close();
            fails(SessionExpiredException.class, LicdStatus.SESSION_EXPIRED, stale::listRecords);
            stale.close();

            s.close(); // idempotent
            assertTrue(s.isClosed());
            assertThrows(IllegalStateException.class, () -> s.readCounter(0));

            Session orphan = d.openSession();
            d.close();
            d.close(); // idempotent
            assertThrows(IllegalStateException.class, d::getSerial);
            assertThrows(IllegalStateException.class, orphan::listRecords);
            orphan.close();

            ctx.close();
            ctx.close(); // idempotent
            assertThrows(IllegalStateException.class, ctx::enumerate);
        }
    }

    // ---- the stand-in -----------------------------------------------------------------------

    private static String buildStandIn() throws IOException, InterruptedException {
        Path root = sdkRoot();
        String os = System.getProperty("os.name", "").toLowerCase();
        boolean windows = os.contains("win");
        Path dir = Paths.get(System.getProperty("java.io.tmpdir"), "keynub-standin-java");
        Files.createDirectories(dir);
        // Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf name.
        Path output = dir.resolve(windows ? "keynub_licdongle_standin.dll"
                : os.contains("mac") ? "libkeynub_licdongle_standin.dylib" : "libkeynub_licdongle_standin.so");
        Path include = Files.exists(root.resolve("core/include/licdongle.h"))
                ? root.resolve("core/include") : root.resolve("include");
        String source = root.resolve("bindings/julia/test/stub/licd_stub.c").toString();

        List<String> gccArgs = new ArrayList<>(List.of("-shared", "-O1", "-DLICD_BUILD_SHARED",
                "-I" + include, "-o", output.toString(), source));
        if (!windows) {
            gccArgs.add("-fPIC");
        }
        List<String> clArgs = List.of("/nologo", "/LD", "/O1", "/DLICD_BUILD_SHARED", "/I" + include,
                "/Fe:" + output, source);
        List<List<String>> commands = List.of(
                prepend(gccArgs, "cc"), prepend(gccArgs, "gcc"), prepend(gccArgs, "clang"),
                prepend(gccArgs, "zig", "cc"), prepend(clArgs, "cl"));
        for (List<String> command : commands) {
            try {
                Process p = new ProcessBuilder(command).directory(dir.toFile())
                        .redirectErrorStream(true).redirectOutput(ProcessBuilder.Redirect.DISCARD).start();
                if (p.waitFor() == 0 && Files.exists(output)) {
                    return output.toString();
                }
            } catch (IOException notOnPath) {
                // try the next compiler
            }
        }
        fail("the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path");
        return null;
    }

    private static List<String> prepend(List<String> args, String... program) {
        List<String> command = new ArrayList<>(Arrays.asList(program));
        command.addAll(args);
        return command;
    }

    private static Path sdkRoot() {
        String given = System.getenv("KEYNUB_SDK_ROOT");
        if (given != null && !given.isEmpty()) {
            return Paths.get(given);
        }
        for (File dir = new File("").getAbsoluteFile(); dir != null; dir = dir.getParentFile()) {
            if (new File(dir, "bindings/flat/licd_flat.c").isFile()) {
                return dir.toPath();
            }
        }
        fail("the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT");
        return null;
    }
}
