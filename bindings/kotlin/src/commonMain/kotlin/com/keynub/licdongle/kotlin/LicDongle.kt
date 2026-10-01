package com.keynub.licdongle.kotlin

/** The native library's version. */
public data class LibraryVersion(val major: Int, val minor: Int, val patch: Int) {
    override fun toString(): String = "$major.$minor.$patch"
}

/** An attached dongle, found without opening it; [path] is the operating system's device path. */
public data class Device(val serial: String, val path: String)

/** A dongle's protocol and firmware versions, storage (in bytes) and status flags. */
public data class DeviceInfo(
    val protocolMajor: Int,
    val protocolMinor: Int,
    val firmwareMajor: Int,
    val firmwareMinor: Int,
    val firmwarePatch: Int,
    val secureElementReady: Boolean,
    val provisioned: Boolean,
    val watchdogReboot: Boolean,
    val isolated: Boolean,
    val writeAuthRotated: Boolean,
    val dataCapacity: Long,
    val dataFree: Long,
)

/** The result of [Dongle.verifyGenuine]; [provisionedDate] is YYYY-MM-DD. */
public data class Verification(val serial: String, val provisionedDate: String)

/** A record on the dongle and its size in bytes. */
public data class Record(val name: String, val size: Long)

/** Where the data of an [Session.appEncrypt] envelope can be decrypted. */
public enum class Scope(internal val value: Int) {
    /** Only the dongle that sealed it. */
    Device(0),

    /** Every dongle issued to the same developer. */
    Developer(1),
}

/**
 * Client for the KeyNub USB license dongle over the SDK's flat C API, loaded from the native library at run time
 * on the first call that needs it.
 *
 * ```
 * val secret = LicDongle.withDongle { dongle ->   // the first dongle, or withDongle(serial) { ... }
 *     dongle.verifyGenuine()                      // throws unless genuine
 *     dongle.withSession { session ->             // closed on every exit path
 *         session.appDecrypt(sealedBytes)         // build the licence check on this
 *     }
 * }
 * ```
 */
public object LicDongle {
    /** The environment variable that names the native library file. */
    public const val LIBRARY_ENVIRONMENT_VARIABLE: String = "KEYNUB_LICDONGLE_FLAT_LIBRARY"

    internal const val SERIAL_SIZE = 15
    internal const val DATE_SIZE = 11
    internal const val PATH_SIZE = 512
    internal const val ERROR_SIZE = 256
    internal const val NAME_SIZE = 256

    private val nativeFolders = listOf("win-x64", "win-x86", "win-arm64", "linux-x64", "linux-arm64", "osx-x64", "osx-arm64")

    private val lock = Lock()
    private var chosenPath: String? = null
    private var loadedPath: String? = null
    private var api: FlatApi? = null

    /** Names the library file to load. Call it before the first dongle call; a process loads the library once. */
    public fun setLibraryPath(path: String) {
        require(path.isNotEmpty()) { "the library path must not be empty" }
        lock.withLock {
            val loaded = loadedPath
            if (loaded != null && loaded != path) {
                throw LibraryException("the KeyNub library is already loaded from $loaded; a process loads it once")
            }
            chosenPath = path
        }
    }

    /** The path of the loaded library; null before the first call. */
    public val loadedLibraryPath: String?
        get() = lock.withLock { loadedPath }

    /**
     * The paths tried, in order: the one given to [setLibraryPath], else KEYNUB_LICDONGLE_FLAT_LIBRARY, else
     * natives/<platform>/ of an SDK clone from the program's folder and the current directory upwards, then the
     * bare file name for the system loader.
     */
    public fun libraryCandidates(): List<String> = candidates(lock.withLock { chosenPath })

    private fun candidates(chosen: String?): List<String> {
        chosen?.let { return listOf(it) }
        Host.environment(LIBRARY_ENVIRONMENT_VARIABLE)?.takeIf { it.isNotEmpty() }?.let { return listOf(it) }
        val file = Host.libraryFileName
        val found = listOfNotNull(Host.programDirectory(), Host.currentDirectory())
            .distinct()
            .flatMap { start -> generateSequence(start) { Host.parent(it) }.toList() }
            .flatMap { dir -> nativeFolders.map { Host.join(dir, "natives", it, file) } }
            .filter { Host.isFile(it) }
            .distinct()
        return found + file
    }

    internal fun flat(): FlatApi = lock.withLock { api ?: load() }

    /** Loads the first candidate that works; called with the lock held. */
    private fun load(): FlatApi {
        val reasons = mutableListOf<String>()
        for (path in candidates(chosenPath)) {
            try {
                val loaded = loadFlatApi(path)
                api = loaded
                loadedPath = path
                return loaded
            } catch (e: Throwable) {
                reasons += "$path (${e.message})"
            }
        }
        throw LibraryException("cannot load the KeyNub library; tried ${reasons.joinToString(", ")}")
    }

