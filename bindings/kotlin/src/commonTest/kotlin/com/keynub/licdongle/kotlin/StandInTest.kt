package com.keynub.licdongle.kotlin

import kotlin.test.Test
import kotlin.test.fail

/**
 * Every call against a stand-in for the flat C API (bindings/flat/licd_flat.c over
 * bindings/julia/test/stub/licd_stub.c): one imaginary dongle held in memory. The build compiles it and names it
 * in KEYNUB_LICDONGLE_FLAT_LIBRARY for the test run.
 */
class StandInTest {
    private val serial = "04A1B2C3D4E5F6"
    private val factoryKey = byteArrayOf(0x30, 0x10, 0x01, 0x02, 0x03)
    private val replacementKey = byteArrayOf(0x30, 0x11, 0x09, 0x08, 0x07, 0x06)

    private val failures = mutableListOf<String>()
    private var checks = 0

    private fun check(ok: Boolean, what: String) {
        checks += 1
        if (!ok) {
            failures += what
            println("FAILED: $what")
        }
    }

    private fun fails(status: Status, what: String, block: () -> Any?) {
        val got = try {
            block()
            null
        } catch (e: LicDongleException) {
            e.status
        }
        check(got == status, "$what: expected $status, got ${got ?: "no failure"}")
    }

    private inline fun <reified E : Throwable> throws(what: String, block: () -> Any?) {
        val thrown = try {
            block()
            false
        } catch (e: Throwable) {
            e is E
        }
        check(thrown, "$what: expected ${E::class.simpleName}")
    }

