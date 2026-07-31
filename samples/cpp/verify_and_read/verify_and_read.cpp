// KeyNub dongle check from C++: enumerate -> open -> verify -> session ->
// read a record -> app-crypto round trip.
//
// Build it with the SDK's CMake project (-DLICD_BUILD_SAMPLES=ON), or compile it
// straight against a release archive:
//
//   c++ -std=c++11 verify_and_read.cpp -Iinclude -Ibindings/cpp -Lx64 \
//       -lkeynub_licdongle -o verify_and_read
//
// The binding is header-only (bindings/cpp/licdongle.hpp) over the same C ABI
// every other language uses. What it adds is worth having in C++ specifically:
// destructors close the device and the session on every path out, including when
// an exception unwinds, and failures arrive as typed exceptions carrying the
// SDK's own diagnostic text instead of an int you have to remember to check.
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// READ FIRST: docs/integration-security.md. This sample prints whether the dongle
// is genuine, which is the one thing a real licence check must not do — a printed
// boolean is a deleted line away from nothing. The last function shows the shape
// that actually protects something.

#include <licdongle.hpp>

#include <cstdint>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

namespace {

void report(keynub::Dongle &dongle) {
    const keynub::Info info = dongle.getInfo();
    // Unary + promotes the uint8_t fields so they print as numbers, not characters.
    std::cout << "Protocol v" << +info.protocolMajor << "." << +info.protocolMinor
              << ", firmware v" << +info.firmwareMajor << "." << +info.firmwareMinor
              << "." << +info.firmwarePatch << ", " << info.dataFree << " of "
              << info.dataCapacity << " bytes free.\n";

    if (info.watchdogReboot) {
        // The only trace a firmware hang leaves behind. Worth reporting to support.
        std::cout << "WARNING: this dongle's previous boot ended in a watchdog reset.\n";
    }

    const keynub::GenuineResult result = dongle.verifyGenuine();
    std::cout << "Genuine: " << std::boolalpha << result.genuine
              << " (serial " << result.serial << ", batch " << result.batch << ")\n";
}

void readRecords(keynub::Session &session) {
    const std::vector<keynub::RecordInfo> records = session.listRecords();
    std::cout << records.size() << " record(s) on the dongle:\n";
    for (const keynub::RecordInfo &record : records) {
        std::cout << "  " << std::left << std::setw(16) << record.name
                  << std::right << std::setw(6) << record.size << " bytes\n";
    }

    for (const keynub::RecordInfo &record : records) {
        if (record.name == "license") {
            const keynub::Bytes data = session.readRecord("license");
            std::cout << "Read " << data.size() << " bytes from the license record.\n";
            break;
        }
    }
}

// The part that actually protects something. At licence-issue time you would call
// appEncrypt once, with a developer dongle, and ship only the blob; the application
// then cannot proceed without a dongle, because it holds no other copy of the data.
// Scope::Developer lets any dongle from your batch decrypt it, so one file serves
// every customer; Scope::Device locks it to one dongle.
void protectSomething(keynub::Session &session) {
    const std::string text = "the data this program cannot run without";
    const keynub::Bytes needed(text.begin(), text.end());

    const keynub::Bytes sealed = session.appEncrypt(keynub::Scope::Developer, needed);
    const keynub::Bytes recovered = session.appDecrypt(sealed);

    std::cout << "App-crypto round trip: " << needed.size() << " bytes -> "
              << sealed.size() << " sealed -> "
              << (recovered == needed ? "recovered intact" : "MISMATCH") << "\n";
}

}  // namespace

int main() {
    std::cout << "KeyNub SDK " << keynub::Context::libraryVersion().toString() << "\n";

    try {
        keynub::Context ctx;

        const std::vector<keynub::DeviceInfo> devices = ctx.enumerate();
        std::cout << "Found " << devices.size() << " KeyNub dongle(s).\n";
        for (std::size_t i = 0; i < devices.size(); ++i) {
            std::cout << "  [" << i << "] serial " << devices[i].serial << " (VID "
                      << std::hex << std::uppercase << std::setw(4) << std::setfill('0')
                      << devices[i].vendorId << " PID " << std::setw(4)
                      << devices[i].productId << std::dec << std::setfill(' ') << ")\n";
        }
        if (devices.empty()) {
            std::cout << "No dongle attached; nothing to do.\n";
            return 0;
        }

        // First dongle; pass a serial to open() to pick a specific one. Both the
        // dongle and the session close themselves when they leave scope.
        keynub::Dongle dongle = ctx.open();
        report(dongle);

        keynub::Session session = dongle.openSession();
        readRecords(session);
        protectSomething(session);

    } catch (const keynub::Error &err) {
        // status() distinguishes the cases; what() carries the SDK's diagnostic
        // text, which is what tells "no dongle" from "certificate rejected".
        std::cerr << "KeyNub error (" << static_cast<int>(err.status()) << "): "
                  << err.what() << "\n";
        return 1;
    }

    return 0;
}
