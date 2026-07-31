package com.keynub.licdongle;

/** Raised when a transfer is cancelled via its {@link ProgressCallback}. */
public class OperationCancelledException extends RuntimeException {
    public OperationCancelledException(String message) {
        super(message);
    }
}
