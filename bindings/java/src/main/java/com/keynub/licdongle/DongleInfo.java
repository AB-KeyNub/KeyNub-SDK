package com.keynub.licdongle;

/** Plaintext device info from {@link Dongle#getInfo()}. Capacities are unsigned 32-bit (as long). */
public record DongleInfo(
        int protocolMajor,
        int protocolMinor,
        int firmwareMajor,
        int firmwareMinor,
        int firmwarePatch,
        boolean seReady,
        boolean provisioned,
        long dataCapacity,
        long dataFree,
        /**
         * Whether the dongle's <em>previous</em> boot ended in a watchdog timeout -- the
         * firmware hung and reset itself. Normal operation and a requested reboot both
         * leave this false, so a true value is worth logging: it is the only trace a
         * field hang leaves behind. Cleared by a power cycle.
         */
        boolean watchdogReboot,
        /**
         * Whether the dongle confirmed at boot that its USB and parsing code is fenced off
         * from keys and storage. Anything that is not a dongle reports false.
         */
        boolean isolated,

        /**
         * Whether the write-auth key has been rotated away from the factory one. That key is
         * public, so a dongle reporting false accepts writes from anyone holding it.
         */
        boolean writeauthRotated) {
}