    /** The native library's version, which is the SDK version it was built from. */
    public fun libraryVersion(): LibraryVersion {
        val out = IntArray(3)
        check("licdf_version", 0, flat().version(out))
        return LibraryVersion(out[0], out[1], out[2])
    }

    /** Human-readable text for a status code; needs no dongle. */
    public fun statusText(code: Int): String {
        val text = ByteArray(ERROR_SIZE)
        return if (flat().strerror(code, text, ERROR_SIZE) == 0) cString(text) else Status.fromCode(code)?.name ?: "unknown"
    }

    /** The attached dongles, without opening any. */
    public fun devices(): List<Device> {
        val f = flat()
        val count = IntArray(1)
        check("licdf_device_count", 0, f.deviceCount(count))
        return (0 until count[0]).map { i ->
            val text = ByteArray(PATH_SIZE)
            check("licdf_device_serial", 0, f.deviceSerial(i, text, PATH_SIZE))
            val serial = cString(text)
            check("licdf_device_path", 0, f.devicePath(i, text.also { it.fill(0) }, PATH_SIZE))
            Device(serial, cString(text))
        }
    }

    /** Opens the dongle with this serial, or the first one found when [serial] is null. */
    public fun open(serial: String? = null): Dongle {
        require(serial == null || serial.isNotEmpty()) { "the serial must not be empty" }
        val handle = flat().open(serial ?: "")
        if (handle < 0) throw error("licdf_open", handle, "")
        return Dongle(handle)
    }

    /** Opens the dongle at this device path (from [devices]). */
    public fun openPath(path: String): Dongle {
        require(path.isNotEmpty()) { "the path must not be empty" }
        val handle = flat().openPath(path)
        if (handle < 0) throw error("licdf_open_path", handle, "")
        return Dongle(handle)
    }

    /** Opens the first dongle, or the one with [serial], passes it to [block] and closes it on every exit path. */
    public inline fun <T> withDongle(serial: String? = null, block: (Dongle) -> T): T = open(serial).use(block)

    // --- helpers --------------------------------------------------------

    internal fun error(operation: String, code: Int, detail: String): LicDongleException =
        LicDongleException(Status.fromCode(code), code, operation, detail)

    internal fun check(operation: String, handle: Int, rc: Int) {
        if (rc != 0) throw error(operation, rc, if (handle > 0) detailOf(handle) else "")
    }

    internal fun detailOf(handle: Int): String = try {
        val text = ByteArray(ERROR_SIZE)
        if (flat().lastError(handle, text, ERROR_SIZE) == 0) cString(text) else ""
    } catch (e: Exception) {
        ""
    }

    /** A buffer the library can read even for empty data. */
    internal fun pointerOf(data: ByteArray): ByteArray = if (data.isEmpty()) ByteArray(1) else data

    /** The text before the first NUL byte, decoded as UTF-8. */
    internal fun cString(buffer: ByteArray): String {
        val end = buffer.indexOf(0).let { if (it < 0) buffer.size else it }
        return buffer.decodeToString(0, end)
    }

    /**
     * The two-call convention: ask for the size with a capacity of 0, then read into a buffer of that size. [call]
     * takes the buffer, its capacity and the length slot and returns the status.
     */
    internal fun readSized(handle: Int, operation: String, call: (ByteArray, Int, IntArray) -> Int): ByteArray {
        val needed = IntArray(1)
        val rc = call(ByteArray(1), 0, needed)
        if (rc == 0) return ByteArray(0)
        if (rc != Status.Range.code) throw error(operation, rc, detailOf(handle))
        val data = ByteArray(maxOf(needed[0], 1))
        val written = IntArray(1)
        check(operation, handle, call(data, needed[0], written))
        return data.copyOf(written[0])
    }
}

/** An open dongle. Closing it also ends its session; closing twice is allowed. */
public class Dongle internal constructor(handle: Int) : AutoCloseable {
    private var handle: Int = handle
    internal var sessionGeneration: Int = 0
    internal var sessionOpen: Boolean = false

    /** Whether [close] has not been called yet. */
    public val isOpen: Boolean
        get() = handle > 0

    internal fun handle(): Int {
        check(handle > 0) { "the dongle has been closed" }
        return handle
    }

    /** The dongle's serial number (14 hex digits). */
    public val serial: String
        get() {
            val h = handle()
            val text = ByteArray(LicDongle.SERIAL_SIZE)
            LicDongle.check("licdf_get_serial", h, LicDongle.flat().getSerial(h, text, LicDongle.SERIAL_SIZE))
            return LicDongle.cString(text)
        }

