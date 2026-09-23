"""Every call of the binding against a stand-in for the C ABI
(bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory),
compiled into a shared library with a C compiler from the path (cc, gcc, clang,
zig cc or cl). KEYNUB_LICDONGLE_LIBRARY naming an already compiled stand-in
skips the build; KEYNUB_SDK_ROOT names the SDK sources when the test does not
run inside a clone. Exit code 0 when every check passed.

    python tests/test_standin.py        (from bindings/python)
"""

import importlib
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

_HERE = pathlib.Path(__file__).resolve()
_BINDING = _HERE.parents[1]

SERIAL = "04A1B2C3D4E5F6"
FACTORY_KEY = bytes([0x30, 0x10, 0x01, 0x02, 0x03])
REPLACEMENT_KEY = bytes([0x30, 0x11, 0x09, 0x08, 0x07, 0x06])

kn = None  # the binding, loaded against the stand-in by setUpModule


# ---- the stand-in -----------------------------------------------------------

def _sdk_root() -> pathlib.Path:
    given = os.environ.get("KEYNUB_SDK_ROOT")
    if given:
        return pathlib.Path(given)
    for folder in [pathlib.Path.cwd(), *pathlib.Path.cwd().parents]:
        if (folder / "bindings" / "flat" / "licd_flat.c").is_file():
            return folder
    raise RuntimeError("the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT")


def _build_stand_in() -> str:
    root = _sdk_root()
    windows = sys.platform == "win32"
    tmp = tempfile.gettempdir()
    # Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf
    # name even for an absolute-path dlopen, and a build tree on that path holds
    # the real library under that name.
    output = os.path.join(tmp, "keynub_licdongle_standin.dll" if windows
                          else "libkeynub_licdongle_standin.so")
    include = root / "core" / "include"
    if not (include / "licdongle.h").is_file():
        include = root / "include"
    source = str(root / "bindings" / "julia" / "test" / "stub" / "licd_stub.c")
    gcc = ["-shared", "-O1", "-DLICD_BUILD_SHARED", f"-I{include}", "-o", output, source]
    if not windows:
        gcc.append("-fPIC")
    cl = ["/nologo", "/LD", "/O1", "/DLICD_BUILD_SHARED", f"/I{include}", f"/Fe:{output}", source]
    for command in (["cc", *gcc], ["gcc", *gcc], ["clang", *gcc], ["zig", "cc", *gcc], ["cl", *cl]):
        try:
            # In the temporary folder, where the compilers leave their byproducts.
            done = subprocess.run(command, cwd=tmp, capture_output=True)
        except OSError:
            continue
        if done.returncode == 0 and os.path.isfile(output):
            return output
    raise RuntimeError("the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path")


def _load_binding():
    """The binding, loaded against the stand-in.

    The library is chosen when the binding is first imported. When another suite
    in this process has already imported it, this loads a separate copy and
    leaves that suite's copy in place.
    """
    name = "keynub_licdongle"
    loaded = {k: v for k, v in sys.modules.items() if k == name or k.startswith(name + ".")}
    given = os.environ.get("KEYNUB_LICDONGLE_LIBRARY")
    library = given if given and not loaded else _build_stand_in()
    for key in loaded:
        del sys.modules[key]
    if str(_BINDING) not in sys.path:
        sys.path.insert(0, str(_BINDING))
    os.environ["KEYNUB_LICDONGLE_LIBRARY"] = library
    try:
        binding = importlib.import_module(name)
    finally:
        if given is None:
            del os.environ["KEYNUB_LICDONGLE_LIBRARY"]
        else:
            os.environ["KEYNUB_LICDONGLE_LIBRARY"] = given
        if loaded:
            for key in [k for k in sys.modules if k == name or k.startswith(name + ".")]:
                del sys.modules[key]
            sys.modules.update(loaded)
    return binding


def setUpModule():
    global kn
    kn = _load_binding()


# ---- the checks --------------------------------------------------------------

