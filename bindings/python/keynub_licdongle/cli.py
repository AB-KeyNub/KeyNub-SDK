"""``licd-tool`` — command-line access to a KeyNub license dongle.

Installed as a console script by the ``keynub-licdongle`` wheel, so
``pip install keynub-licdongle`` gives you ``licd-tool``. It drives the same
production core (``keynub_licdongle``) an application would, which makes it useful
for three jobs:

* **licence issuance** — write records and wrap app data for a customer's dongle;
* **support** — ask a dongle in the field what it is and whether it is genuine;
* **integration debugging** — reproduce what an application sees, without the
  application.

Factory provisioning is deliberately NOT here: it lives in the firmware repo's
``tools/provision`` alongside the CA, because it is a vendor-internal operation
with irreversible steps, and this tool is published.

Anything that changes the dongle requires ``--master-key``; anything irreversible
additionally requires ``--yes``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

# ``licd-tool --help`` and ``--version`` must work even if the native library is
# missing or unloadable, so the package is imported lazily inside the commands
# rather than at module import time.


class ToolError(Exception):
    """A user-facing failure: reported as `error: <msg>` with exit code 1."""


# --------------------------------------------------------------------------- #
# output
# --------------------------------------------------------------------------- #


class Out:
    """Human-readable by default, machine-readable with --json.

    Every command builds a dict and hands it here, so the two formats cannot
    drift apart the way separate print statements do.
    """

    def __init__(self, as_json: bool) -> None:
        self.as_json = as_json

    def emit(self, data: Dict[str, Any], lines: Optional[List[str]] = None) -> None:
        if self.as_json:
            json.dump(data, sys.stdout, indent=2, default=str)
            sys.stdout.write("\n")
            return
        if lines is not None:
            for line in lines:
                print(line)
            return
        for key, value in data.items():
            print(f"{key}: {value}")

    def note(self, msg: str) -> None:
        """Progress/advisory text, suppressed under --json so stdout stays parseable."""
        if not self.as_json:
            print(msg)


# --------------------------------------------------------------------------- #
# connection helpers
# --------------------------------------------------------------------------- #


def _load_binding(args):
    if args.library:
        os.environ["KEYNUB_LICDONGLE_LIBRARY"] = str(Path(args.library).resolve())
    try:
        import keynub_licdongle as kn
    except Exception as exc:  # noqa: BLE001
        raise ToolError(
            f"could not load the native library: {exc}\n"
            "  Point --library at keynub_licdongle.dll/.so/.dylib, or set "
            "KEYNUB_LICDONGLE_LIBRARY."
        ) from exc
    return kn


def _read_file(path: str, what: str) -> bytes:
    try:
        return Path(path).read_bytes()
    except OSError as exc:
        raise ToolError(f"cannot read {what} ({path}): {exc}") from exc


class Connection:
    """Context/dongle pair, with the trust root installed if one was supplied."""

    def __init__(self, args, need_session: bool = False, need_write: bool = False) -> None:
        self.kn = _load_binding(args)
        self.args = args
        self.ctx = self.kn.LicenseDongleContext()
        self.dongle = None
        self.session = None
        self._need_session = need_session
        self._need_write = need_write

    def __enter__(self) -> "Connection":
        kn = self.kn
        args = self.args
        try:
            if args.trust_root:
                self.ctx.set_trust_root(_read_file(args.trust_root, "trust root"))
            try:
                self.dongle = self.ctx.open(args.serial)
            except kn.DeviceNotFoundError as exc:
                raise ToolError(
                    "no dongle found"
                    + (f" with serial {args.serial}" if args.serial else "")
                    + ".\n  Check the cable; on Linux check the udev rule "
                    "(the SDK build checks)."
                ) from exc

            if self._need_session:
                if not args.trust_root:
                    raise ToolError(
                        "this command needs an encrypted session, which requires "
                        "verifying the dongle first.\n"
                        "  Pass --trust-root <ca.der> unless this build has one compiled in."
                    )
                try:
                    self.session = self.dongle.open_session()
                except kn.LicenseDongleError as exc:
                    raise ToolError(f"could not open a session: {exc}") from exc

            if self._need_write:
                if not args.master_key:
                    raise ToolError(
                        "this command modifies the dongle and needs the developer "
                        "master key.\n  Pass --master-key <key.der>."
                    )
                try:
                    self.session.authorize_write(_read_file(args.master_key, "master key"))
                except self.kn.LicenseDongleError as exc:
                    raise ToolError(f"write authorization failed: {exc}") from exc
        except BaseException:
            self.close()
            raise
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def close(self) -> None:
        for obj in (self.session, self.dongle, self.ctx):
            if obj is not None:
                try:
                    obj.close()
                except Exception:  # noqa: BLE001
                    pass
        self.session = self.dongle = None


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #


def cmd_list(args, out: Out) -> int:
    kn = _load_binding(args)
    with kn.LicenseDongleContext() as ctx:
        devices = ctx.enumerate()
    out.emit(
        {"count": len(devices),
         "dongles": [{"serial": d.serial, "vendor_id": f"0x{d.vendor_id:04X}",
                      "product_id": f"0x{d.product_id:04X}", "path": d.path}
                     for d in devices]},
        lines=([f"{len(devices)} dongle(s):"] +
               [f"  {d.serial}  (VID 0x{d.vendor_id:04X} PID 0x{d.product_id:04X})"
                for d in devices]) if devices else ["no dongles found"],
    )
    return 0 if devices else 1


def cmd_info(args, out: Out) -> int:
    with Connection(args) as conn:
        info = conn.dongle.get_info()
        serial = conn.dongle.get_serial()
        data = {
            "serial": serial,
            "protocol_version": ".".join(map(str, info.protocol_version)),
            "firmware_version": ".".join(map(str, info.firmware_version)),
            "se_ready": info.se_ready,
            "provisioned": info.provisioned,
            "data_capacity": info.data_capacity,
            "data_free": info.data_free,
        }
        out.emit(data, lines=[
            f"serial            {serial}",
            f"protocol          {data['protocol_version']}",
            f"firmware          {data['firmware_version']}",
            f"secure element    {'ready' if info.se_ready else 'NOT READY'}",
            f"provisioned       {'yes' if info.provisioned else 'no'}",
            f"data              {info.data_free} of {info.data_capacity} bytes free",
        ])
    return 0


def cmd_verify(args, out: Out) -> int:
    if not args.trust_root:
        raise ToolError("verify needs --trust-root <ca.der> unless this build has a "
                        "trust root compiled in")
    kn = _load_binding(args)
    with Connection(args) as conn:
        try:
            res = conn.dongle.verify_genuine()
        except kn.LicenseDongleError as exc:
            out.emit({"genuine": False, "error": str(exc)},
                     lines=[f"NOT GENUINE: {exc}"])
            return 2
        data = {"genuine": res.is_genuine, "serial": res.serial,
                "provisioned_date": res.provisioned_date}
        out.emit(data, lines=[
            f"GENUINE           {res.serial}",
            f"provisioned       {res.provisioned_date or '(none)'}",
        ])
        return 0 if res.is_genuine else 2


def cmd_records_list(args, out: Out) -> int:
    with Connection(args, need_session=True) as conn:
        records = conn.session.list_records()
        out.emit(
            {"count": len(records),
             "records": [{"name": r.name, "size": r.size} for r in records]},
            lines=([f"{len(records)} record(s):"] +
                   [f"  {r.name:<34} {r.size} bytes" for r in records])
            if records else ["no records stored"],
        )
    return 0


def cmd_records_read(args, out: Out) -> int:
    kn = _load_binding(args)
    with Connection(args, need_session=True) as conn:
        try:
            data = conn.session.read_record(args.name)
        except kn.RecordNotFoundError:
            raise ToolError(f"no such record: {args.name}") from None
        if args.output:
            Path(args.output).write_bytes(data)
            out.emit({"name": args.name, "bytes": len(data), "output": args.output},
                     lines=[f"wrote {len(data)} bytes to {args.output}"])
        elif args.as_json:
            out.emit({"name": args.name, "bytes": len(data), "hex": data.hex()})
        else:
            # Raw to stdout so it pipes; the byte count goes to stderr.
            sys.stdout.buffer.write(data)
            print(f"({len(data)} bytes)", file=sys.stderr)
    return 0


def cmd_records_write(args, out: Out) -> int:
    payload = sys.stdin.buffer.read() if args.input == "-" else _read_file(args.input, "record data")
    with Connection(args, need_session=True, need_write=True) as conn:
        conn.session.write_record(args.name, payload)
        # Read back rather than trusting the write: this is licence data, and a
        # silent truncation would only surface at the customer.
        back = conn.session.read_record(args.name)
        if back != payload:
            raise ToolError(f"verification failed: wrote {len(payload)} bytes, "
                            f"read back {len(back)}")
        out.emit({"name": args.name, "bytes": len(payload), "verified": True},
                 lines=[f"wrote and verified {len(payload)} bytes to '{args.name}'"])
    return 0


def cmd_records_erase(args, out: Out) -> int:
    if args.all and not args.yes:
        raise ToolError("--all erases every record on the dongle; add --yes to confirm")
    with Connection(args, need_session=True, need_write=True) as conn:
        if args.all:
            conn.session.erase_all_records()
            out.emit({"erased": "all"}, lines=["erased all records"])
        else:
            if not args.name:
                raise ToolError("give a record name, or --all")
            conn.session.erase_record(args.name)
            out.emit({"erased": args.name}, lines=[f"erased '{args.name}'"])
    return 0


def cmd_counter_read(args, out: Out) -> int:
    with Connection(args, need_session=True) as conn:
        values = {str(i): conn.session.read_counter(i) for i in args.ids}
        out.emit({"counters": values},
                 lines=[f"counter {i}: {v}" for i, v in values.items()])
    return 0


def cmd_counter_increment(args, out: Out) -> int:
    if not args.yes:
        raise ToolError(
            "incrementing a monotonic counter is IRREVERSIBLE — the consumed value "
            "can never be recovered.\n  Add --yes if you are sure."
        )
    with Connection(args, need_session=True, need_write=True) as conn:
        before = conn.session.read_counter(args.id)
        after = conn.session.increment_counter(args.id)
        out.emit({"counter": args.id, "before": before, "after": after},
                 lines=[f"counter {args.id}: {before} -> {after} (cannot be undone)"])
    return 0


def cmd_appcrypto_encrypt(args, out: Out) -> int:
    kn = _load_binding(args)
    scope = kn.Scope.DEVELOPER if args.scope == "developer" else kn.Scope.DEVICE
    plaintext = sys.stdin.buffer.read() if args.input == "-" else _read_file(args.input, "input")
    with Connection(args, need_session=True) as conn:
        packed = conn.session.app_encrypt(scope, plaintext)
    if args.output:
        Path(args.output).write_bytes(packed)
        out.emit({"scope": args.scope, "plaintext_bytes": len(plaintext),
                  "envelope_bytes": len(packed), "output": args.output},
                 lines=[f"encrypted {len(plaintext)} bytes -> {len(packed)} byte envelope "
                        f"({args.scope} scope) in {args.output}"])
    else:
        sys.stdout.buffer.write(packed)
    return 0


def cmd_appcrypto_decrypt(args, out: Out) -> int:
    packed = sys.stdin.buffer.read() if args.input == "-" else _read_file(args.input, "envelope")
    with Connection(args, need_session=True) as conn:
        plaintext = conn.session.app_decrypt(packed)
    if args.output:
        Path(args.output).write_bytes(plaintext)
        out.emit({"envelope_bytes": len(packed), "plaintext_bytes": len(plaintext),
                  "output": args.output},
                 lines=[f"decrypted {len(packed)} bytes -> {len(plaintext)} bytes "
                        f"in {args.output}"])
    else:
        sys.stdout.buffer.write(plaintext)
    return 0


# --------------------------------------------------------------------------- #
# argument parsing
# --------------------------------------------------------------------------- #


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="licd-tool",
        description="Command-line access to a KeyNub license dongle.",
        epilog="Commands that modify the dongle need --master-key; irreversible ones "
               "also need --yes.",
    )
    p.add_argument("--serial", help="target this dongle (default: the only one attached)")
    p.add_argument("--library", help="path to the keynub_licdongle shared library")
    p.add_argument("--trust-root", metavar="DER",
                   help="CA certificate for verify_genuine; required for any session")
    p.add_argument("--master-key", metavar="DER",
                   help="developer master key (EC private key, DER) for write operations")
    p.add_argument("--json", dest="as_json", action="store_true",
                   help="machine-readable output on stdout")
    p.add_argument("--version", action="store_true", help="print versions and exit")

    sub = p.add_subparsers(dest="command", metavar="<command>")

    sub.add_parser("list", help="list attached dongles").set_defaults(func=cmd_list)
    sub.add_parser("info", help="show device and storage information").set_defaults(func=cmd_info)
    sub.add_parser("verify", help="prove the dongle is genuine").set_defaults(func=cmd_verify)

    rec = sub.add_parser("records", help="license data records").add_subparsers(
        dest="subcommand", metavar="<action>")
    rec.add_parser("list", help="list records").set_defaults(func=cmd_records_list)

    r_read = rec.add_parser("read", help="read a record")
    r_read.add_argument("name")
    r_read.add_argument("-o", "--output", help="write to this file (default: stdout)")
    r_read.set_defaults(func=cmd_records_read)

    r_write = rec.add_parser("write", help="write a record (needs --master-key)")
    r_write.add_argument("name")
    r_write.add_argument("input", help="file to write, or '-' for stdin")
    r_write.set_defaults(func=cmd_records_write)

    r_erase = rec.add_parser("erase", help="erase a record (needs --master-key)")
    r_erase.add_argument("name", nargs="?")
    r_erase.add_argument("--all", action="store_true", help="erase every record")
    r_erase.add_argument("--yes", action="store_true", help="confirm --all")
    r_erase.set_defaults(func=cmd_records_erase)

    cnt = sub.add_parser("counter", help="hardware monotonic counters").add_subparsers(
        dest="subcommand", metavar="<action>")
    c_read = cnt.add_parser("read", help="read counters")
    c_read.add_argument("ids", nargs="*", type=int, default=[0, 1], metavar="ID")
    c_read.set_defaults(func=cmd_counter_read)

    c_incr = cnt.add_parser("increment", help="increment a counter (IRREVERSIBLE)")
    c_incr.add_argument("id", type=int)
    c_incr.add_argument("--yes", action="store_true", help="confirm; cannot be undone")
    c_incr.set_defaults(func=cmd_counter_increment)

    app = sub.add_parser(
        "appcrypto",
        help="envelope-encrypt data so it only decrypts with a dongle attached",
    ).add_subparsers(dest="subcommand", metavar="<action>")
    a_enc = app.add_parser("encrypt", help="encrypt a file")
    a_enc.add_argument("input", help="file to encrypt, or '-' for stdin")
    a_enc.add_argument("-o", "--output", help="envelope output (default: stdout)")
    a_enc.add_argument("--scope", choices=("device", "developer"), default="device",
                       help="device = only this dongle; developer = any of your own dongles")
    a_enc.set_defaults(func=cmd_appcrypto_encrypt)

    a_dec = app.add_parser("decrypt", help="decrypt an envelope")
    a_dec.add_argument("input", help="envelope file, or '-' for stdin")
    a_dec.add_argument("-o", "--output", help="plaintext output (default: stdout)")
    a_dec.set_defaults(func=cmd_appcrypto_decrypt)

    return p


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    out = Out(args.as_json)

    if args.version:
        from . import __version__
        data: Dict[str, Any] = {"licd_tool": __version__}
        try:
            kn = _load_binding(args)
            data["native_core"] = ".".join(map(str, kn.LicenseDongleContext.library_version()))
        except ToolError as exc:
            data["native_core"] = f"unavailable ({exc})"
        out.emit(data, lines=[f"licd-tool     {data['licd_tool']}",
                              f"native core   {data['native_core']}"])
        return 0

    if not getattr(args, "func", None):
        parser.print_help()
        return 2

    try:
        return args.func(args, out)
    except ToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except Exception as exc:  # noqa: BLE001
        # Anything from the binding that was not turned into a ToolError: report it
        # cleanly rather than dumping a traceback at someone provisioning dongles.
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
