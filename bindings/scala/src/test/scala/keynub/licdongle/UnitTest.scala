package keynub.licdongle

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

/** Checks that need neither the native library nor a dongle. */
class UnitTest:

  @Test def statusCodes(): Unit =
    assertEquals(-2, Status.NoDevice.code)
    assertEquals(Status.TagMismatch, Status.fromCode(-10))
    assertEquals(Status.Internal, Status.fromCode(-999))
    assertEquals(20, Status.values.length)
    assertEquals(Status.values.length, Status.values.map(_.code).distinct.length)

  @Test def platformFolders(): Unit =
    assertEquals(("win-x64", "keynub_licdongle.dll"), LicDongle.platform("Windows 11", "amd64"))
    assertEquals(("win-x86", "keynub_licdongle.dll"), LicDongle.platform("Windows 10", "x86"))
    assertEquals(("linux-arm64", "libkeynub_licdongle.so"), LicDongle.platform("Linux", "aarch64"))
    assertEquals(("osx-arm64", "libkeynub_licdongle.dylib"), LicDongle.platform("Mac OS X", "aarch64"))
    assertEquals(("osx-x64", "libkeynub_licdongle.dylib"), LicDongle.platform("Darwin", "x86_64"))

  @Test def errorsCarryStatusAndDetail(): Unit =
    val e = LicDongleError(Status.NotFound, "not found", "no record named x", null)
    assertEquals(-14, e.code)
    assertEquals("no record named x", e.detail)
    assertTrue(e.isInstanceOf[RuntimeException])

  @Test def argumentsAreCheckedBeforeTheLibrary(): Unit =
    assertThrows(classOf[IllegalArgumentException], () => LicDongle.open(""))
    assertThrows(classOf[IllegalArgumentException], () => LicDongle.openPath(""))
    assertThrows(classOf[IllegalArgumentException], () => LicDongle.setLibraryPath(""))

  @Test def models(): Unit =
    assertEquals(Record("lic", 3), Record("lic", 3))
    assertEquals("Developer", Scope.Developer.toString)