class StandIn(unittest.TestCase):
    def setUp(self):
        self.ctx = kn.LicenseDongleContext()
        self.dongle = self.ctx.open()

    def tearDown(self):
        self.dongle.close()
        self.ctx.close()

    def assertStatus(self, status, error_type, action):
        with self.assertRaises(error_type) as caught:
            action()
        self.assertEqual(caught.exception.status, status)
        return caught.exception

    def test_library_version(self):
        self.assertEqual(kn.LicenseDongleContext.library_version(), (9, 8, 7))

    def test_status_text(self):
        self.assertIs(kn.Status(-2), kn.Status.NO_DEVICE)
        err = self.assertStatus(kn.Status.NO_DEVICE, kn.DeviceNotFoundError,
                                lambda: self.ctx.open("nope"))
        self.assertEqual(str(err), "licd_open: no device - no dongle with that serial")
        self.assertEqual(err.detail, "no dongle with that serial")
        self.assertEqual(self.ctx.last_error_detail, "no dongle with that serial")

    def test_devices(self):
        self.assertEqual(self.ctx.enumerate(), [kn.DeviceInfo(SERIAL, "stub:0", 0x1234, 0xABCD)])
        self.assertStatus(kn.Status.NO_DEVICE, kn.DeviceNotFoundError, lambda: self.ctx.open("nope"))
        self.assertStatus(kn.Status.NO_DEVICE, kn.DeviceNotFoundError,
                          lambda: self.ctx.open_path("stub:9"))
        with self.ctx.open(SERIAL) as by_serial:
            self.assertEqual(by_serial.get_serial(), SERIAL)
        with self.ctx.open_path("stub:0") as by_path:
            self.assertEqual(by_path.get_serial(), SERIAL)

    def test_info(self):
        self.assertEqual(self.dongle.get_serial(), SERIAL)
        i = self.dongle.get_info()
        self.assertEqual(i.protocol_version, (1, 0))
        self.assertEqual(i.firmware_version, (2, 3, 4))
        self.assertIs(i.se_ready, True)
        self.assertIs(i.provisioned, True)
        self.assertIs(i.isolated, True)
        self.assertIs(i.watchdog_reboot, False)
        self.assertIs(i.writeauth_rotated, False)
        self.assertEqual(i.data_capacity, 1024 * 1024)
        self.assertEqual(i.data_free, 1_000_000)

    def test_genuine_and_trust_root(self):
        self.assertEqual(self.dongle.verify_genuine(), kn.GenuineResult(True, SERIAL, "2026-08-15"))
        self.assertStatus(kn.Status.CERTIFICATE_INVALID, kn.CertificateInvalidError,
                          lambda: self.ctx.set_trust_root(b"\x02\x01\x00"))
        self.assertStatus(kn.Status.INVALID_ARGUMENT, kn.LicenseDongleError,
                          lambda: self.ctx.set_trust_root(b""))
        self.ctx.set_trust_root(b"\x30\x82\x01\x00" + b"\xAB" * 128)
        self.assertStatus(kn.Status.CERTIFICATE_INVALID, kn.CertificateInvalidError,
                          self.dongle.verify_genuine)
        self.ctx.set_trust_root(b"\x30\x82\x01\x00" + b"\x01" * 128)
        self.assertTrue(self.dongle.verify_genuine().is_genuine)

    def test_session_required(self):
        # A second Session object ends the dongle's session under the first one.
        first = self.dongle.open_session()
        second = self.dongle.open_session()
        second.close()
        self.assertStatus(kn.Status.SESSION_EXPIRED, kn.SessionExpiredError, first.list_records)
        first.close()
        self.assertTrue(first.is_closed)
        with self.assertRaises(RuntimeError):
            first.list_records()
        first.close()  # idempotent

    def test_write_role(self):
        with self.dongle.open_session() as s:
            self.assertStatus(kn.Status.AUTH_REQUIRED, kn.WriteAuthorizationRequiredError,
                              lambda: s.write_record("lic", b"x"))
            self.assertStatus(kn.Status.AUTH_REQUIRED, kn.WriteAuthorizationRequiredError,
                              lambda: s.increment_counter(0))
            self.assertStatus(kn.Status.NOT_GENUINE, kn.NotGenuineError,
                              lambda: s.authorize_write(b"\x30\x00"))
            s.authorize_write(FACTORY_KEY)
            s.write_record("lic", b"x")

    def test_records(self):
        with self.dongle.open_session() as s:
            s.authorize_write(FACTORY_KEY)
            payload = b"license-blob-0123456789"
            s.write_record("lic", payload)
            self.assertEqual(s.read_record("lic"), payload)
            s.write_record("cfg", b"cfgdata")
            recs = s.list_records()
            self.assertEqual(sorted(r.name for r in recs), ["cfg", "lic"])
            self.assertIn(kn.RecordInfo("lic", len(payload)), recs)
            self.assertEqual(s.read_record("cfg"), b"cfgdata")
            self.assertStatus(kn.Status.NOT_FOUND, kn.RecordNotFoundError, lambda: s.read_record("nope"))
            self.assertStatus(kn.Status.NOT_FOUND, kn.RecordNotFoundError, lambda: s.erase_record("nope"))
            with self.assertRaises(ValueError):
                s.erase_record("")
            with self.assertRaises(ValueError):
                s.read_record("")
            self.assertEqual(len(s.list_records()), 2)
            s.erase_record("cfg")
            self.assertEqual([r.name for r in s.list_records()], ["lic"])
            s.write_record("empty", b"")
            self.assertEqual(s.read_record("empty"), b"")
            big = bytes((k * 31 + 5) & 0xFF for k in range(2000))
            s.write_record("big", big)
            self.assertEqual(s.read_record("big"), big)
            s.erase_all_records()
            self.assertEqual(s.list_records(), [])

    def test_progress(self):
        with self.dongle.open_session() as s:
            s.authorize_write(FACTORY_KEY)
            big = bytes((k * 31 + 5) & 0xFF for k in range(2000))
            writes = []
            s.write_record("big", big, progress=writes.append)
            self.assertEqual(writes[-1], kn.TransferProgress(2000, 2000))
            reads = []
            self.assertEqual(s.read_record("big", progress=reads.append), big)
            self.assertEqual(reads[-1], kn.TransferProgress(2000, 2000))
            self.assertEqual(reads[-1].fraction, 1.0)
            with self.assertRaises(kn.OperationCancelledError):
                s.read_record("big", progress=lambda p: False)
            with self.assertRaises(kn.OperationCancelledError):
                s.write_record("big", big, progress=lambda p: False)

            def explode(_):
                raise ValueError("callback exploded")

            with self.assertRaises(kn.OperationCancelledError):
                s.read_record("big", progress=explode)
            self.assertEqual(s.read_record("big", progress=lambda p: None), big)
            s.write_record("empty", b"")
            empty = []
            self.assertEqual(s.read_record("empty", progress=empty.append), b"")
            self.assertEqual(empty, [kn.TransferProgress(0, 0)])

    def test_counters(self):
        with self.dongle.open_session() as s:
            s.authorize_write(FACTORY_KEY)
            before = s.read_counter(0)
            self.assertEqual(s.increment_counter(0), before + 1)
            self.assertEqual(s.read_counter(0), before + 1)
            self.assertEqual(s.read_counter(1), 0)
            self.assertStatus(kn.Status.RANGE, kn.LicenseDongleError, lambda: s.read_counter(7))
            self.assertStatus(kn.Status.RANGE, kn.LicenseDongleError, lambda: s.increment_counter(7))

    def test_app_crypto(self):
        with self.dongle.open_session() as s:
            secret = bytes((3 * k + 7) % 256 for k in range(100))
            for scope in (kn.Scope.DEVICE, kn.Scope.DEVELOPER):
                with self.subTest(scope=scope.name):
                    blob = s.app_encrypt(scope, secret)
                    self.assertGreater(len(blob), len(secret))
                    self.assertEqual(blob[0], int(scope))
                    self.assertEqual(s.app_decrypt(blob), secret)
                    tampered = blob[:-1] + bytes([blob[-1] ^ 1])
                    self.assertStatus(kn.Status.TAG_MISMATCH, kn.LicenseDongleError,
                                      lambda: s.app_decrypt(tampered))
            self.assertEqual(s.app_decrypt(s.app_encrypt(kn.Scope.DEVICE, b"")), b"")
            self.assertStatus(kn.Status.INVALID_ARGUMENT, kn.LicenseDongleError,
                              lambda: s.app_decrypt(b"\x00\x01"))

    def test_rotation(self):
        with self.dongle.open_session() as s:
            self.assertStatus(kn.Status.AUTH_REQUIRED, kn.WriteAuthorizationRequiredError,
                              lambda: s.rotate_write_key(REPLACEMENT_KEY))
            s.authorize_write(FACTORY_KEY)
            s.rotate_write_key(REPLACEMENT_KEY)
            s.write_record("lic", b"still-writable")
        self.assertIs(self.dongle.get_info().writeauth_rotated, True)
        with self.dongle.open_session() as s:
            self.assertStatus(kn.Status.NOT_GENUINE, kn.NotGenuineError,
                              lambda: s.authorize_write(FACTORY_KEY))
            s.authorize_write(REPLACEMENT_KEY)
            s.write_record("lic", b"new-key-writes")
            self.assertEqual(s.read_record("lic"), b"new-key-writes")

    def test_log_callback(self):
        lines = []
        self.ctx.set_log_callback(lambda level, message: lines.append((level, message)))
        self.dongle.get_info()
        self.ctx.set_log_callback(None)
        self.assertEqual(self.dongle.get_serial(), SERIAL)

    def test_close(self):
        self.dongle.close()
        self.dongle.close()  # idempotent
        with self.assertRaises(RuntimeError):
            self.dongle.get_serial()
        self.ctx.close()
        self.ctx.close()  # idempotent
        with self.assertRaises(RuntimeError):
            self.ctx.enumerate()

    def test_context_managers(self):
        with kn.LicenseDongleContext() as ctx:
            with ctx.open() as dongle:
                with dongle.open_session() as s:
                    # list_records needs a session, so an answer proves it is open.
                    self.assertEqual(s.list_records(), [])
                self.assertTrue(s.is_closed)
            with self.assertRaises(RuntimeError):
                dongle.get_serial()
        with self.assertRaises(RuntimeError):
            ctx.enumerate()


if __name__ == "__main__":
    passed = unittest.main(exit=False).result.wasSuccessful()
    if passed:
        print("keynub-licdongle: every call passed against the ABI stand-in")
    sys.exit(0 if passed else 1)
