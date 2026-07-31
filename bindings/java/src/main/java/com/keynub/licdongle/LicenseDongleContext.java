package com.keynub.licdongle;

import com.sun.jna.Pointer;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.ptr.PointerByReference;

import java.util.ArrayList;
import java.util.List;
import java.util.function.BiConsumer;

/**
 * The library context: the entry point for enumerating and opening dongles. Thread-safe.
 * Use with try-with-resources, or call {@link #close()} when done (after the dongles it opened).
 */
public final class LicenseDongleContext implements AutoCloseable {

    private Pointer handle;
    private LicdLibrary.LogCB logCb; // kept alive while registered

    public LicenseDongleContext() {
        PointerByReference out = new PointerByReference();
        int rc = LicdLibrary.INSTANCE.licd_init(out);
        Pointer h = out.getValue();
        Errors.check(rc, h, "licd_init");
        this.handle = h;
    }

    Pointer handle() {
        if (handle == null) {
            throw new IllegalStateException("the context has been closed");
        }
        return handle;
    }

    /** The native core library version (semantic), e.g. {@code "0.1.0"}. */
    public static String libraryVersion() {
        IntByReference major = new IntByReference();
        IntByReference minor = new IntByReference();
        IntByReference patch = new IntByReference();
        LicdLibrary.INSTANCE.licd_version(major, minor, patch);
        return major.getValue() + "." + minor.getValue() + "." + patch.getValue();
    }

    /** Set (or clear, with {@code null}) a diagnostic log callback {@code (level, message)}. */
    public void setLogCallback(BiConsumer<LogLevel, String> callback) {
        if (callback == null) {
            logCb = null;
            LicdLibrary.INSTANCE.licd_set_log_callback(handle(), null, null);
            return;
        }
        logCb = (level, msg, user) -> callback.accept(LogLevel.fromCode(level), msg == null ? "" : msg);
        LicdLibrary.INSTANCE.licd_set_log_callback(handle(), logCb, null);
    }

    /**
     * Override the CA root that {@link Dongle#verifyGenuine()} checks the device certificate
     * chain against, given a DER-encoded X.509 CA certificate.
     *
     * <p>Applications do not need this: a release build embeds the KeyNub production root. It
     * exists for dongles provisioned against a <em>development</em> CA and
     * for vendor tooling and hardware tests. This is not a security boundary — see
     * {@code docs/integration-security.md}.
     */
    public void setTrustRoot(byte[] der) {
        if (der == null) {
            throw new IllegalArgumentException("der must not be null");
        }
        Errors.check(
                LicdLibrary.INSTANCE.licd_set_trust_root(handle(), der, new LicdLibrary.SizeT(der.length)),
                handle(),
                "licd_set_trust_root");
    }

    /** Enumerate the connected dongles (empty list when none are present). */
    public List<DeviceInfo> enumerate() {
        PointerByReference outList = new PointerByReference();
        LicdLibrary.SizeTByReference outCount = new LicdLibrary.SizeTByReference();
        Errors.check(LicdLibrary.INSTANCE.licd_enumerate(handle(), outList, outCount), handle(), "licd_enumerate");
        List<DeviceInfo> result = new ArrayList<>();
        long n = outCount.getValue();
        Pointer listPtr = outList.getValue();
        if (n > 0 && listPtr != null) {
            LicdLibrary.LicdDeviceInfo[] arr =
                    (LicdLibrary.LicdDeviceInfo[]) new LicdLibrary.LicdDeviceInfo(listPtr).toArray((int) n);
            for (LicdLibrary.LicdDeviceInfo e : arr) {
                result.add(new DeviceInfo(Util.cstr(e.serial), Util.cstr(e.path),
                        e.vendor_id & 0xFFFF, e.product_id & 0xFFFF));
            }
            LicdLibrary.INSTANCE.licd_free_device_list(listPtr, new LicdLibrary.SizeT(n));
        }
        return result;
    }

    /** Open the dongle with {@code serial}, or the first one if {@code serial} is null. */
    public Dongle open(String serial) {
        PointerByReference outDev = new PointerByReference();
        Errors.check(LicdLibrary.INSTANCE.licd_open(handle(), Util.nulTerm(serial), outDev), handle(), "licd_open");
        return new Dongle(this, outDev.getValue());
    }

    /** Open the first attached dongle. */
    public Dongle open() {
        return open(null);
    }

    /** Open a specific dongle by the {@link DeviceInfo#path()} from {@link #enumerate()}. */
    public Dongle openPath(String path) {
        PointerByReference outDev = new PointerByReference();
        Errors.check(LicdLibrary.INSTANCE.licd_open_path(handle(), Util.nulTerm(path), outDev),
                handle(), "licd_open_path");
        return new Dongle(this, outDev.getValue());
    }

    /** The thread-local diagnostic detail for the most recent failure on this thread. */
    public String lastErrorDetail() {
        String s = LicdLibrary.INSTANCE.licd_error_detail(handle());
        return s == null ? "" : s;
    }

    @Override
    public void close() {
        if (handle != null) {
            LicdLibrary.INSTANCE.licd_free(handle);
            handle = null;
            logCb = null;
        }
    }
}
