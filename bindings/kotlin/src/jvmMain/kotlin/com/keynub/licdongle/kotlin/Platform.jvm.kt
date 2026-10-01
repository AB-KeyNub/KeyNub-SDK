package com.keynub.licdongle.kotlin

import com.sun.jna.Library
import com.sun.jna.Native
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock as reentrantWithLock

/** The flat C API as JNA maps it: int32_t* is IntArray, uint8_t* and char* buffers are ByteArray. */
@Suppress("FunctionName")
internal interface FlatLibrary : Library {
    fun licdf_version(major: IntArray, minor: IntArray, patch: IntArray): Int
    fun licdf_device_count(count: IntArray): Int
    fun licdf_device_serial(index: Int, out: ByteArray, size: Int): Int
    fun licdf_device_path(index: Int, out: ByteArray, size: Int): Int
    fun licdf_open(serialOrEmpty: String): Int
    fun licdf_open_path(path: String): Int
    fun licdf_close(handle: Int): Int
    fun licdf_set_trust_root(handle: Int, der: ByteArray, length: Int): Int
    fun licdf_get_serial(handle: Int, out: ByteArray, size: Int): Int
    fun licdf_get_info(
        handle: Int, protoMajor: IntArray, protoMinor: IntArray, fwMajor: IntArray, fwMinor: IntArray,
        fwPatch: IntArray, flags: IntArray, capacity: IntArray, free: IntArray,
    ): Int
    fun licdf_verify_genuine(handle: Int, genuine: IntArray, serial: ByteArray, serialSize: Int, date: ByteArray, dateSize: Int): Int
    fun licdf_session_open(handle: Int): Int
    fun licdf_session_close(handle: Int): Int
    fun licdf_write_auth(handle: Int, der: ByteArray, length: Int): Int
    fun licdf_write_auth_rotate(handle: Int, der: ByteArray, length: Int): Int
    fun licdf_record_count(handle: Int, count: IntArray): Int
    fun licdf_record_name(handle: Int, index: Int, out: ByteArray, size: Int, recordSize: IntArray): Int
    fun licdf_record_read(handle: Int, name: String, out: ByteArray, capacity: Int, length: IntArray): Int
    fun licdf_record_write(handle: Int, name: String, data: ByteArray, length: Int): Int
    fun licdf_record_erase(handle: Int, name: String): Int
    fun licdf_record_erase_all(handle: Int): Int
    fun licdf_counter_read(handle: Int, id: Int, value: IntArray): Int
    fun licdf_counter_increment(handle: Int, id: Int, value: IntArray): Int
    fun licdf_app_encrypt(handle: Int, scope: Int, data: ByteArray, length: Int, out: ByteArray, capacity: Int, outLength: IntArray): Int
    fun licdf_app_decrypt(handle: Int, data: ByteArray, length: Int, out: ByteArray, capacity: Int, outLength: IntArray): Int
    fun licdf_strerror(status: Int, out: ByteArray, size: Int): Int
    fun licdf_last_error(handle: Int, out: ByteArray, size: Int): Int
}

private class JnaFlat(private val lib: FlatLibrary) : FlatApi {
    override fun version(out: IntArray): Int {
        val a = IntArray(1)
        val b = IntArray(1)
        val c = IntArray(1)
        val rc = lib.licdf_version(a, b, c)
        out[0] = a[0]
        out[1] = b[0]
        out[2] = c[0]
        return rc
    }

    override fun deviceCount(out: IntArray) = lib.licdf_device_count(out)
    override fun deviceSerial(index: Int, out: ByteArray, size: Int) = lib.licdf_device_serial(index, out, size)
    override fun devicePath(index: Int, out: ByteArray, size: Int) = lib.licdf_device_path(index, out, size)
    override fun open(serialOrEmpty: String) = lib.licdf_open(serialOrEmpty)
    override fun openPath(path: String) = lib.licdf_open_path(path)
    override fun close(handle: Int) = lib.licdf_close(handle)
    override fun setTrustRoot(handle: Int, der: ByteArray, length: Int) = lib.licdf_set_trust_root(handle, der, length)
    override fun getSerial(handle: Int, out: ByteArray, size: Int) = lib.licdf_get_serial(handle, out, size)

