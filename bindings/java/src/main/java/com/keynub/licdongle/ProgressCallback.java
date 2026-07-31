package com.keynub.licdongle;

/**
 * Progress callback for {@link Session#readRecord} / {@link Session#writeRecord}. Return
 * {@code true} to continue the transfer, {@code false} to cancel it (raises
 * {@link OperationCancelledException}).
 */
@FunctionalInterface
public interface ProgressCallback {
    boolean onProgress(TransferProgress progress);
}
