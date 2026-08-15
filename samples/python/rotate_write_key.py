#!/usr/bin/env python3
"""KeyNub SDK - Python sample: take ownership of a new dongle.

A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
that from the next session onward only your key can write records, erase them or
increment counters. Run it once per dongle, when it arrives.

Two keys are involved and they are not interchangeable:

  * the **current** key -- KeyNub's, supplied with the delivery. It proves you
    may replace what is there. After this runs it no longer works on this unit.
  * the **replacement** key -- yours, generated below or brought from your own
    key management. Its private half is what will authorise every future write,
    so it is worth exactly as much as your licence-signing key.

Both are P-256 private keys in PKCS#8 DER.

Targets real hardware; prints guidance and exits 0 when no dongle is attached.

    python rotate_write_key.py --current ../../keys/keynub-shipping-writeauth.key.der --new my-key.der
    python rotate_write_key.py --current ../../keys/keynub-shipping-writeauth.key.der --generate my-key.der
"""

import argparse
import sys
from pathlib import Path

try:
    import keynub_licdongle as kn
except ModuleNotFoundError:
    # Running from a checkout, where the package is not installed.
    import os
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "bindings", "python"))
    import keynub_licdongle as kn


def generate_key(path: Path) -> bytes:
    """A fresh P-256 key, written as PKCS#8 DER.

    Only here so the sample runs end to end. In production this belongs wherever
    you already keep signing keys -- an HSM, a key vault, whatever holds the key
    you sign licences with -- because losing it means no further writes to any
    dongle rotated to it, and there is no recovery path that does not involve
    the units coming back.
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    if path.exists():
        raise SystemExit(f"{path} already exists; refusing to overwrite a key")
    key = ec.generate_private_key(ec.SECP256R1())
    der = key.private_bytes(serialization.Encoding.DER,
                            serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption())
    path.write_bytes(der)
    print(f"wrote a new P-256 key to {path}")
    print("Back it up before going further. Nothing below can be undone.")
    return der


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--current", required=True, type=Path,
                    help="the key the dongle holds now (KeyNub's, as delivered)")
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--new", type=Path, help="your replacement key, PKCS#8 DER")
    group.add_argument("--generate", type=Path, metavar="FILE",
                       help="generate a replacement key and write it here first")
    args = ap.parse_args()

    current = args.current.read_bytes()
    replacement = generate_key(args.generate) if args.generate else args.new.read_bytes()

    with kn.LicenseDongleContext() as ctx:
        if not ctx.enumerate():
            print("Connect a KeyNub dongle and re-run.")
            return 0

        with ctx.open() as dongle:
            print(f"dongle {dongle.get_serial()}")
            with dongle.session() as session:
                # The current key proves you may replace it. Without this the
                # rotation is refused: holding the write role is the only
                # evidence the outgoing key is yours to change.
                session.authorize_write(current)

                # The replacement proves itself, by signing this session. That is
                # what makes it impossible to rotate to a key nobody holds --
                # the mistake here that no later session could undo.
                session.rotate_write_key(replacement)
                print("rotated: this dongle now answers only to your key")

                # Prove it, rather than trusting the return code. A fresh session
                # is the only place the change is observable, because the session
                # above keeps the role it was already granted.
            with dongle.session() as session:
                try:
                    session.authorize_write(current)
                except kn.LicenseDongleError:
                    print("confirmed: the old key no longer elevates")
                else:
                    print("WARNING: the old key still works -- do not ship this unit")
                    return 1
                session.authorize_write(replacement)
                print("confirmed: your key elevates")

    print("\nKeep the replacement key safe. Every future write to this dongle "
          "needs it, and it cannot be recovered from the dongle.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
