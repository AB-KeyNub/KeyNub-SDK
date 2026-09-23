// Every call of the C++ wrapper (licdongle.hpp) against a stand-in for the C
// ABI: bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in
// memory, compiled into the same executable. Exit code 0 when every check
// passed.
//
//     cmake -S bindings/cpp/tests -B build-standin && cmake --build build-standin
//     build-standin/standin_test          (from the repository root)
//
// or with the compilers directly (C for the stand-in, C++11 for the test):
//
//     cc -c -DLICD_BUILD_SHARED -Iinclude bindings/julia/test/stub/licd_stub.c -o licd_stub.o
//     c++ -std=c++11 -DLICD_BUILD_SHARED -Iinclude -Ibindings/cpp bindings/cpp/tests/standin_test.cpp licd_stub.o -o standin_test

#include <algorithm>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "licdongle.hpp"

using keynub::Bytes;
using keynub::Status;

static int failures = 0;

static void check(bool condition, const char *what) {
    if (!condition) {
        failures++;
        std::printf("  FAIL  %s\n", what);
    }
}

template <typename F>
static void fails(Status status, const char *what, F action) {
    try {
        action();
        failures++;
        std::printf("  FAIL  %s: no failure\n", what);
    } catch (const keynub::Error &e) {
        if (e.status() != status) {
            failures++;
            std::printf("  FAIL  %s: %s\n", what, e.what());
        }
    }
}

static Bytes bytes(const std::string &text) { return Bytes(text.begin(), text.end()); }

static const char *kSerial = "04A1B2C3D4E5F6";
static const Bytes kFactoryKey = {0x30, 0x10, 0x01, 0x02, 0x03};
static const Bytes kReplacementKey = {0x30, 0x11, 0x09, 0x08, 0x07, 0x06};