    /** The dongle's protocol and firmware versions, storage and status flags. */
    public fun info(): DeviceInfo {
        val h = handle()
        val out = IntArray(8)
        LicDongle.check("licdf_get_info", h, LicDongle.flat().getInfo(h, out))
        val flags = out[5]
        return DeviceInfo(
            out[0], out[1], out[2], out[3], out[4],
            secureElementReady = flags and 0x01 != 0,
            provisioned = flags and 0x02 != 0,
            watchdogReboot = flags and 0x04 != 0,
            isolated = flags and 0x08 != 0,
            writeAuthRotated = flags and 0x10 != 0,
            dataCapacity = out[6].toLong() and 0xFFFFFFFFL,
            dataFree = out[7].toLong() and 0xFFFFFFFFL,
        )
    }

    /**
     * Proves the dongle is genuine: its certificate chain to the trusted root plus a live challenge-response.
     * Returns only when it is; throws with [Status.NotGenuine] or [Status.CertificateInvalid] otherwise.
     */
    public fun verifyGenuine(): Verification {
        val h = handle()
        val genuine = IntArray(1)
        val serialText = ByteArray(LicDongle.SERIAL_SIZE)
        val dateText = ByteArray(LicDongle.DATE_SIZE)
        LicDongle.check(
            "licdf_verify_genuine", h,
            LicDongle.flat().verifyGenuine(h, genuine, serialText, LicDongle.SERIAL_SIZE, dateText, LicDongle.DATE_SIZE),
        )
        if (genuine[0] == 0) throw LicDongle.error("licdf_verify_genuine", Status.NotGenuine.code, "")
        return Verification(LicDongle.cString(serialText), LicDongle.cString(dateText))
    }

    /**
     * true only when [verifyGenuine] succeeds. Fails closed: every failure, a closed dongle included, gives false.
     *
     * `if (!dongle.isGenuine()) exitProcess(1)` is one branch to patch out. Put data the program needs through
     * [Session.appEncrypt] and ship only the sealed form.
     */
    public fun isGenuine(): Boolean = try {
        verifyGenuine()
        true
    } catch (e: Throwable) {
        false
    }

    /** Replaces the root certificate (DER) that [verifyGenuine] checks against. Applications do not need this. */
    public fun setTrustRoot(der: ByteArray) {
        val h = handle()
        LicDongle.check("licdf_set_trust_root", h, LicDongle.flat().setTrustRoot(h, LicDongle.pointerOf(der), der.size))
    }

    /** Diagnostic detail for the most recent failure on this dongle; may be empty. */
    public fun lastError(): String = LicDongle.detailOf(handle())

    /**
     * Opens the encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM) that records, counters and app encryption
     * need. A dongle has one session at a time: opening another ends the one before it.
     */
    public fun openSession(): Session {
        val h = handle()
        LicDongle.check("licdf_session_open", h, LicDongle.flat().sessionOpen(h))
        sessionGeneration += 1
        sessionOpen = true
        return Session(this, sessionGeneration)
    }

    /** Opens a session, passes it to [block] and closes it on every exit path. Returns what [block] returns. */
    public inline fun <T> withSession(block: (Session) -> T): T = openSession().use(block)

    override fun close() {
        val h = handle
        if (h > 0) {
            handle = 0
            sessionOpen = false
            LicDongle.check("licdf_close", h, LicDongle.flat().close(h))
        }
    }
}

/** An encrypted session on a dongle. Closing the dongle ends it too; closing twice is allowed. */
public class Session internal constructor(private val dongle: Dongle, private val generation: Int) : AutoCloseable {
    private var closed = false

    /** Whether the session has been closed. */
    public val isClosed: Boolean
        get() = closed || !dongle.isOpen

    private fun handle(): Int {
        check(!closed) { "the session has been closed" }
        val h = dongle.handle()
        if (generation != dongle.sessionGeneration || !dongle.sessionOpen) {
            throw LicDongle.error("session", Status.SessionExpired.code, "a newer session on this dongle ended this one")
        }
        return h
    }

    private fun name(name: String): String {
        require(name.isNotEmpty()) { "the record name must not be empty" }
        return name
    }

    /**
     * Unlocks writing, erasing and counter increments for the rest of the session with the dongle's write key, a
     * P-256 private key in PKCS#8 DER. This belongs in your licence-issuing tooling; never ship that key with what
     * your users run. A key the dongle does not accept throws with [Status.NotGenuine].
     */
    public fun authorizeWrite(key: ByteArray) {
        val h = handle()
        LicDongle.check("licdf_write_auth", h, LicDongle.flat().writeAuth(h, LicDongle.pointerOf(key), key.size))
    }

