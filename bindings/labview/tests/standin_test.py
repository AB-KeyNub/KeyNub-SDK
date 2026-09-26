"""Every VI of the LabVIEW library (bindings/labview/keynub_licdongle) against a
stand-in for the flat C API: bindings/flat/licd_flat.c over
bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory,
compiled as keynub_licdongle_flat.dll with a C compiler from the path (cl, gcc,
clang or zig cc). The library is copied into a temporary folder with the
stand-in in natives/win-x64/, where the VIs look for the flat library, and
LabVIEW runs each VI through its ActiveX automation server. Exit code 0 when
every check passed.

Needs 64-bit LabVIEW 2026 or later on Windows, Python 3 with pywin32, and no
other copy of keynub_licdongle.lvlib open in LabVIEW. KEYNUB_SDK_ROOT names the
SDK sources when the test does not run inside a clone.

    python bindings/labview/tests/standin_test.py        (from the repository root)
"""

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

SERIAL = "04A1B2C3D4E5F6"
FACTORY_KEY = bytes([0x30, 0x10, 0x01, 0x02, 0x03])
REPLACEMENT_KEY = bytes([0x30, 0x11, 0x09, 0x08, 0x07, 0x06])

OK, INVALID_ARG, NO_DEVICE, NOT_GENUINE, CERT_INVALID = 0, -1, -2, -7, -8
SESSION_EXPIRED, TAG_MISMATCH, RANGE, NOT_FOUND, AUTH_REQUIRED = -9, -10, -11, -14, -15
SE_READY, PROVISIONED, WATCHDOG_REBOOT, ISOLATED, WRITEAUTH_ROTATED = 1, 2, 4, 8, 16


# ---- the stand-in and the staged library -------------------------------------

def sdk_root() -> pathlib.Path:
    given = os.environ.get("KEYNUB_SDK_ROOT")
    if given:
        return pathlib.Path(given)
    here = pathlib.Path(__file__).resolve()
    for folder in [pathlib.Path.cwd(), *pathlib.Path.cwd().parents, *here.parents]:
        if (folder / "bindings" / "flat" / "licd_flat.c").is_file():
            return folder
    raise RuntimeError("the SDK sources were not found; set KEYNUB_SDK_ROOT")


def build_stand_in(root: pathlib.Path, output: pathlib.Path) -> None:
    include = root / "core" / "include"
    if not (include / "licdongle.h").is_file():
        include = root / "include"
    flat = root / "bindings" / "flat"
    sources = [str(flat / "licd_flat.c"), str(root / "bindings" / "julia" / "test" / "stub" / "licd_stub.c")]
    gcc = ["-shared", "-O1", "-DLICDF_BUILD_SHARED", f"-I{include}", f"-I{flat}", "-o", str(output), *sources]
    cl = ["/nologo", "/LD", "/O1", "/DLICDF_BUILD_SHARED", f"/I{include}", f"/I{flat}", f"/Fe:{output}", *sources]
    for command in (["cl", *cl], ["gcc", *gcc], ["clang", *gcc], ["zig", "cc", *gcc]):
        try:
            # In the output folder, where the compilers leave their byproducts.
            done = subprocess.run(command, cwd=output.parent, capture_output=True)
        except OSError:
            continue
        if done.returncode == 0 and output.is_file():
            return
    raise RuntimeError("the flat stand-in could not be compiled: no C compiler (cl, gcc, clang, zig cc) on the path")


def stage(root: pathlib.Path, work: pathlib.Path) -> pathlib.Path:
    """The library at the same relative place as in the repository, and the
    stand-in where the VIs look for keynub_licdongle_flat.dll."""
    library = work / "bindings" / "labview" / "keynub_licdongle"
    shutil.copytree(root / "bindings" / "labview" / "keynub_licdongle", library)
    natives = work / "natives" / "win-x64"
    natives.mkdir(parents=True)
    build_stand_in(root, natives / "keynub_licdongle_flat.dll")
    return library / "VIs"


# ---- LabVIEW -----------------------------------------------------------------

