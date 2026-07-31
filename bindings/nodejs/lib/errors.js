'use strict';
// Status codes and the error hierarchy, mirroring the other bindings so that the
// same failure has the same name in every language.

const { fn } = require('./native');

const Status = Object.freeze({
  OK: 0,
  INVALID_ARGUMENT: -1,
  NO_DEVICE: -2,
  ACCESS_DENIED: -3,
  IO: -4,
  TIMEOUT: -5,
  PROTOCOL: -6,
  NOT_GENUINE: -7,
  CERTIFICATE_INVALID: -8,
  SESSION_EXPIRED: -9,
  TAG_MISMATCH: -10,
  RANGE: -11,
  STORAGE_FULL: -12,
  BUSY: -13,
  NOT_FOUND: -14,
  AUTH_REQUIRED: -15,
  FIRMWARE_INCOMPATIBLE: -16,
  SDK_TOO_OLD: -17,
  CANCELLED: -18,
  NOT_IMPLEMENTED: -19,
  INTERNAL: -20,
});

// Stable string codes, because JavaScript callers switch on strings and a numeric
// status is easy to mistype.
const CODES = {
  [Status.INVALID_ARGUMENT]: 'KEYNUB_INVALID_ARGUMENT',
  [Status.NO_DEVICE]: 'KEYNUB_NO_DEVICE',
  [Status.ACCESS_DENIED]: 'KEYNUB_ACCESS_DENIED',
  [Status.IO]: 'KEYNUB_IO',
  [Status.TIMEOUT]: 'KEYNUB_TIMEOUT',
  [Status.PROTOCOL]: 'KEYNUB_PROTOCOL',
  [Status.NOT_GENUINE]: 'KEYNUB_NOT_GENUINE',
  [Status.CERTIFICATE_INVALID]: 'KEYNUB_CERTIFICATE_INVALID',
  [Status.SESSION_EXPIRED]: 'KEYNUB_SESSION_EXPIRED',
  [Status.TAG_MISMATCH]: 'KEYNUB_TAG_MISMATCH',
  [Status.RANGE]: 'KEYNUB_RANGE',
  [Status.STORAGE_FULL]: 'KEYNUB_STORAGE_FULL',
  [Status.BUSY]: 'KEYNUB_BUSY',
  [Status.NOT_FOUND]: 'KEYNUB_RECORD_NOT_FOUND',
  [Status.AUTH_REQUIRED]: 'KEYNUB_WRITE_AUTH_REQUIRED',
  [Status.FIRMWARE_INCOMPATIBLE]: 'KEYNUB_FIRMWARE_INCOMPATIBLE',
  [Status.SDK_TOO_OLD]: 'KEYNUB_SDK_TOO_OLD',
  [Status.CANCELLED]: 'KEYNUB_CANCELLED',
  [Status.NOT_IMPLEMENTED]: 'KEYNUB_NOT_IMPLEMENTED',
  [Status.INTERNAL]: 'KEYNUB_INTERNAL',
};

class LicenseDongleError extends Error {
  constructor(status, message, detail) {
    super(message);
    // new.target, so every subclass reports its own name without each one having
    // to set it — and without a non-writable prototype property, which would make
    // this very assignment throw under 'use strict'.
    this.name = new.target.name;
    this.status = status;
    this.detail = detail || '';
    this.code = CODES[status] || 'KEYNUB_INTERNAL';
  }
}

class NotGenuineError extends LicenseDongleError {}
class CertificateInvalidError extends LicenseDongleError {}
class WriteAuthorizationRequiredError extends LicenseDongleError {}
class SessionExpiredError extends LicenseDongleError {}
class DeviceNotFoundError extends LicenseDongleError {}
class RecordNotFoundError extends LicenseDongleError {}
class OperationCancelledError extends LicenseDongleError {}

const SUBCLASS = {
  [Status.NOT_GENUINE]: NotGenuineError,
  [Status.CERTIFICATE_INVALID]: CertificateInvalidError,
  [Status.AUTH_REQUIRED]: WriteAuthorizationRequiredError,
  [Status.SESSION_EXPIRED]: SessionExpiredError,
  [Status.NO_DEVICE]: DeviceNotFoundError,
  [Status.NOT_FOUND]: RecordNotFoundError,
  [Status.CANCELLED]: OperationCancelledError,
};

/** Builds the error type that goes with `status`, without throwing it. */
function makeError(status, message, detail) {
  const Cls = SUBCLASS[status] || LicenseDongleError;
  return new Cls(status, message, detail);
}

/**
 * Raises the mapped error for a status the binding produces itself, so that a
 * locally detected problem is the same type a native one would have been.
 */
function fail(status, message) {
  throw makeError(status, message, '');
}

/** Throws the mapped error when `status` is not OK. */
function check(status, ctxHandle, operation) {
  if (status === Status.OK) {
    return;
  }
  const text = fn.strerror(status) || 'unknown error';
  const detail = ctxHandle ? fn.errorDetail(ctxHandle) || '' : '';
  const message = `${operation}: ${text}` + (detail ? ` (${detail})` : '');
  throw makeError(status, message, detail);
}

module.exports = {
  Status,
  LicenseDongleError,
  NotGenuineError,
  CertificateInvalidError,
  WriteAuthorizationRequiredError,
  SessionExpiredError,
  DeviceNotFoundError,
  RecordNotFoundError,
  OperationCancelledError,
  check,
  fail,
  makeError,
};
