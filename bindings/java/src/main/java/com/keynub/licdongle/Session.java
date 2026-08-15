package com.keynub.licdongle;

import com.sun.jna.Pointer;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.ptr.PointerByReference;

import java.util.ArrayList;
import java.util.List;

/**
 * An open encrypted session on a {@link Dongle}: records, counters, app-data envelope
 * encryption, and write-role elevation. Obtain one from {@link Dongle#openSession()}; close it
 * (or use try-with-resources) to end the session.
 */
public final class Session implements AutoCloseable {

    private final Dongle dongle;
    private boolean closed;

    Session(Dongle dongle) {
        this.dongle = dongle;
    }

    private Pointer h() {
        return dongle.handle();
    }

    private Pointer ch() {
        return dongle.ctxHandle();
    }

    private void guard() {
        if (closed) {
            throw new IllegalStateException("the session has been closed");
        }
    }

    /** Whether this session has been closed. */
    public boolean isClosed() {
        return closed;
    }

    /**
     * Elevate the session to the write role by proving the developer master key (DER EC private
     * key). Required before {@link #writeRecord}, {@link #eraseRecord}, {@link #eraseAllRecords},
     * and {@link #incrementCounter}.
     */
    public void authorizeWrite(byte[] masterKeyDer) {
        guard();
        Errors.check(LicdLibrary.INSTANCE.licd_write_auth(h(), masterKeyDer,
                new LicdLibrary.SizeT(masterKeyDer.length)), ch(), "licd_write_auth");
    }

    /**
     * Replace the dongle's write-auth key with your own (DER EC private key).
     *
     * <p>Call {@link #authorizeWrite} with the current key first. From the next session on, only
     * the new key elevates.
     */
    public void rotateWriteKey(byte[] newKeyDer) {
        guard();
        Errors.check(LicdLibrary.INSTANCE.licd_write_auth_rotate(h(), newKeyDer,
                new LicdLibrary.SizeT(newKeyDer.length)), ch(), "licd_write_auth_rotate");
    }

    /** List the record names and sizes stored on the dongle. */
    public List<RecordInfo> listRecords() {
        guard();
        PointerByReference outNames = new PointerByReference();
        PointerByReference outSizes = new PointerByReference();
        LicdLibrary.SizeTByReference outCount = new LicdLibrary.SizeTByReference();
        Errors.check(LicdLibrary.INSTANCE.licd_record_list(h(), outNames, outSizes, outCount),
                ch(), "licd_record_list");
        List<RecordInfo> result = new ArrayList<>();
        long n = outCount.getValue();
        Pointer namesPtr = outNames.getValue();
        Pointer sizesPtr = outSizes.getValue();
        try {
            if (n > 0 && namesPtr != null && sizesPtr != null) {
                Pointer[] nameArr = namesPtr.getPointerArray(0, (int) n);
                int[] sizeArr = sizesPtr.getIntArray(0, (int) n);
                for (int i = 0; i < n; i++) {
                    String name = nameArr[i] != null ? nameArr[i].getString(0, "UTF-8") : "";
                    result.add(new RecordInfo(name, sizeArr[i] & 0xFFFFFFFFL));
                }
            }
        } finally {
            LicdLibrary.INSTANCE.licd_free_record_list(namesPtr, sizesPtr, new LicdLibrary.SizeT(n));
        }
        return result;
    }

    /** Read the entire named record. {@code progress} may cancel by returning {@code false}. */
    public byte[] readRecord(String name, ProgressCallback progress) {
        guard();
        byte[] nameB = Util.nameBytes(name);
        IntByReference outLen = new IntByReference();
        IntByReference total = new IntByReference();

        // Learn the total size (no progress on the tiny probe), then read the whole record so
        // reported progress is monotonic from 0 to total.
        Errors.check(LicdLibrary.INSTANCE.licd_record_read(h(), nameB, 0, new byte[1], 1,
                outLen, total, null, null), ch(), "licd_record_read");
        int totalLen = total.getValue();
        if (totalLen == 0) {
            if (progress != null) {
                progress.onProgress(new TransferProgress(0, 0));
            }
            return new byte[0];
        }

        byte[] buf = new byte[totalLen];
        LicdLibrary.ProgressCB cb = wrap(progress);
        int rc = LicdLibrary.INSTANCE.licd_record_read(h(), nameB, 0, buf, totalLen, outLen, total, cb, null);
        checkCancel(rc, "licd_record_read");
        int got = outLen.getValue();
        if (got == buf.length) {
            return buf;
        }
        byte[] exact = new byte[got];
        System.arraycopy(buf, 0, exact, 0, got);
        return exact;
    }

