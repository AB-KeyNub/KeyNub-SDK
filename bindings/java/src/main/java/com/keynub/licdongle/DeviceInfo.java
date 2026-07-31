package com.keynub.licdongle;

/** A dongle discovered by {@link LicenseDongleContext#enumerate()}. */
public record DeviceInfo(String serial, String path, int vendorId, int productId) {
}
