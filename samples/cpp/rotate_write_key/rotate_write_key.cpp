// KeyNub SDK - C++ sample: take ownership of a new dongle.
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
// Build it with the SDK's CMake project (-DLICD_BUILD_SAMPLES=ON), then:
//
//   ./sample_rotate_write_key_cpp ../../../keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware; prints guidance and exits 0 when no dongle is attached.
//
// The replacement key is worth what your licence-signing key is worth. It cannot be
// recovered from the dongle, and a unit rotated to a key you have lost has to come
// back to be re-provisioned.

#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

#include "licdongle.hpp"

static keynub::Bytes readKey(const std::string &path) {
    std::ifstream in(path.c_str(), std::ios::binary);
    if (!in) {
        throw std::runtime_error("cannot open " + path);
    }
    return keynub::Bytes((std::istreambuf_iterator<char>(in)),
                         std::istreambuf_iterator<char>());
}

int main(int argc, char **argv) {
    if (argc != 3) {
        std::cerr << "usage: " << argv[0] << " <current-key.der> <new-key.der>\n";
        return 2;
    }

    try {
        const keynub::Bytes current = readKey(argv[1]);
        const keynub::Bytes replacement = readKey(argv[2]);

        keynub::Context ctx;
        if (ctx.enumerate().empty()) {
            std::cout << "Connect a KeyNub dongle and re-run.\n";
            return 0;
        }

        keynub::Dongle dongle = ctx.open();
        std::cout << "dongle " << dongle.getSerial() << "\n";

        {
            keynub::Session session = dongle.openSession();
            session.authorizeWrite(current);
            session.rotateWriteKey(replacement);
            std::cout << "rotated: this dongle now answers only to your key\n";
        }

        // A fresh session is the only place the change is observable: the session
        // above keeps the role it was already granted.
        keynub::Session session = dongle.openSession();
        try {
            session.authorizeWrite(current);
            std::cerr << "WARNING: the old key still works -- do not ship this unit\n";
            return 1;
        } catch (const keynub::Error &) {
            std::cout << "confirmed: the old key no longer elevates\n";
        }
        session.authorizeWrite(replacement);
        std::cout << "confirmed: your key elevates\n";

        std::cout << "\nKeep the replacement key safe. Every future write to this "
                     "dongle needs it.\n";
        return 0;
    } catch (const keynub::Error &err) {
        std::cerr << "KeyNub error: " << err.what() << "\n";
        return 1;
    } catch (const std::exception &err) {
        std::cerr << err.what() << "\n";
        return 2;
    }
}
