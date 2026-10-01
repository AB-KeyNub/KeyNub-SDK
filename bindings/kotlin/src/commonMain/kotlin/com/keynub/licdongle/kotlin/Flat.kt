package com.keynub.licdongle.kotlin

/**
 * The SDK's flat C API (bindings/flat/licd_flat.h): integer handles and caller-provided buffers. Out-parameters
 * are IntArray slots; every function returns the status code, except open and openPath, which return a handle or
 * a negative status.
 */
internal interface FlatApi {
    fun version(out: IntArray): Int
    fun deviceCount(out: IntArray): Int
    fun deviceSerial(index: Int, out: ByteArray, size: Int): Int
    fun devicePath(index: Int, out: ByteArray, size: Int): Int
    fun open(serialOrEmpty: String): Int
    fun openPath(path: String): Int
    fun close(handle: Int): Int
    fun setTrustRoot(handle: Int, der: ByteArray, length: Int): Int
    fun getSerial(handle: Int, out: ByteArray, size: Int): Int

    /** out: protocol major, protocol minor, firmware major, minor, patch, flags, capacity, free. */
    fun getInfo(handle: Int, out: IntArray): Int
    fun verifyGenuine(handle: Int, genuine: IntArray, serial: ByteArray, serialSize: Int, date: ByteArray, dateSize: Int): Int
    fun sessionOpen(handle: Int): Int
    fun sessionClose(handle: Int): Int
    fun writeAuth(handle: Int, der: ByteArray, length: Int): Int
    fun writeAuthRotate(handle: Int, der: ByteArray, length: Int): Int
    fun recordCount(handle: Int, out: IntArray): Int
    fun recordName(handle: Int, index: Int, out: ByteArray, size: Int, recordSize: IntArray): Int
    fun recordRead(handle: Int, name: String, out: ByteArray, capacity: Int, length: IntArray): Int
    fun recordWrite(handle: Int, name: String, data: ByteArray, length: Int): Int
    fun recordErase(handle: Int, name: String): Int
    fun recordEraseAll(handle: Int): Int
    fun counterRead(handle: Int, id: Int, out: IntArray): Int
    fun counterIncrement(handle: Int, id: Int, out: IntArray): Int
    fun appEncrypt(handle: Int, scope: Int, data: ByteArray, length: Int, out: ByteArray, capacity: Int, outLength: IntArray): Int
    fun appDecrypt(handle: Int, data: ByteArray, length: Int, out: ByteArray, capacity: Int, outLength: IntArray): Int
    fun strerror(status: Int, out: ByteArray, size: Int): Int
    fun lastError(handle: Int, out: ByteArray, size: Int): Int
}

/** Loads the flat API from the library file at path; throws with the reason when it cannot. */
internal expect fun loadFlatApi(path: String): FlatApi

/** What the library lookup needs from the platform. */
internal expect object Host {
    /** The natives/ folder name of this platform, such as "win-x64". */
    val nativeFolder: String

    /** The library's file name on this operating system. */
    val libraryFileName: String

    fun environment(name: String): String?
    fun isFile(path: String): Boolean
    fun currentDirectory(): String?

    /** The folder of the running program, when it is known. */
    fun programDirectory(): String?

    /** The parent folder of path, or null at the root. */
    fun parent(path: String): String?
    fun join(directory: String, vararg names: String): String
}

/** A mutual-exclusion lock. */
internal expect class Lock() {
    fun <T> withLock(block: () -> T): T
}