int main() {
    keynub::Version v = keynub::Context::libraryVersion();
    check(v.major == 9 && v.minor == 8 && v.patch == 7, "library version");
    check(v.toString() == "9.8.7", "version text");

    keynub::Context ctx;
    std::vector<keynub::DeviceInfo> found = ctx.enumerate();
    check(found.size() == 1 && found[0].serial == kSerial && found[0].path == "stub:0", "enumerate");
    fails(Status::NoDevice, "open by unknown serial", [&] { ctx.open("nope"); });
    fails(Status::NoDevice, "open by unknown path", [&] { ctx.openPath("stub:9"); });
    try {
        ctx.open("nope");
    } catch (const keynub::DeviceNotFoundError &) {
        check(true, "DeviceNotFoundError");
    } catch (...) {
        check(false, "DeviceNotFoundError");
    }

    keynub::Dongle d = ctx.open();
    check(d.isOpen(), "open");
    check(d.getSerial() == kSerial, "serial");
    keynub::Info i = d.getInfo();
    check(i.protocolMajor == 1 && i.protocolMinor == 0, "protocol version");
    check(i.firmwareMajor == 2 && i.firmwareMinor == 3 && i.firmwarePatch == 4, "firmware version");
    check(i.seReady && i.provisioned && i.isolated, "flags set");
    check(!i.watchdogReboot && !i.writeAuthRotated, "flags clear");
    check(i.dataCapacity == 1024 * 1024 && i.dataFree == 1000000, "capacity");
    keynub::GenuineResult g = d.verifyGenuine();
    check(g.genuine && g.serial == kSerial && g.provisionedDate == "2026-08-15", "genuine");
    check(d.isGenuine(), "isGenuine");

    fails(Status::CertificateInvalid, "malformed trust root", [&] { ctx.setTrustRoot({0x02, 0x01, 0x00}); });
    Bytes root = {0x30, 0x82, 0x01, 0x00};
    root.resize(132, 0xAB);
    ctx.setTrustRoot(root);
    fails(Status::CertificateInvalid, "verify against a foreign root", [&] { d.verifyGenuine(); });
    check(!d.isGenuine(), "isGenuine fails closed");
    std::fill(root.begin() + 4, root.end(), 0x01);
    ctx.setTrustRoot(root);
    check(d.isGenuine(), "isGenuine after the right root");

    {
        keynub::Session s = d.openSession();
        check(s.isOpen(), "session open");
        const Bytes payload = bytes("license-blob-0123456789");
        fails(Status::AuthRequired, "write before the write role", [&] { s.writeRecord("lic", payload); });
        fails(Status::NotGenuine, "write role with a bad key", [&] { s.authorizeWrite({0x30, 0x00}); });
        s.authorizeWrite(kFactoryKey);
        s.writeRecord("lic", payload);
        check(s.readRecord("lic") == payload, "read back");
        s.writeRecord("cfg", bytes("cfgdata"));
        std::vector<keynub::RecordInfo> recs = s.listRecords();
        std::vector<std::string> names;
        for (const keynub::RecordInfo &r : recs) {
            names.push_back(r.name);
        }
        std::sort(names.begin(), names.end());
        check(names == std::vector<std::string>({"cfg", "lic"}), "record names");
        check(std::any_of(recs.begin(), recs.end(),
                          [&](const keynub::RecordInfo &r) { return r.name == "lic" && r.size == payload.size(); }),
              "record size");
        check(s.readRecord("cfg") == bytes("cfgdata"), "second record");
        fails(Status::NotFound, "read a missing record", [&] { s.readRecord("nope"); });
        fails(Status::InvalidArgument, "erase with an empty name", [&] { s.eraseRecord(""); });
        check(s.listRecords().size() == 2, "two records");
        s.eraseRecord("cfg");
        check(s.listRecords().size() == 1 && s.listRecords()[0].name == "lic", "one record left");
        s.writeRecord("empty", Bytes());
        check(s.readRecord("empty").empty(), "empty record");

        // A record bigger than one transfer chunk, with progress reported.
        Bytes big(3000, 0x5A);
        uint32_t lastDone = 0;
        s.writeRecord("big", big, [&](uint32_t done, uint32_t) {
            lastDone = done;
            return true;
        });
        check(lastDone == big.size(), "write progress");
        lastDone = 0;
        check(s.readRecord("big", [&](uint32_t done, uint32_t) {
            lastDone = done;
            return true;
        }) == big, "multi-chunk read");
        check(lastDone == big.size(), "read progress");
        fails(Status::Cancelled, "cancelled transfer", [&] {
            s.readRecord("big", [](uint32_t, uint32_t) { return false; });
        });
        s.eraseRecord("big");

        uint32_t before = s.readCounter(0);
        check(s.incrementCounter(0) == before + 1, "increment");
        check(s.readCounter(0) == before + 1 && s.readCounter(1) == 0, "counters");
        fails(Status::Range, "counter out of range", [&] { s.readCounter(7); });

        Bytes secret(100);
        for (size_t k = 0; k < secret.size(); k++) {
            secret[k] = static_cast<uint8_t>((3 * k + 7) % 256);
        }
        for (keynub::Scope scope : {keynub::Scope::Device, keynub::Scope::Developer}) {
            Bytes blob = s.appEncrypt(scope, secret);
            check(blob.size() > secret.size(), "sealed data is longer");
            check(blob[0] == static_cast<uint8_t>(scope), "scope byte");
            check(s.appDecrypt(blob) == secret, "round trip");
            Bytes tampered = blob;
            tampered.back() ^= 1;
            fails(Status::TagMismatch, "tampered blob", [&] { s.appDecrypt(tampered); });
        }

        s.eraseAllRecords();
        check(s.listRecords().empty(), "erase all");

        s.rotateWriteKey(kReplacementKey);
        s.writeRecord("lic", bytes("still-writable"));
    }
    // The session ended when it left scope.
    check(d.getInfo().writeAuthRotated, "rotated flag");
    {
        keynub::Session s = d.openSession();
        fails(Status::NotGenuine, "factory key after rotation", [&] { s.authorizeWrite(kFactoryKey); });
        s.authorizeWrite(kReplacementKey);
        s.writeRecord("lic", bytes("new-key-writes"));
        check(s.readRecord("lic") == bytes("new-key-writes"), "write with the new key");

        keynub::Session moved = std::move(s);
        check(!s.isOpen() && moved.isOpen(), "session moves");
        moved.close();
        check(!moved.isOpen(), "session close");
        moved.close();
    }

    // A session that outlives its dongle refuses to work instead of touching freed memory.
    keynub::Session orphan = d.openSession();
    d.close();
    check(!d.isOpen(), "dongle close");
    check(!orphan.isOpen(), "session ends with its dongle");
    fails(Status::InvalidArgument, "serial after close", [&] { d.getSerial(); });
    fails(Status::InvalidArgument, "session after its dongle closed", [&] { orphan.readCounter(0); });

    keynub::Dongle again = ctx.open(kSerial);
    keynub::Dongle moved = std::move(again);
    check(moved.isOpen() && !again.isOpen(), "dongle moves");

    if (failures) {
        std::printf("%d check(s) failed\n", failures);
        return 1;
    }
    std::printf("licdongle.hpp: every call passed against the ABI stand-in\n");
    return 0;
}
