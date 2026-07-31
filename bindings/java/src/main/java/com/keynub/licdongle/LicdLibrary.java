package com.keynub.licdongle;

import com.sun.jna.Callback;
import com.sun.jna.IntegerType;
import com.sun.jna.Library;
import com.sun.jna.Native;
import com.sun.jna.Pointer;
import com.sun.jna.Structure;
import com.sun.jna.ptr.ByReference;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.ptr.PointerByReference;

/**
 * JNA binding to the native {@code keynub_licdongle} core (the Java equivalent of the .NET
 * binding's P/Invoke layer). Package-private: everything above works through {@link #INSTANCE}.
 */
interface LicdLibrary extends Library {

    String LIBRARY_PROPERTY = "keynub.licdongle.library";

    /** Resolve the library: an explicit path from the system property, else the base name. */
    static String resolveLibraryName() {
        String override = System.getProperty(LIBRARY_PROPERTY);
        return (override != null && !override.isEmpty()) ? override : "keynub_licdongle";
    }

    LicdLibrary INSTANCE = Native.load(resolveLibraryName(), LicdLibrary.class);

    // --- size_t helpers (pointer-sized; JNA has no built-in size_t) ---

    class SizeT extends IntegerType {
        public SizeT() { this(0); }
        public SizeT(long value) { super(Native.SIZE_T_SIZE, value, true); }
    }

    class SizeTByReference extends ByReference {
        public SizeTByReference() { super(Native.SIZE_T_SIZE); }
        public long getValue() {
            Pointer p = getPointer();
            return Native.SIZE_T_SIZE == 8 ? p.getLong(0) : (p.getInt(0) & 0xFFFFFFFFL);
        }
    }

    // --- structures (mirror licdongle.h) ---

    @Structure.FieldOrder({"proto_version_major", "proto_version_minor", "fw_version_major",
            "fw_version_minor", "fw_version_patch", "se_ready", "provisioned",
            "data_capacity", "data_free", "watchdog_reboot", "isolated"})
    class LicdInfo extends Structure {
        public byte proto_version_major;
        public byte proto_version_minor;
        public byte fw_version_major;
        public byte fw_version_minor;
        public byte fw_version_patch;
        public int se_ready;
        public int provisioned;
        public int data_capacity;
        public int data_free;
        public int watchdog_reboot;
        public int isolated;
    }

    @Structure.FieldOrder({"genuine", "serial", "batch", "provisioned_date"})
    class LicdGenuineResult extends Structure {
        public int genuine;
        public byte[] serial = new byte[19];
        public byte[] batch = new byte[64];
        public byte[] provisioned_date = new byte[11];
    }

    @Structure.FieldOrder({"serial", "path", "vendor_id", "product_id"})
    class LicdDeviceInfo extends Structure {
        public byte[] serial = new byte[19];
        public byte[] path = new byte[512];
        public short vendor_id;
        public short product_id;

        public LicdDeviceInfo() { super(); }
        public LicdDeviceInfo(Pointer p) { super(p); read(); }
    }

    // --- callbacks ---

    interface ProgressCB extends Callback {
        int invoke(int done, int total, Pointer user);
    }

    interface LogCB extends Callback {
        void invoke(int level, String msg, Pointer user);
    }

    // --- functions ---

    void licd_version(IntByReference major, IntByReference minor, IntByReference patch);

    int licd_init(PointerByReference outCtx);
    void licd_free(Pointer ctx);
    void licd_set_log_callback(Pointer ctx, LogCB cb, Pointer user);

    int licd_set_trust_root(Pointer ctx, byte[] der, SizeT len);

    int licd_enumerate(Pointer ctx, PointerByReference outList, SizeTByReference outCount);
    void licd_free_device_list(Pointer list, SizeT count);
    int licd_open(Pointer ctx, byte[] serial, PointerByReference outDev);
    int licd_open_path(Pointer ctx, byte[] path, PointerByReference outDev);
    void licd_close(Pointer dev);

    int licd_get_info(Pointer dev, LicdInfo outInfo);
    int licd_get_serial(Pointer dev, byte[] outSerial, SizeT size);

    int licd_verify_genuine(Pointer dev, LicdGenuineResult outResult);
    int licd_session_open(Pointer dev);
    int licd_session_close(Pointer dev);
    int licd_write_auth(Pointer dev, byte[] der, SizeT len);

    int licd_record_list(Pointer dev, PointerByReference outNames, PointerByReference outSizes,
                         SizeTByReference outCount);
    void licd_free_record_list(Pointer names, Pointer sizes, SizeT count);
    int licd_record_read(Pointer dev, byte[] name, int offset, byte[] buf, int bufSize,
                         IntByReference outLen, IntByReference outTotal, ProgressCB progress, Pointer user);
    int licd_record_write(Pointer dev, byte[] name, byte[] data, int len, ProgressCB progress, Pointer user);
    int licd_record_erase(Pointer dev, byte[] name);

    int licd_counter_read(Pointer dev, byte counterId, IntByReference outValue);
    int licd_counter_increment(Pointer dev, byte counterId, IntByReference outValue);

    int licd_app_encrypt(Pointer dev, int scope, byte[] plaintext, int len,
                         PointerByReference outBuf, IntByReference outLen);
    int licd_app_decrypt(Pointer dev, byte[] packed, int len,
                         PointerByReference outBuf, IntByReference outLen);
    void licd_free_buffer(Pointer buf);

    String licd_strerror(int status);
    String licd_error_detail(Pointer ctx);
}