    @Test
    fun everyCallAgainstTheStandIn() {
        check(LicDongle.libraryVersion() == LibraryVersion(9, 8, 7), "library version")
        check(LicDongle.statusText(-2) == "no device", "status text")
        check(LicDongle.devices() == listOf(Device(serial, "stub:0")), "devices")
        fails(Status.NoDevice, "open by unknown serial") { LicDongle.open("nope") }
        fails(Status.NoDevice, "open by unknown path") { LicDongle.openPath("stub:9") }

        val d = LicDongle.open()
        check(d.isOpen, "open")
        check(d.serial == serial, "serial")
        check(
            d.info() == DeviceInfo(1, 0, 2, 3, 4, true, true, false, true, false, 1024L * 1024L, 1000000L),
            "info: ${d.info()}",
        )
        check(d.verifyGenuine() == Verification(serial, "2026-08-15"), "verifyGenuine")
        check(d.isGenuine(), "isGenuine")

        fails(Status.CertificateInvalid, "a malformed trust root") { d.setTrustRoot(byteArrayOf(0x02, 0x01, 0x00)) }
        val root = ByteArray(132) { 0xAB.toByte() }
        root[0] = 0x30
        root[1] = 0x82.toByte()
        root[2] = 0x01
        root[3] = 0x00
        d.setTrustRoot(root)
        fails(Status.CertificateInvalid, "verify against a foreign root") { d.verifyGenuine() }
        check(!d.isGenuine(), "isGenuine fails closed")
        for (k in 4 until root.size) root[k] = 0x01
        d.setTrustRoot(root)
        check(d.isGenuine(), "isGenuine after the right root")

        d.withSession { s ->
            val payload = "license-blob-0123456789"
            fails(Status.AuthRequired, "write before the write role") { s.write("lic", payload) }
            fails(Status.AuthRequired, "erase before the write role") { s.erase("lic") }
            fails(Status.AuthRequired, "increment before the write role") { s.incrementCounter(0) }
            fails(Status.NotGenuine, "write role with a bad key") { s.authorizeWrite(byteArrayOf(0x30, 0x00)) }
            s.authorizeWrite(factoryKey)
            s.write("lic", payload)
            check(s.readString("lic") == payload, "read back")
            s.write("cfg", "cfgdata".encodeToByteArray())
            val records = s.records().sortedBy { it.name }
            check(records.map { it.name } == listOf("cfg", "lic"), "record names")
            check(records[1].size == payload.length.toLong(), "record size")
            check(s.read("cfg").contentEquals("cfgdata".encodeToByteArray()), "second record")
            fails(Status.NotFound, "read a missing record") { s.read("nope") }
            fails(Status.NotFound, "erase a missing record") { s.erase("nope") }
            throws<IllegalArgumentException>("an empty name is refused for erase") { s.erase("") }
            throws<IllegalArgumentException>("an empty name is refused for read") { s.read("") }
            check(s.records().size == 2, "two records")
            s.erase("cfg")
            check(s.records().map { it.name } == listOf("lic"), "one record left")
            s.write("empty", ByteArray(0))
            check(s.read("empty").isEmpty(), "empty record")
            val big = ByteArray(3000) { (5 + 31 * it).toByte() }
            s.write("big", big)
            check(s.read("big").contentEquals(big), "a record bigger than one transfer chunk")

            val before = s.readCounter(0)
            check(s.incrementCounter(0) == before + 1, "increment")
            check(s.readCounter(0) == before + 1 && s.readCounter(1) == 0L, "counters")
            fails(Status.Range, "counter out of range") { s.readCounter(7) }

            val secret = ByteArray(100) { ((3 * it + 7) % 256).toByte() }
            for ((scope, value) in listOf(Scope.Device to 0, Scope.Developer to 1)) {
                val blob = s.appEncrypt(scope, secret)
                check(blob.size > secret.size, "sealed data is longer, $scope")
                check(blob[0].toInt() == value, "scope byte, $scope")
                check(s.appDecrypt(blob).contentEquals(secret), "round trip, $scope")
                val tampered = blob.copyOf()
                tampered[tampered.size - 1] = (tampered.last().toInt() xor 1).toByte()
                fails(Status.TagMismatch, "tampered data, $scope") { s.appDecrypt(tampered) }
            }
            check(s.appDecrypt(s.appEncrypt(Scope.Developer, "the data")).decodeToString() == "the data", "text")
            check(s.appDecrypt(s.appEncrypt(Scope.Device, ByteArray(0))).isEmpty(), "empty data")

            s.eraseAll()
            check(s.records().isEmpty(), "erase all")
            s.rotateWriteKey(replacementKey)
            s.write("lic", "still-writable")
        }
        check(d.info().writeAuthRotated, "rotated flag")
        d.withSession { s ->
            fails(Status.NotGenuine, "factory key after rotation") { s.authorizeWrite(factoryKey) }
            s.authorizeWrite(replacementKey)
            s.write("lic", "new-key-writes")
            check(s.readString("lic") == "new-key-writes", "write with the new key")
        }

        var kept: Session? = null
        check(d.withSession { kept = it; 42 } == 42, "withSession returns the value of its body")
        check(kept!!.isClosed, "and closes the session")
        val stale = d.openSession()
        val current = d.openSession()
        fails(Status.SessionExpired, "a new session ends the one before it") { stale.records() }
        stale.close()
        check(current.records().size == 1, "closing a stale session leaves the current one open")
        current.close()
        throws<IllegalStateException>("a closed session refuses calls") { current.readCounter(0) }
        val orphan = d.openSession()
        d.close()
        d.close()
        check(!d.isOpen, "closed")
        throws<IllegalStateException>("a session ends with its dongle") { orphan.records() }
        throws<IllegalStateException>("a closed dongle refuses calls") { d.serial }

        check(LicDongle.withDongle { it.serial } == serial, "withDongle")
        check(LicDongle.withDongle(serial) { dd -> dd.withSession { it.records().size } } >= 0, "withDongle(serial)")
        val leaked = LicDongle.withDongle { it }
        check(!leaked.isOpen, "closed after withDongle")
        check(LicDongle.loadedLibraryPath == LicDongle.libraryCandidates().first(), "loaded path")
        throws<LibraryException>("a second library is refused") { LicDongle.setLibraryPath("some/other/library") }

        if (failures.isEmpty()) {
            println("keynub-licdongle-kotlin: every call passed against the ABI stand-in ($checks checks)")
        } else {
            fail("${failures.size} of $checks check(s) failed: ${failures.joinToString("; ")}")
        }
    }
}
