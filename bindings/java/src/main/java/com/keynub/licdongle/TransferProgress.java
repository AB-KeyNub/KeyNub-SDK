package com.keynub.licdongle;

/** Progress of a record transfer, passed to a {@link ProgressCallback}. */
public record TransferProgress(long bytesTransferred, long totalBytes) {
    /** Fraction complete in {@code [0, 1]} (1.0 when {@link #totalBytes()} is 0). */
    public double fraction() {
        return totalBytes == 0 ? 1.0 : (double) bytesTransferred / totalBytes;
    }
}