class LabVIEW:
    """Runs a VI through LabVIEW's automation server: set controls, run, read
    indicators. Methods are invoked through raw IDispatch, because the type
    library LabVIEW registers describes an older interface. Run uses the
    current values of all controls, so every call sets each control it relies
    on. LabVIEW tracks an indicator's value only once it has been asked for
    (the first GetControlValue on a VI with a closed front panel returns the
    default), so each indicator is read once before the run."""

    def __init__(self, folder: pathlib.Path):
        import pythoncom
        import win32com.client.dynamic as dynamic

        self._pythoncom = pythoncom
        self._app = dynamic.Dispatch("LabVIEW.Application")
        self._folder = folder

    def _call(self, o, name, *args):
        return o.Invoke(o.GetIDsOfNames(name), 0, self._pythoncom.DISPATCH_METHOD, 1, *args)

    def __call__(self, name, sets, reads):
        path = self._folder / name
        vi = self._app.GetVIReference(str(path))
        loaded = pathlib.Path(str(vi.Path))
        if loaded.resolve() != path.resolve():
            raise RuntimeError("LabVIEW already has %s open from %s; close it and run again" % (name, loaded.parent))
        o = vi._oleobj_
        for control, value in sets.items():
            self._call(o, "SetControlValue", control, value)
        for indicator in reads:
            self._call(o, "GetControlValue", indicator)
        self._call(o, "Run", False)
        result = {}
        for indicator in reads:
            value = self._call(o, "GetControlValue", indicator)
            if isinstance(value, (tuple, list, memoryview)) and indicator != "error out":
                value = bytes(bytearray(value))
            result[indicator] = value
        return result


# ---- the checks ----------------------------------------------------------------

