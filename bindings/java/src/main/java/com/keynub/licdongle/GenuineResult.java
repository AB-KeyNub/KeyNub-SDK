package com.keynub.licdongle;

/** The verified identity from {@link Dongle#verifyGenuine()}. */
public record GenuineResult(boolean genuine, String serial, String provisionedDate) {
}
