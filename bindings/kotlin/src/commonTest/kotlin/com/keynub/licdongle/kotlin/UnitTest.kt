package com.keynub.licdongle.kotlin

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Checks that need neither the native library nor a dongle. */
class UnitTest {
    @Test
    fun statusCodes() {
        assertEquals(-2, Status.NoDevice.code)
        assertEquals(Status.TagMismatch, Status.fromCode(-10))
        assertNull(Status.fromCode(-999))
        assertEquals(20, Status.entries.size)
        assertEquals(Status.entries.size, Status.entries.map { it.code }.distinct().size)
    }

    @Test
    fun errorText() {
        val e = LicDongleException(Status.NotFound, -14, "licdf_record_read", "no record named x")
        assertEquals("licdf_record_read: NotFound (-14): no record named x", e.message)
        assertEquals("licdf_open: unknown (-99)", LicDongleException(null, -99, "licdf_open", "").message)
    }

    @Test
    fun cStrings() {
        assertEquals("abc", LicDongle.cString(byteArrayOf(0x61, 0x62, 0x63, 0, 0x64)))
        assertEquals("abc", LicDongle.cString(byteArrayOf(0x61, 0x62, 0x63)))
        assertEquals(1, LicDongle.pointerOf(ByteArray(0)).size)
    }

    @Test
    fun platformNames() {
        assertTrue(Host.nativeFolder.matches(Regex("(win|linux|osx)-(x64|x86|arm64)")), Host.nativeFolder)
        assertTrue(Host.libraryFileName.contains("keynub_licdongle_flat"))
        val base = Host.currentDirectory()!!
        val dir = Host.join(base, "natives", "x")
        assertEquals(base, Host.parent(Host.parent(dir)!!))
    }

    @Test
    fun argumentsAreCheckedBeforeTheLibrary() {
        assertFailsWith<IllegalArgumentException> { LicDongle.open("") }
        assertFailsWith<IllegalArgumentException> { LicDongle.openPath("") }
        assertFailsWith<IllegalArgumentException> { LicDongle.setLibraryPath("") }
    }
}
