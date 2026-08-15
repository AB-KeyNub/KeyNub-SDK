#!/usr/bin/env python3
"""KeyNub SDK - Python sample: enumerate a dongle, verify authenticity, open an
encrypted session, read a "license" record, and round-trip app-data encryption.

Targets real hardware; prints guidance and exits 0 when no dongle is attached.

Run (after `pip install keynub-licdongle`, or with the binding on PYTHONPATH and
the native discoverable via KEYNUB_LICDONGLE_LIBRARY):

    python verify_and_read.py
"""

import sys

try:
    import keynub_licdongle as kn
except ModuleNotFoundError:
    # Running from a checkout, where the package is not installed.
    import os
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "bindings", "python"))
    import keynub_licdongle as kn


def main() -> int:
    print(f"KeyNub SDK {'.'.join(map(str, kn.LicenseDongleContext.library_version()))}")

    with kn.LicenseDongleContext() as ctx:
        devices = ctx.enumerate()
        print(f"Dongles found: {len(devices)}")
        if not devices:
            print("Connect a KeyNub dongle and re-run.")
            return 0

        with ctx.open() as dongle:
            info = dongle.get_info()
            print(f"protocol {info.protocol_version}, firmware {info.firmware_version}, "
                  f"capacity {info.data_capacity} bytes")
            print(f"serial {dongle.get_serial()}")

            result = dongle.verify_genuine()
            print(f"genuine: {result.is_genuine}, cert serial {result.serial}")
            if not result.is_genuine:
                return 2

            with dongle.open_session() as session:
                try:
                    license = session.read_record("license")
                    print(f"license record: {len(license)} bytes")
                except kn.RecordNotFoundError:
                    print("no 'license' record on this dongle")

                # App-data envelope encryption: only decryptable with this dongle.
                secret = b"hello-keynub"
                packed = session.app_encrypt(kn.Scope.DEVICE, secret)
                ok = session.app_decrypt(packed) == secret
                print(f"app-crypto round-trip {'OK' if ok else 'FAILED'} "
                      f"({len(secret)} plaintext -> {len(packed)} packed bytes)")
                return 0 if ok else 4


if __name__ == "__main__":
    sys.exit(main())
