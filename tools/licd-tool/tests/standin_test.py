"""Every command of licd-tool against a stand-in for the C ABI.

    python tools/licd-tool/tests/standin_test.py

Compiles licd_tool.c together with bindings/julia/test/stub/licd_stub.c (one
imaginary dongle held in memory) with the C compiler on the path (cc, gcc,
clang, zig cc or cl) into one executable, then runs every command and checks
its output and exit status. Each run is a new process and so a fresh dongle.
KEYNUB_SDK_ROOT names the SDK sources when the script is not inside a clone.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FACTORY_KEY = bytes([0x30, 0x10, 0x01, 0x02, 0x03])
REPLACEMENT_KEY = bytes([0x30, 0x11, 0x09, 0x08, 0x07, 0x06])
SERIAL = "04A1B2C3D4E5F6"


def sdk_root():
    if os.environ.get("KEYNUB_SDK_ROOT"):
        return os.environ["KEYNUB_SDK_ROOT"]
    d = HERE
    while True:
        if os.path.isfile(os.path.join(d, "bindings", "flat", "licd_flat.c")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            sys.exit("the SDK sources were not found above this script; set KEYNUB_SDK_ROOT")
        d = parent


def build(root, work):
    exe = os.path.join(work, "licd-tool-standin" + (".exe" if os.name == "nt" else ""))
    include = os.path.join(root, "core", "include")
    if not os.path.isfile(os.path.join(include, "licdongle.h")):
        include = os.path.join(root, "include")
    sources = [os.path.join(HERE, "..", "licd_tool.c"),
               os.path.join(root, "bindings", "julia", "test", "stub", "licd_stub.c")]
    gcc = ["-O1", "-std=c99", "-I" + include, "-o", exe] + sources
    cl = ["/nologo", "/O1", "/I" + include, "/Fe:" + exe] + sources
    for cmd in (["cc"] + gcc, ["gcc"] + gcc, ["clang"] + gcc, ["zig", "cc"] + gcc, ["cl"] + cl):
        if shutil.which(cmd[0]) is None:
            continue
        r = subprocess.run(cmd, cwd=work, capture_output=True, text=True)
        if r.returncode == 0 and os.path.isfile(exe):
            return exe
    sys.exit("licd-tool and the stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path")


failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print("FAILED:", what)


def run(exe, *args, stdin=None, want=0):
    r = subprocess.run([exe] + list(args), input=stdin, capture_output=True)
    check(r.returncode == want, "%s: exit %d, expected %d (%s)" % (
        " ".join(args), r.returncode, want, r.stderr.decode("utf-8", "replace").strip()))
    return r


def jrun(exe, *args, want=0):
    r = run(exe, "--json", *args, want=want)
    try:
        return json.loads(r.stdout.decode("utf-8"))
    except ValueError:
        check(False, "%s: output is not JSON: %r" % (" ".join(args), r.stdout[:200]))
        return {}


def main():
    root = sdk_root()
    work = tempfile.mkdtemp(prefix="licd-tool-standin-")
    try:
        exe = build(root, work)
        key = os.path.join(work, "factory.der")
        new_key = os.path.join(work, "new.der")
        open(key, "wb").write(FACTORY_KEY)
        open(new_key, "wb").write(REPLACEMENT_KEY)

        # help, version, usage
        check(b"usage: licd-tool" in run(exe, "--help").stdout, "--help prints the usage")
        check(b"9.8.7" in run(exe, "--version").stdout, "--version names the core version")
        check(jrun(exe, "--version").get("native_core") == "9.8.7", "--version --json")
        run(exe, want=2)
        run(exe, "frobnicate", want=2)
        run(exe, "--bogus", "list", want=2)
        run(exe, "--serial", want=2)

        # list, info, verify
        d = jrun(exe, "list")
        check(d.get("count") == 1 and d["dongles"][0]["serial"] == SERIAL, "list finds the dongle")
        check(d["dongles"][0]["vendor_id"] == "0x1234" and d["dongles"][0]["path"] == "stub:0", "list: ids and path")
        check(SERIAL.encode() in run(exe, "list").stdout, "list, text")
        info = jrun(exe, "info")
        check(info.get("serial") == SERIAL and info.get("firmware_version") == "2.3.4", "info")
        check(info.get("data_free") == 1000000 and info.get("write_key_rotated") is False, "info: storage, key")
        check(b"the factory key" in run(exe, "info").stdout, "info names the factory key")
        run(exe, "--serial", "nope", "info", want=1)
        v = jrun(exe, "verify")
        check(v.get("genuine") is True and v.get("provisioned_date") == "2026-08-15", "verify")
        check(b"GENUINE" in run(exe, "verify").stdout, "verify, text")
        bad_root = os.path.join(work, "root.der")
        open(bad_root, "wb").write(bytes([0x30, 0x82, 0x01, 0x00]) + bytes([0xAB]) * 128)
        v = jrun(exe, "--trust-root", bad_root, "verify", want=2)
        check(v.get("genuine") is False, "verify against another root: not genuine, exit 2")

        # records
        check(jrun(exe, "records", "list").get("count") == 0, "records list: none")
        run(exe, "records", "write", "lic", "-", stdin=b"x", want=1)  # no write key
        r = run(exe, "--write-key", key, "records", "write", "lic", "-", stdin=b"license-blob")
        check(b"wrote and verified 12 bytes" in r.stdout, "records write verifies by reading back")
        w = jrun(exe, "--write-key", key, "records", "write", "cfg", key)
        check(w.get("verified") is True and w.get("bytes") == len(FACTORY_KEY), "records write --json")
        run(exe, "--master-key", key, "records", "write", "lic", "-", stdin=b"alias")
        run(exe, "--write-key", os.path.join(work, "missing.der"), "records", "write", "a", "-", stdin=b"", want=1)
        run(exe, "records", "read", "nope", want=1)
        run(exe, "--write-key", key, "records", "erase", "nope", want=1)
        run(exe, "--write-key", key, "records", "erase", "--all", want=2)
        check(b"erased all" in run(exe, "--write-key", key, "records", "erase", "--all", "--yes").stdout,
              "records erase --all --yes")
        run(exe, "--write-key", key, "records", "erase", "x", "--all", "--yes", want=2)
        run(exe, "--write-key", key, "records", "erase", want=2)

        # counters
        c = jrun(exe, "counter", "read")
        check(c.get("counters") == {"0": 0, "1": 0}, "counter read: 0 and 1 by default")
        check(jrun(exe, "counter", "read", "1").get("counters") == {"1": 0}, "counter read 1")
        run(exe, "counter", "read", "7", want=1)
        run(exe, "counter", "read", "x", want=2)
        run(exe, "--write-key", key, "counter", "increment", "0", want=2)
        i = jrun(exe, "--write-key", key, "counter", "increment", "0", "--yes")
        check(i.get("before") == 0 and i.get("after") == 1, "counter increment")
        run(exe, "counter", "increment", "0", "--yes", want=1)

        # appcrypto: an envelope made in one process opens in the next
        plain = os.path.join(work, "plain.bin")
        sealed = os.path.join(work, "sealed.bin")
        back = os.path.join(work, "back.bin")
        data = bytes(range(256)) * 3
        open(plain, "wb").write(data)
        for scope, code in (("device", 0), ("developer", 1)):
            e = jrun(exe, "appcrypto", "encrypt", plain, "-o", sealed, "--scope", scope)
            env = open(sealed, "rb").read()
            check(e.get("output_bytes") == len(env) > len(data) and env[0] == code, "encrypt, %s scope" % scope)
            run(exe, "appcrypto", "decrypt", sealed, "-o", back)
            check(open(back, "rb").read() == data, "decrypt round trip, %s scope" % scope)
        piped = run(exe, "appcrypto", "encrypt", "-", stdin=b"\x00\r\n\x1a binary").stdout
        check(run(exe, "appcrypto", "decrypt", "-", stdin=piped).stdout == b"\x00\r\n\x1a binary",
              "stdin and stdout carry bytes unchanged")
        tampered = bytearray(open(sealed, "rb").read())
        tampered[-1] ^= 1
        open(sealed, "wb").write(bytes(tampered))
        run(exe, "appcrypto", "decrypt", sealed, want=1)
        run(exe, "appcrypto", "encrypt", plain, "--scope", "everyone", want=2)

        # the write key
        run(exe, "--write-key", key, "rotate-write-key", new_key, want=2)
        check(jrun(exe, "--write-key", key, "rotate-write-key", new_key, "--yes").get("write_key_rotated") is True,
              "rotate-write-key")
        run(exe, "--write-key", new_key, "rotate-write-key", new_key, "--yes", want=1)  # fresh dongle: factory key
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        print("%d check(s) failed" % len(failures))
        return 1
    print("licd-tool: every call passed against the ABI stand-in")
    return 0


if __name__ == "__main__":
    sys.exit(main())
