package com.keynub.licdongle.kotlin

import com.keynub.licdongle.kotlin.cinterop.kn_licdf_app_decrypt
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_app_encrypt
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_close
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_counter_increment
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_counter_read
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_device_count
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_device_path
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_device_serial
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_get_info
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_get_serial
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_last_error
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_open
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_open_path
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_record_count
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_record_erase
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_record_erase_all
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_record_name
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_record_read
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_record_write
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_session_close
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_session_open
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_set_trust_root
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_strerror
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_verify_genuine
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_version
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_write_auth
import com.keynub.licdongle.kotlin.cinterop.kn_licdf_write_auth_rotate
import com.keynub.licdongle.kotlin.cinterop.kn_load
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.IntVar
import kotlinx.cinterop.UByteVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.usePinned
import kotlin.concurrent.AtomicInt

private inline fun <T> ByteArray.chars(block: (CPointer<ByteVar>) -> T): T = usePinned { block(it.addressOf(0)) }

private inline fun <T> ByteArray.bytes(block: (CPointer<UByteVar>) -> T): T =
    usePinned { block(it.addressOf(0).reinterpret()) }

private inline fun <T> IntArray.ints(block: (CPointer<IntVar>) -> T): T = usePinned { block(it.addressOf(0)) }

/** The flat API through the C shim, which forwards to the library kn_load resolved. */
private object ShimFlat : FlatApi {
    override fun version(out: IntArray): Int = out.usePinned {
        kn_licdf_version(it.addressOf(0), it.addressOf(1), it.addressOf(2))
    }

    override fun deviceCount(out: IntArray): Int = out.ints { kn_licdf_device_count(it) }
    override fun deviceSerial(index: Int, out: ByteArray, size: Int): Int = out.chars { kn_licdf_device_serial(index, it, size) }
    override fun devicePath(index: Int, out: ByteArray, size: Int): Int = out.chars { kn_licdf_device_path(index, it, size) }
    override fun open(serialOrEmpty: String): Int = kn_licdf_open(serialOrEmpty)
    override fun openPath(path: String): Int = kn_licdf_open_path(path)
    override fun close(handle: Int): Int = kn_licdf_close(handle)
    override fun setTrustRoot(handle: Int, der: ByteArray, length: Int): Int =
        der.bytes { kn_licdf_set_trust_root(handle, it, length) }

    override fun getSerial(handle: Int, out: ByteArray, size: Int): Int = out.chars { kn_licdf_get_serial(handle, it, size) }

    override fun getInfo(handle: Int, out: IntArray): Int = out.usePinned {
        kn_licdf_get_info(
            handle, it.addressOf(0), it.addressOf(1), it.addressOf(2), it.addressOf(3), it.addressOf(4),
            it.addressOf(5), it.addressOf(6), it.addressOf(7),
        )
    }

    override fun verifyGenuine(handle: Int, genuine: IntArray, serial: ByteArray, serialSize: Int, date: ByteArray, dateSize: Int): Int =
        genuine.ints { g -> serial.chars { s -> date.chars { d -> kn_licdf_verify_genuine(handle, g, s, serialSize, d, dateSize) } } }

    override fun sessionOpen(handle: Int): Int = kn_licdf_session_open(handle)
    override fun sessionClose(handle: Int): Int = kn_licdf_session_close(handle)
    override fun writeAuth(handle: Int, der: ByteArray, length: Int): Int = der.bytes { kn_licdf_write_auth(handle, it, length) }
    override fun writeAuthRotate(handle: Int, der: ByteArray, length: Int): Int =
        der.bytes { kn_licdf_write_auth_rotate(handle, it, length) }

    override fun recordCount(handle: Int, out: IntArray): Int = out.ints { kn_licdf_record_count(handle, it) }
    override fun recordName(handle: Int, index: Int, out: ByteArray, size: Int, recordSize: IntArray): Int =
        out.chars { o -> recordSize.ints { r -> kn_licdf_record_name(handle, index, o, size, r) } }

    override fun recordRead(handle: Int, name: String, out: ByteArray, capacity: Int, length: IntArray): Int =
        out.bytes { o -> length.ints { l -> kn_licdf_record_read(handle, name, o, capacity, l) } }

    override fun recordWrite(handle: Int, name: String, data: ByteArray, length: Int): Int =
        data.bytes { kn_licdf_record_write(handle, name, it, length) }

    override fun recordErase(handle: Int, name: String): Int = kn_licdf_record_erase(handle, name)
    override fun recordEraseAll(handle: Int): Int = kn_licdf_record_erase_all(handle)
    override fun counterRead(handle: Int, id: Int, out: IntArray): Int = out.ints { kn_licdf_counter_read(handle, id, it) }
    override fun counterIncrement(handle: Int, id: Int, out: IntArray): Int = out.ints { kn_licdf_counter_increment(handle, id, it) }

    override fun appEncrypt(handle: Int, scope: Int, data: ByteArray, length: Int, out: ByteArray, capacity: Int, outLength: IntArray): Int =
        data.bytes { d -> out.bytes { o -> outLength.ints { l -> kn_licdf_app_encrypt(handle, scope, d, length, o, capacity, l) } } }

    override fun appDecrypt(handle: Int, data: ByteArray, length: Int, out: ByteArray, capacity: Int, outLength: IntArray): Int =
        data.bytes { d -> out.bytes { o -> outLength.ints { l -> kn_licdf_app_decrypt(handle, d, length, o, capacity, l) } } }

    override fun strerror(status: Int, out: ByteArray, size: Int): Int = out.chars { kn_licdf_strerror(status, it, size) }
    override fun lastError(handle: Int, out: ByteArray, size: Int): Int = out.chars { kn_licdf_last_error(handle, it, size) }
}

internal actual fun loadFlatApi(path: String): FlatApi {
    val message = ByteArray(512)
    val pathBytes = (path + "\u0000").encodeToByteArray()
    val rc = pathBytes.chars { p -> message.chars { m -> kn_load(p, m, message.size) } }
    if (rc != 0) throw LibraryException(LicDongle.cString(message))
    return ShimFlat
}

/** A spin lock; the library holds it only around loading and its bookkeeping. */
internal actual class Lock actual constructor() {
    private val state = AtomicInt(0)

    actual fun <T> withLock(block: () -> T): T {
        while (!state.compareAndSet(0, 1)) {
            // Another thread holds the lock for the few instructions of a load or a field update.
        }
        try {
            return block()
        } finally {
            state.value = 0
        }
    }
}
