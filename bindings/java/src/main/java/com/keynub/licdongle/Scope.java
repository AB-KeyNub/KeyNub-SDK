package com.keynub.licdongle;

/** Scope for app-data envelope encryption ({@link Session#appEncrypt}). */
public enum Scope {
    /** Only this physical dongle can decrypt (node-locking). */
    DEVICE(0),
    /** Any dongle from the same developer batch can decrypt. */
    DEVELOPER(1);

    private final int code;

    Scope(int code) {
        this.code = code;
    }

    /** The numeric scope code passed to the native layer. */
    public int code() {
        return code;
    }
}