    /** Read the entire named record. */
    public byte[] readRecord(String name) {
        return readRecord(name, null);
    }

    /** Write (atomically replace) the named record. Requires the write role. */
    public void writeRecord(String name, byte[] data, ProgressCallback progress) {
        guard();
        byte[] nameB = Util.nameBytes(name);
        LicdLibrary.ProgressCB cb = wrap(progress);
        int rc = LicdLibrary.INSTANCE.licd_record_write(h(), nameB, data, data.length, cb, null);
        checkCancel(rc, "licd_record_write");
    }

    /** Write (atomically replace) the named record. Requires the write role. */
    public void writeRecord(String name, byte[] data) {
        writeRecord(name, data, null);
    }

    /** Erase the named record. Requires the write role. */
    public void eraseRecord(String name) {
        guard();
        Errors.check(LicdLibrary.INSTANCE.licd_record_erase(h(), Util.nameBytes(name)),
                ch(), "licd_record_erase");
    }

    /** Erase all records. Requires the write role. */
    public void eraseAllRecords() {
        guard();
        Errors.check(LicdLibrary.INSTANCE.licd_record_erase(h(), null), ch(), "licd_record_erase");
    }

    /** Read a hardware monotonic counter. */
    public long readCounter(int counterId) {
        guard();
        IntByReference value = new IntByReference();
        Errors.check(LicdLibrary.INSTANCE.licd_counter_read(h(), (byte) counterId, value),
                ch(), "licd_counter_read");
        return value.getValue() & 0xFFFFFFFFL;
    }

    /** Increment a monotonic counter, returning the new value. Requires the write role. */
    public long incrementCounter(int counterId) {
        guard();
        IntByReference value = new IntByReference();
        Errors.check(LicdLibrary.INSTANCE.licd_counter_increment(h(), (byte) counterId, value),
                ch(), "licd_counter_increment");
        return value.getValue() & 0xFFFFFFFFL;
    }

    /** Encrypt {@code plaintext} so only a dongle of {@code scope} can decrypt it. */
    public byte[] appEncrypt(Scope scope, byte[] plaintext) {
        guard();
        PointerByReference outBuf = new PointerByReference();
        IntByReference outLen = new IntByReference();
        Errors.check(LicdLibrary.INSTANCE.licd_app_encrypt(h(), scope.code(), plaintext, plaintext.length,
                outBuf, outLen), ch(), "licd_app_encrypt");
        return takeBuffer(outBuf.getValue(), outLen.getValue());
    }

    /** Decrypt a blob produced by {@link #appEncrypt} using the dongle. */
    public byte[] appDecrypt(byte[] packed) {
        guard();
        PointerByReference outBuf = new PointerByReference();
        IntByReference outLen = new IntByReference();
        Errors.check(LicdLibrary.INSTANCE.licd_app_decrypt(h(), packed, packed.length, outBuf, outLen),
                ch(), "licd_app_decrypt");
        return takeBuffer(outBuf.getValue(), outLen.getValue());
    }

    /** End the session, zeroizing session keys on the dongle. Safe to call more than once. */
    @Override
    public void close() {
        if (!closed) {
            closed = true;
            Pointer h = dongle.handleOrNull();
            if (h != null) {
                // Teardown is local state; ignore the status so close never throws.
                LicdLibrary.INSTANCE.licd_session_close(h);
            }
        }
    }

    private void checkCancel(int rc, String operation) {
        if (rc == LicdStatus.CANCELLED.code()) {
            throw new OperationCancelledException(operation + " was cancelled");
        }
        Errors.check(rc, ch(), operation);
    }

    private static LicdLibrary.ProgressCB wrap(ProgressCallback progress) {
        if (progress == null) {
            return null;
        }
        return (done, total, user) -> {
            try {
                boolean cont = progress.onProgress(
                        new TransferProgress(done & 0xFFFFFFFFL, total & 0xFFFFFFFFL));
                return cont ? 1 : 0;
            } catch (RuntimeException e) {
                return 0; // cancel on any callback error
            }
        };
    }

    private static byte[] takeBuffer(Pointer buf, int len) {
        try {
            if (buf == null || len == 0) {
                return new byte[0];
            }
            return buf.getByteArray(0, len);
        } finally {
            if (buf != null) {
                LicdLibrary.INSTANCE.licd_free_buffer(buf);
            }
        }
    }
}