    override fun getInfo(handle: Int, out: IntArray): Int {
        val slots = Array(8) { IntArray(1) }
        val rc = lib.licdf_get_info(handle, slots[0], slots[1], slots[2], slots[3], slots[4], slots[5], slots[6], slots[7])
        for (i in 0 until 8) out[i] = slots[i][0]
        return rc
    }

    override fun verifyGenuine(handle: Int, genuine: IntArray, serial: ByteArray, serialSize: Int, date: ByteArray, dateSize: Int) =
        lib.licdf_verify_genuine(handle, genuine, serial, serialSize, date, dateSize)

    override fun sessionOpen(handle: Int) = lib.licdf_session_open(handle)
    override fun sessionClose(handle: Int) = lib.licdf_session_close(handle)
    override fun writeAuth(handle: Int, der: ByteArray, length: Int) = lib.licdf_write_auth(handle, der, length)
    override fun writeAuthRotate(handle: Int, der: ByteArray, length: Int) = lib.licdf_write_auth_rotate(handle, der, length)
    override fun recordCount(handle: Int, out: IntArray) = lib.licdf_record_count(handle, out)
    override fun recordName(handle: Int, index: Int, out: ByteArray, size: Int, recordSize: IntArray) =
        lib.licdf_record_name(handle, index, out, size, recordSize)

    override fun recordRead(handle: Int, name: String, out: ByteArray, capacity: Int, length: IntArray) =
        lib.licdf_record_read(handle, name, out, capacity, length)

    override fun recordWrite(handle: Int, name: String, data: ByteArray, length: Int) = lib.licdf_record_write(handle, name, data, length)
    override fun recordErase(handle: Int, name: String) = lib.licdf_record_erase(handle, name)
    override fun recordEraseAll(handle: Int) = lib.licdf_record_erase_all(handle)
    override fun counterRead(handle: Int, id: Int, out: IntArray) = lib.licdf_counter_read(handle, id, out)
    override fun counterIncrement(handle: Int, id: Int, out: IntArray) = lib.licdf_counter_increment(handle, id, out)
    override fun appEncrypt(handle: Int, scope: Int, data: ByteArray, length: Int, out: ByteArray, capacity: Int, outLength: IntArray) =
        lib.licdf_app_encrypt(handle, scope, data, length, out, capacity, outLength)

    override fun appDecrypt(handle: Int, data: ByteArray, length: Int, out: ByteArray, capacity: Int, outLength: IntArray) =
        lib.licdf_app_decrypt(handle, data, length, out, capacity, outLength)

    override fun strerror(status: Int, out: ByteArray, size: Int) = lib.licdf_strerror(status, out, size)
    override fun lastError(handle: Int, out: ByteArray, size: Int) = lib.licdf_last_error(handle, out, size)
}

internal actual fun loadFlatApi(path: String): FlatApi {
    val lib = Native.load(path, FlatLibrary::class.java, mapOf(Library.OPTION_STRING_ENCODING to "UTF-8"))
    return JnaFlat(lib)
}

internal actual object Host {
    private val os = System.getProperty("os.name").lowercase()
    private val cpu = when (System.getProperty("os.arch").lowercase()) {
        "amd64", "x86_64" -> "x64"
        "aarch64", "arm64" -> "arm64"
        "x86", "i386", "i486", "i586", "i686" -> "x86"
        else -> System.getProperty("os.arch").lowercase()
    }

    actual val nativeFolder: String = when {
        os.startsWith("windows") -> "win-$cpu"
        os.startsWith("mac") || os.contains("darwin") -> "osx-$cpu"
        else -> "linux-$cpu"
    }

    actual val libraryFileName: String = when {
        os.startsWith("windows") -> "keynub_licdongle_flat.dll"
        os.startsWith("mac") || os.contains("darwin") -> "libkeynub_licdongle_flat.dylib"
        else -> "libkeynub_licdongle_flat.so"
    }

    actual fun environment(name: String): String? = System.getenv(name)
    actual fun isFile(path: String): Boolean = File(path).isFile
    actual fun currentDirectory(): String? = System.getProperty("user.dir")?.let { File(it).absolutePath }
    actual fun programDirectory(): String? = null
    actual fun parent(path: String): String? = File(path).absoluteFile.parent
    actual fun join(directory: String, vararg names: String): String = names.fold(File(directory)) { d, n -> File(d, n) }.path
}

internal actual class Lock actual constructor() {
    private val lock = ReentrantLock()
    actual fun <T> withLock(block: () -> T): T = lock.reentrantWithLock(block)
}
