// TypeScript declarations for @keynub/licdongle.
//
// Hand-written and kept beside index.js. Most consumers of an Electron licensing
// binding are on TypeScript, and an untyped `require` there is a bad first
// impression — but note that these types are not generated, so they are a claim
// about index.js rather than proof about it.

/** Native status codes (mirrors licd_status). OK is 0; errors are negative. */
export const Status: {
  readonly OK: 0;
  readonly INVALID_ARGUMENT: -1;
  readonly NO_DEVICE: -2;
  readonly ACCESS_DENIED: -3;
  readonly IO: -4;
  readonly TIMEOUT: -5;
  readonly PROTOCOL: -6;
  readonly NOT_GENUINE: -7;
  readonly CERTIFICATE_INVALID: -8;
  readonly SESSION_EXPIRED: -9;
  readonly TAG_MISMATCH: -10;
  readonly RANGE: -11;
  readonly STORAGE_FULL: -12;
  readonly BUSY: -13;
  readonly NOT_FOUND: -14;
  readonly AUTH_REQUIRED: -15;
  readonly FIRMWARE_INCOMPATIBLE: -16;
  readonly SDK_TOO_OLD: -17;
  readonly CANCELLED: -18;
  readonly NOT_IMPLEMENTED: -19;
  readonly INTERNAL: -20;
};

/** Who can decrypt data produced by Session.appEncrypt. */
export const Scope: {
  /** Only this one physical dongle. */
  readonly DEVICE: 0;
  /** Any dongle from the same developer batch — one blob for every customer. */
  readonly DEVELOPER: 1;
};

export const LogLevel: {
  readonly ERROR: 0;
  readonly WARN: 1;
  readonly INFO: 2;
  readonly DEBUG: 3;
};

export type ErrorCode =
  | 'KEYNUB_INVALID_ARGUMENT'
  | 'KEYNUB_NO_DEVICE'
  | 'KEYNUB_ACCESS_DENIED'
  | 'KEYNUB_IO'
  | 'KEYNUB_TIMEOUT'
  | 'KEYNUB_PROTOCOL'
  | 'KEYNUB_NOT_GENUINE'
  | 'KEYNUB_CERTIFICATE_INVALID'
  | 'KEYNUB_SESSION_EXPIRED'
  | 'KEYNUB_TAG_MISMATCH'
  | 'KEYNUB_RANGE'
  | 'KEYNUB_STORAGE_FULL'
  | 'KEYNUB_BUSY'
  | 'KEYNUB_RECORD_NOT_FOUND'
  | 'KEYNUB_WRITE_AUTH_REQUIRED'
  | 'KEYNUB_FIRMWARE_INCOMPATIBLE'
  | 'KEYNUB_SDK_TOO_OLD'
  | 'KEYNUB_CANCELLED'
  | 'KEYNUB_NOT_IMPLEMENTED'
  | 'KEYNUB_INTERNAL';

export class LicenseDongleError extends Error {
  readonly status: number;
  readonly code: ErrorCode;
  /** The SDK's diagnostic detail for this failure. Log it; do not parse it. */
  readonly detail: string;
}

export class NotGenuineError extends LicenseDongleError {}
export class CertificateInvalidError extends LicenseDongleError {}
export class WriteAuthorizationRequiredError extends LicenseDongleError {}
export class SessionExpiredError extends LicenseDongleError {}
export class DeviceNotFoundError extends LicenseDongleError {}
export class RecordNotFoundError extends LicenseDongleError {}
export class OperationCancelledError extends LicenseDongleError {}

export interface DeviceInfo {
  serial: string;
  /** Opaque platform path; pass to Context.openPath. */
  path: string;
  vendorId: number;
  productId: number;
}

export interface DongleInfo {
  /** [major, minor] */
  protocolVersion: [number, number];
  /** [major, minor, patch] */
  firmwareVersion: [number, number, number];
  seReady: boolean;
  provisioned: boolean;
  dataCapacity: number;
  dataFree: number;
  /**
   * The dongle's *previous* boot ended in a watchdog timeout: the firmware hung
   * and reset itself. The only trace a field hang leaves behind, cleared by a
   * power cycle — worth logging.
   */
  watchdogReboot: boolean;
  /**
   * Whether the dongle confirmed at boot that its USB and parsing code is fenced off
   * from keys and storage. The software simulator reports false.
   */
  isolated: boolean;
}

export interface GenuineResult {
  genuine: boolean;
  serial: string;
  batch: string;
  /** "YYYY-MM-DD", or empty. */
  provisionedDate: string;
}

export interface RecordInfo {
  name: string;
  size: number;
}

export interface Version {
  major: number;
  minor: number;
  patch: number;
}

/** Return false to cancel the transfer. Throwing also cancels, and rethrows. */
export type ProgressCallback = (done: number, total: number) => boolean | void;

export type BytesLike = Buffer | Uint8Array | ArrayBuffer | string;

export class Context implements Disposable {
  constructor();
  static libraryVersion(): Version;
  readonly closed: boolean;
  /** The raw native handle, for mixing this binding with direct FFI calls. */
  readonly handle: unknown;
  readonly lastErrorDetail: string;
  close(): void;
  [Symbol.dispose](): void;
  setLogCallback(callback: ((level: number, message: string) => void) | null): void;
  setTrustRoot(der: BytesLike): void;
  enumerate(): DeviceInfo[];
  /** Opens the dongle with this serial, or the first one found. */
  open(serial?: string | null): Dongle;
  openPath(path: string): Dongle;
}

export class Dongle implements Disposable {
  readonly closed: boolean;
  readonly handle: unknown;
  close(): void;
  [Symbol.dispose](): void;
  getInfo(): DongleInfo;
  getSerial(): string;
  /** Throws unless the dongle proves it is genuine. */
  verifyGenuine(): GenuineResult;
  /** Non-throwing licence gate. Fails closed on every kind of failure. */
  isGenuine(): { genuine: boolean; code: ErrorCode | null };
  openSession(): Session;
}

export class Session implements Disposable {
  readonly closed: boolean;
  close(): void;
  [Symbol.dispose](): void;
  /** Vendor tooling only — never ship the developer master key in an app. */
  authorizeWrite(masterKeyDer: BytesLike): void;
  listRecords(): RecordInfo[];
  readRecord(name: string, progress?: ProgressCallback): Buffer;
  writeRecord(name: string, data: BytesLike, progress?: ProgressCallback): void;
  eraseRecord(name: string): void;
  eraseAllRecords(): void;
  readCounter(counterId: number): number;
  /** Irreversible: the counter is monotonic in hardware. */
  incrementCounter(counterId: number): number;
  /**
   * Encrypts so only a dongle of `scope` can decrypt. Build the licence check on
   * this pair: put something the app needs through it, so removing the check
   * removes the data.
   */
  appEncrypt(scope: 0 | 1, plaintext: BytesLike): Buffer;
  appDecrypt(packed: BytesLike): Buffer;
}
