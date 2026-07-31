package com.keynub.licdongle;

import com.sun.jna.Pointer;

/**
 * An open connection to a dongle. Plaintext operations are here; the session operations live
 * on the {@link Session} returned by {@link #openSession()}. Not thread-safe.
 */
public final class Dongle implements AutoCloseable {

    private final LicenseDongleContext context;
    private Pointer handle;

    Dongle(LicenseDongleContext context, Pointer handle) {
        this.context = context;
        this.handle = handle;
    }

    Pointer handle() {
        if (handle == null) {
            throw new IllegalStateException("the dongle has been closed");
        }
        return handle;
    }

    Pointer handleOrNull() {
        return handle;
    }

    Pointer ctxHandle() {
        return context.handle();
    }

    /** Read the plaintext device info (protocol/firmware version, flags, capacity). */
    public DongleInfo getInfo() {
        LicdLibrary.LicdInfo info = new LicdLibrary.LicdInfo();
        Errors.check(LicdLibrary.INSTANCE.licd_get_info(handle(), info), ctxHandle(), "licd_get_info");
        return new DongleInfo(
                info.proto_version_major & 0xFF, info.proto_version_minor & 0xFF,
                info.fw_version_major & 0xFF, info.fw_version_minor & 0xFF, info.fw_version_patch & 0xFF,
                info.se_ready != 0, info.provisioned != 0,
                info.data_capacity & 0xFFFFFFFFL, info.data_free & 0xFFFFFFFFL,
                info.watchdog_reboot != 0, info.isolated != 0);
    }

    /** Read the dongle serial as hex (e.g. {@code 0123456789ABCDEFEE}). */
    public String getSerial() {
        byte[] buf = new byte[19]; // LICD_SERIAL_HEX_LEN + 1
        Errors.check(LicdLibrary.INSTANCE.licd_get_serial(handle(), buf, new LicdLibrary.SizeT(buf.length)),
                ctxHandle(), "licd_get_serial");
        return Util.cstr(buf);
    }

    /** Verify authenticity (cert chain + live challenge-response); return the cert identity. */
    public GenuineResult verifyGenuine() {
        LicdLibrary.LicdGenuineResult res = new LicdLibrary.LicdGenuineResult();
        Errors.check(LicdLibrary.INSTANCE.licd_verify_genuine(handle(), res), ctxHandle(), "licd_verify_genuine");
        return new GenuineResult(res.genuine != 0, Util.cstr(res.serial), Util.cstr(res.batch),
                Util.cstr(res.provisioned_date));
    }

    /** Open an encrypted session (verify + P-256 ECDH / HKDF / AES-256-GCM handshake). */
    public Session openSession() {
        Errors.check(LicdLibrary.INSTANCE.licd_session_open(handle()), ctxHandle(), "licd_session_open");
        return new Session(this);
    }

    @Override
    public void close() {
        if (handle != null) {
            LicdLibrary.INSTANCE.licd_close(handle);
            handle = null;
        }
    }
}
