// KeyNub SDK - Swift sample: take ownership of a new dongle.
//
// A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
// that from the next session onward only your key can write records, erase them or
// increment counters. Run it once per dongle, when it arrives.
//
// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//
//   openssl ecparam -name prime256v1 -genkey -noout |
//     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//
//   swift run rotate_write_key ../../keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It cannot be
// recovered from the dongle, and a unit rotated to a key you have lost has to come
// back to be re-provisioned.

import Foundation
import KeyNubLicDongle

func readKey(_ path: String) -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write("cannot open \(path)\n".data(using: .utf8)!)
        exit(2)
    }
    return [UInt8](data)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: rotate_write_key <current-key.der> <new-key.der>\n".data(using: .utf8)!)
    exit(2)
}
let current = readKey(arguments[1])
let replacement = readKey(arguments[2])

do {
    let ctx = try Context()
    defer { ctx.close() }
    if try ctx.enumerate().isEmpty {
        print("Connect a KeyNub dongle and re-run.")
        exit(0)
    }

    let dongle = try ctx.open()
    defer { dongle.close() }
    print("Dongle \(try dongle.serial())")
    if try dongle.info().writeAuthRotated {
        print("This dongle's write key has already been rotated away from the factory one.")
    }

    try dongle.withSession { s in
        try s.authorizeWrite(key: current)       // the key the dongle accepts today
        try s.rotateWriteKey(replacement)        // from the next session: only the new one
    }

    print("Write key rotated: \(try dongle.info().writeAuthRotated ? "yes" : "no")")
} catch {
    FileHandle.standardError.write("KeyNub error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
