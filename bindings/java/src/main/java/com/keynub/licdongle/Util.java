package com.keynub.licdongle;

import java.nio.charset.StandardCharsets;

/** Small marshaling helpers shared by the API classes. */
final class Util {
    private Util() {
    }

    /** UTF-8, NUL-terminated bytes for a C string, or {@code null} if {@code s} is null. */
    static byte[] nulTerm(String s) {
        if (s == null) {
            return null;
        }
        byte[] b = s.getBytes(StandardCharsets.UTF_8);
        byte[] out = new byte[b.length + 1]; // trailing NUL is the default 0
        System.arraycopy(b, 0, out, 0, b.length);
        return out;
    }

    /** Like {@link #nulTerm} but rejects null/empty (records need a name). */
    static byte[] nameBytes(String name) {
        if (name == null || name.isEmpty()) {
            throw new IllegalArgumentException("record name must be non-empty");
        }
        return nulTerm(name);
    }

    /** Decode a NUL-terminated UTF-8 string from a fixed-size byte buffer. */
    static String cstr(byte[] buf) {
        int len = 0;
        while (len < buf.length && buf[len] != 0) {
            len++;
        }
        return new String(buf, 0, len, StandardCharsets.UTF_8);
    }
}