def scenario(run) -> int:
    """Drives every VI through `run(vi_name, controls, indicators)`, which returns
    the indicators by name. Returns the number of failed checks."""
    failures = []

    def check(condition, what):
        if not condition:
            failures.append(what)
            print("  FAIL  %s" % what)

    def call(name, sets, reads, status, what):
        """Runs a VI; the C return value must be `status`, and error out must
        carry it as the code when it is negative."""
        r = run("licdf %s.vi" % name, sets, ["function return", "error out", *reads])
        rc = r["function return"]
        if status is None:
            ok = rc > 0
        else:
            ok = rc == status
        check(ok, "%s: returned %r, expected %r" % (what, rc, status if status is not None else "a handle"))
        err = r["error out"]
        failed = status is not None and status < 0
        check(bool(err[0]) == failed and (not failed or err[1] == status),
              "%s: error out %r" % (what, tuple(err[:2])))
        return r

    def text(name, sets, size, status, what):
        return call(name, {**sets, "out": " " * size, "out_size": size}, ["out out"], status, what)["out out"]

    def read_record(h, name, status=OK):
        r = call("record read", {"handle": h, "name": name, "out": b"", "out_cap": 0, "out_len": 0},
                 ["out_len out"], RANGE if status == OK else status, "size of record %s" % name)
        if status != OK:
            return None
        need = r["out_len out"]
        r = call("record read", {"handle": h, "name": name, "out": bytes(need), "out_cap": need, "out_len": 0},
                 ["out out", "out_len out"], OK, "record read %s" % name)
        return bytes(r["out out"][:r["out_len out"]])

    r = call("version", {}, ["out_major out", "out_minor out", "out_patch out"], OK, "version")
    if (r["out_major out"], r["out_minor out"], r["out_patch out"]) != (9, 8, 7):
        check(False, "LabVIEW loaded a keynub_licdongle_flat library other than the stand-in (version %r.%r.%r)"
              % (r["out_major out"], r["out_minor out"], r["out_patch out"]))
        return len(failures)
    check(text("strerror", {"status": NO_DEVICE}, 256, OK, "strerror") == "no device", "status text")
    text("strerror", {"status": NO_DEVICE}, 3, RANGE, "status text too small")

    r = call("device count", {"out_count": 0}, ["out_count out"], OK, "device count")
    check(r["out_count out"] == 1, "one device")
    check(text("device serial", {"index": 0}, 15, OK, "device serial") == SERIAL, "device serial")
    check(text("device path", {"index": 0}, 512, OK, "device path") == "stub:0", "device path")
    text("device serial", {"index": 1}, 15, RANGE, "device index out of range")
    call("open", {"serial_or_empty": "nope"}, [], NO_DEVICE, "open by unknown serial")
    call("open path", {"path": "stub:9"}, [], NO_DEVICE, "open by unknown path")

    h = call("open", {"serial_or_empty": ""}, [], None, "open")["function return"]
    check(text("get serial", {"handle": h}, 15, OK, "get serial") == SERIAL, "serial")
    outs = ["out_proto_major", "out_proto_minor", "out_fw_major", "out_fw_minor", "out_fw_patch", "out_flags",
            "out_capacity", "out_free"]
    r = call("get info", {"handle": h, **{o: 0 for o in outs}}, [o + " out" for o in outs], OK, "get info")
    info = [r[o + " out"] for o in outs]
    check(info[:5] == [1, 0, 2, 3, 4], "protocol and firmware versions")
    flags = info[5]
    check(flags & SE_READY and flags & PROVISIONED and flags & ISOLATED, "flags set")
    check(not flags & WATCHDOG_REBOOT and not flags & WRITEAUTH_ROTATED, "flags clear")
    check(info[6:] == [1024 * 1024, 1000000], "capacity")

    def verify(status, what):
        return call("verify genuine", {"handle": h, "out_genuine": 0, "out_serial": " " * 15, "serial_size": 15,
                                       "out_provisioned_date": " " * 11, "date_size": 11},
                    ["out_genuine out", "out_serial out", "out_provisioned_date out"], status, what)

    r = verify(OK, "verify genuine")
    check((r["out_genuine out"], r["out_serial out"], r["out_provisioned_date out"]) == (1, SERIAL, "2026-08-15"),
          "genuine")
    bad_root = bytes([0x02, 0x01, 0x00])
    call("set trust root", {"handle": h, "der": bad_root, "der_len": 3}, [], CERT_INVALID, "malformed trust root")
    root = bytearray([0xAB] * 132)
    root[0:4] = bytes([0x30, 0x82, 0x01, 0x00])
    call("set trust root", {"handle": h, "der": bytes(root), "der_len": 132}, [], OK, "foreign trust root")
    verify(CERT_INVALID, "verify against a foreign root")
    root[4:] = bytes([0x01] * 128)
    call("set trust root", {"handle": h, "der": bytes(root), "der_len": 132}, [], OK, "right trust root")
    verify(OK, "verify after the right root")

    call("record count", {"handle": h, "out_count": 0}, [], SESSION_EXPIRED, "records without a session")
    call("session open", {"handle": h}, [], OK, "session open")
    payload = b"license-blob-0123456789"

    def write(name, data, status, what):
        call("record write", {"handle": h, "name": name, "data": data, "data_len": len(data)}, [], status, what)

    write("lic", payload, AUTH_REQUIRED, "write before the write role")
    call("write auth", {"handle": h, "der": bytes([0x30, 0x00]), "der_len": 2}, [], NOT_GENUINE, "bad key")
    call("write auth", {"handle": h, "der": FACTORY_KEY, "der_len": len(FACTORY_KEY)}, [], OK, "write auth")
    write("lic", payload, OK, "record write")
    check(read_record(h, "lic") == payload, "read back")
    r = call("record size", {"handle": h, "name": "lic", "out_size": 0}, ["out_size out"], OK, "record size")
    check(r["out_size out"] == len(payload), "record size value")
    write("cfg", b"cfgdata", OK, "second record")
    r = call("record count", {"handle": h, "out_count": 0}, ["out_count out"], OK, "record count")
    check(r["out_count out"] == 2, "two records")
    seen = set()
    for i in range(2):
        r = call("record name", {"handle": h, "index": i, "out": " " * 64, "out_size": 64, "out_record_size": 0},
                 ["out out", "out_record_size out"], OK, "record name")
        seen.add((r["out out"], r["out_record_size out"]))
    check(seen == {("lic", len(payload)), ("cfg", 7)}, "record names and sizes")
    read_record(h, "nope", NOT_FOUND)
    check(text("last error", {"handle": h}, 256, OK, "last error") == "no such record", "error detail")
    call("record erase", {"handle": h, "name": ""}, [], INVALID_ARG, "erase with an empty name")
    call("record erase", {"handle": h, "name": "cfg"}, [], OK, "record erase")
    r = call("record count", {"handle": h, "out_count": 0}, ["out_count out"], OK, "record count")
    check(r["out_count out"] == 1, "one record left")
    write("empty", b"", OK, "empty record")
    r = call("record read", {"handle": h, "name": "empty", "out": b"", "out_cap": 0, "out_len": 0},
             ["out_len out"], OK, "read the empty record")
    check(r["out_len out"] == 0, "empty record length")

    def counter(name, cid, status, what):
        return call(name, {"handle": h, "counter_id": cid, "out_value": 0}, ["out_value out"], status,
                    what)["out_value out"]

    before = counter("counter read", 0, OK, "counter read")
    check(counter("counter increment", 0, OK, "counter increment") == before + 1, "increment")
    check(counter("counter read", 1, OK, "second counter") == 0, "counters")
    counter("counter read", 7, RANGE, "counter out of range")

    secret = bytes((3 * k + 7) % 256 for k in range(100))
    for scope in (0, 1):
        r = call("app encrypt", {"handle": h, "scope": scope, "plaintext": secret, "plaintext_len": 100,
                                 "out": b"", "out_cap": 0, "out_len": 0}, ["out_len out"], RANGE, "sealed size")
        need = r["out_len out"]
        r = call("app encrypt", {"handle": h, "scope": scope, "plaintext": secret, "plaintext_len": 100,
                                 "out": bytes(need), "out_cap": need, "out_len": 0}, ["out out", "out_len out"], OK,
                 "app encrypt")
        blob = bytearray(r["out out"][:r["out_len out"]])
        check(len(blob) > 100 and blob[0] == scope, "sealed data and scope byte")
        r = call("app decrypt", {"handle": h, "packed": bytes(blob), "packed_len": len(blob), "out": bytes(256),
                                 "out_cap": 256, "out_len": 0}, ["out out", "out_len out"], OK, "app decrypt")
        check(bytes(r["out out"][:r["out_len out"]]) == secret, "round trip")
        blob[-1] ^= 1
        call("app decrypt", {"handle": h, "packed": bytes(blob), "packed_len": len(blob), "out": bytes(256),
                             "out_cap": 256, "out_len": 0}, [], TAG_MISMATCH, "tampered envelope")
    call("app encrypt", {"handle": h, "scope": 7, "plaintext": secret, "plaintext_len": 100, "out": b"",
                         "out_cap": 0, "out_len": 0}, [], INVALID_ARG, "unknown scope")

    call("record erase all", {"handle": h}, [], OK, "record erase all")
    r = call("record count", {"handle": h, "out_count": 0}, ["out_count out"], OK, "record count")
    check(r["out_count out"] == 0, "erase all")

    call("write auth rotate", {"handle": h, "der": REPLACEMENT_KEY, "der_len": len(REPLACEMENT_KEY)}, [], OK,
         "write auth rotate")
    write("lic", b"still-writable", OK, "still writable")
    call("session close", {"handle": h}, [], OK, "session close")
    r = call("get info", {"handle": h, **{o: 0 for o in outs}}, ["out_flags out"], OK, "get info")
    check(r["out_flags out"] & WRITEAUTH_ROTATED, "rotated flag")
    call("session open", {"handle": h}, [], OK, "second session")
    call("write auth", {"handle": h, "der": FACTORY_KEY, "der_len": len(FACTORY_KEY)}, [], NOT_GENUINE,
         "factory key after rotation")
    call("write auth", {"handle": h, "der": REPLACEMENT_KEY, "der_len": len(REPLACEMENT_KEY)}, [], OK, "new key")
    write("lic", b"new-key-writes", OK, "write with the new key")
    check(read_record(h, "lic") == b"new-key-writes", "new key content")
    call("session close", {"handle": h}, [], OK, "session close")

    call("close", {"handle": h}, [], OK, "close")
    text("get serial", {"handle": h}, 15, INVALID_ARG, "serial after close")
    call("close", {"handle": h}, [], INVALID_ARG, "close twice")

    handles = [run("licdf open.vi", {"serial_or_empty": SERIAL}, ["function return"])["function return"]
               for _ in range(40)]
    check(sum(1 for x in handles if x > 0) == 32, "32 handles at a time")
    for x in handles:
        if x > 0:
            run("licdf close.vi", {"handle": x}, ["function return"])
    return len(failures)


def main() -> int:
    if sys.platform != "win32":
        print("the LabVIEW stand-in test runs on Windows")
        return 2
    root = sdk_root()
    work = pathlib.Path(tempfile.mkdtemp(prefix="keynub-labview-"))
    try:
        failed = scenario(LabVIEW(stage(root, work)))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if failed:
        print("%d check(s) failed" % failed)
        return 1
    print("keynub_licdongle.lvlib: every call passed against the ABI stand-in")
    return 0


if __name__ == "__main__":
    sys.exit(main())