    /**
     * Replaces the dongle's write key with one you hold (PKCS#8 DER). Needs the write role. From the next session
     * on only the new key elevates. Do this once per dongle, when it arrives: the factory key is public.
     */
    public fun rotateWriteKey(key: ByteArray) {
        val h = handle()
        LicDongle.check("licdf_write_auth_rotate", h, LicDongle.flat().writeAuthRotate(h, LicDongle.pointerOf(key), key.size))
    }

    /** The records on the dongle. */
    public fun records(): List<Record> {
        val h = handle()
        val f = LicDongle.flat()
        val count = IntArray(1)
        LicDongle.check("licdf_record_count", h, f.recordCount(h, count))
        return (0 until count[0]).map { i ->
            val text = ByteArray(LicDongle.NAME_SIZE)
            val size = IntArray(1)
            LicDongle.check("licdf_record_name", h, f.recordName(h, i, text, LicDongle.NAME_SIZE, size))
            Record(LicDongle.cString(text), size[0].toLong() and 0xFFFFFFFFL)
        }
    }

    /** Reads a record. A record that does not exist throws with [Status.NotFound]. */
    public fun read(name: String): ByteArray {
        val h = handle()
        val n = name(name)
        return LicDongle.readSized(h, "licdf_record_read") { buffer, capacity, length ->
            LicDongle.flat().recordRead(h, n, buffer, capacity, length)
        }
    }

    /** Reads a record as UTF-8 text. */
    public fun readString(name: String): String = read(name).decodeToString()

    /** Creates or replaces a record atomically. Needs the write role. */
    public fun write(name: String, data: ByteArray) {
        val h = handle()
        LicDongle.check("licdf_record_write", h, LicDongle.flat().recordWrite(h, name(name), LicDongle.pointerOf(data), data.size))
    }

    /** Creates or replaces a record with text, stored as UTF-8. Needs the write role. */
    public fun write(name: String, text: String): Unit = write(name, text.encodeToByteArray())

    /** Erases one record. Needs the write role. An empty name is refused, so this never erases more than one. */
    public fun erase(name: String) {
        val h = handle()
        LicDongle.check("licdf_record_erase", h, LicDongle.flat().recordErase(h, name(name)))
    }

    /** Erases every record on the dongle. Needs the write role. */
    public fun eraseAll() {
        val h = handle()
        LicDongle.check("licdf_record_erase_all", h, LicDongle.flat().recordEraseAll(h))
    }

    /** Reads a monotonic counter (an id from 0 upwards). */
    public fun readCounter(id: Int): Long {
        val h = handle()
        val out = IntArray(1)
        LicDongle.check("licdf_counter_read", h, LicDongle.flat().counterRead(h, id, out))
        return out[0].toLong() and 0xFFFFFFFFL
    }

    /** Increments a monotonic counter and returns its new value. Needs the write role; it cannot be undone. */
    public fun incrementCounter(id: Int): Long {
        val h = handle()
        val out = IntArray(1)
        LicDongle.check("licdf_counter_increment", h, LicDongle.flat().counterIncrement(h, id, out))
        return out[0].toLong() and 0xFFFFFFFFL
    }

    /**
     * Encrypts data so that only a dongle can decrypt it and returns the sealed bytes. Put something the program
     * needs through this and ship only the sealed form, so removing the check removes the data. [Scope.Developer]
     * lets any dongle you have issued decrypt it; [Scope.Device] locks it to this dongle.
     */
    public fun appEncrypt(scope: Scope, data: ByteArray): ByteArray {
        val h = handle()
        val input = LicDongle.pointerOf(data)
        return LicDongle.readSized(h, "licdf_app_encrypt") { buffer, capacity, length ->
            LicDongle.flat().appEncrypt(h, scope.value, input, data.size, buffer, capacity, length)
        }
    }

    /** Encrypts text, as UTF-8, so that only a dongle can decrypt it. */
    public fun appEncrypt(scope: Scope, text: String): ByteArray = appEncrypt(scope, text.encodeToByteArray())

    /** Decrypts data from [appEncrypt]. Altered data throws with [Status.TagMismatch]. */
    public fun appDecrypt(sealedData: ByteArray): ByteArray {
        val h = handle()
        val input = LicDongle.pointerOf(sealedData)
        return LicDongle.readSized(h, "licdf_app_decrypt") { buffer, capacity, length ->
            LicDongle.flat().appDecrypt(h, input, sealedData.size, buffer, capacity, length)
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        if (dongle.isOpen && generation == dongle.sessionGeneration && dongle.sessionOpen) {
            dongle.sessionOpen = false
            val h = dongle.handle()
            LicDongle.check("licdf_session_close", h, LicDongle.flat().sessionClose(h))
        }
    }
}
