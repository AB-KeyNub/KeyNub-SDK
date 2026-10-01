/**
 * KeyNub License Dongle: verify that a dongle is genuine, read and write the
 * license records it holds, use its hardware counters and encrypt data so that
 * only a dongle can decrypt it. Calls the SDK's flat C API through a library
 * loaded at run time with `Deno.dlopen`; run with `--allow-ffi` (plus
 * `--allow-env` and `--allow-read` for the library search).
 *
 * ```ts
 * import { Dongle } from "jsr:@keynub/licdongle";
 *
 * using d = Dongle.open();           // first dongle, or Dongle.open("serial")
 * d.verifyGenuine();                 // throws unless genuine
 * const secret = d.withSession(() => d.appDecrypt(sealed));
 * ```
 *
 * @module
 */
import {
  DATE_SIZE,
  ERROR_SIZE,
  FLAG_ISOLATED,
  FLAG_PROVISIONED,
  FLAG_SECURE_ELEMENT_READY,
  FLAG_WATCHDOG_REBOOT,
  FLAG_WRITE_AUTH_ROTATED,
  NAME_SIZE,
  PATH_SIZE,
  SERIAL_SIZE,
} from "./src/flat.ts";
import { loadApi } from "./src/library.ts";

export {
  LIBRARY_ENVIRONMENT_VARIABLE,
  libraryBasename,
  libraryCandidates,
  LibraryError,
  libraryPath,
  loadedLibraryPath,
  setLibraryPath,
} from "./src/library.ts";

/** The package version. */
export const VERSION = "1.1.1";

/** The SDK's status codes (`licd_status`). */
export enum Status {
  Ok = 0,
  InvalidArg = -1,
  NoDevice = -2,
  AccessDenied = -3,
  Io = -4,
  Timeout = -5,
  Protocol = -6,
  NotGenuine = -7,
  CertInvalid = -8,
  SessionExpired = -9,
  TagMismatch = -10,
  Range = -11,
  StorageFull = -12,
  Busy = -13,
  NotFound = -14,
  AuthRequired = -15,
  FirmwareIncompatible = -16,
  SdkTooOld = -17,
  Cancelled = -18,
  NotImplemented = -19,
  Internal = -20,
}

/** The name of a status code; `"Unknown"` for one this binding does not know. */
export function statusName(code: number): string {
  return Status[code] ?? "Unknown";
}

/**
 * A failed dongle call: the status (undefined for a code this binding does not
 * know), the raw code, the operation (the flat API function) and the library's
 * detail text, which may be empty.
 */
export class LicDongleError extends Error {
  readonly status: Status | undefined;
  readonly code: number;
  readonly operation: string;
  readonly detail: string;

  constructor(operation: string, code: number, detail = "") {
    let text = `${operation}: ${statusName(code)} (${code})`;
    if (detail !== "") text += `: ${detail}`;
    super(text);
    this.name = "LicDongleError";
    this.status = Status[code] !== undefined ? (code as Status) : undefined;
    this.code = code;
    this.operation = operation;
    this.detail = detail;
  }
}

/** The native library's version. */
export interface LibraryVersion {
  readonly major: number;
  readonly minor: number;
  readonly patch: number;
}

/** An attached dongle. */
export interface Device {
  readonly serial: string;
  readonly path: string;
}

/**
 * Plaintext device information. `watchdogReboot`: the previous boot ended in a
 * watchdog reset. `writeAuthRotated`: the write-auth key has been rotated away
 * from the factory one.
 */
export interface Info {
  readonly protocolMajor: number;
  readonly protocolMinor: number;
  readonly firmwareMajor: number;
  readonly firmwareMinor: number;
  readonly firmwarePatch: number;
  readonly secureElementReady: boolean;
  readonly provisioned: boolean;
  readonly watchdogReboot: boolean;
  readonly isolated: boolean;
  readonly writeAuthRotated: boolean;
  readonly dataCapacity: number;
  readonly dataFree: number;
}

/**
 * The result of a successful {@linkcode Dongle.verifyGenuine}. `provisionedDate`
 * is "YYYY-MM-DD", or empty when the dongle reports none; informational.
 */
export interface Genuine {
  readonly serial: string;
  readonly provisionedDate: string;
}

/** A record on the dongle. */
export interface DongleRecord {
  readonly name: string;
  readonly size: number;
}

/** Who can decrypt data sealed with {@linkcode Dongle.appEncrypt}. */
export enum Scope {
  /** This dongle only. */
  Device = 0,
  /** Any dongle issued by the same developer. */
  Developer = 1,
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const EMPTY = new Uint8Array(1);

function cString(text: string): Uint8Array<ArrayBuffer> {
  const bytes = encoder.encode(text);
  const out = new Uint8Array(bytes.length + 1);
  out.set(bytes);
  return out;
}

function fromCString(buffer: Uint8Array): string {
  const end = buffer.indexOf(0);
  return decoder.decode(end < 0 ? buffer : buffer.subarray(0, end));
}

function dataOf(data: Uint8Array): Uint8Array {
  return data.length === 0 ? EMPTY : data;
}

function lengthOf(data: Uint8Array): number {
  if (data.length > 0x7fffffff) {
    throw new LicDongleError("argument", Status.InvalidArg, "more than 2 GiB of data");
  }
  return data.length;
}

function check(operation: string, handle: number, rc: number): void {
  if (rc !== 0) throw new LicDongleError(operation, rc, handle > 0 ? detailOf(handle) : "");
}

function detailOf(handle: number): string {
  try {
    const text = new Uint8Array(ERROR_SIZE);
    return loadApi().licdf_last_error(handle, text, ERROR_SIZE) === 0 ? fromCString(text) : "";
  } catch {
    return "";
  }
}

/** The native library's version. */
export function libraryVersion(): LibraryVersion {
  const v = new Int32Array(3);
  check("licdf_version", 0, loadApi().licdf_version(v.subarray(0, 1), v.subarray(1, 2), v.subarray(2, 3)));
  return { major: v[0], minor: v[1], patch: v[2] };
}

/** Human-readable text for a status code; needs no dongle. */
export function statusText(code: number): string {
  const text = new Uint8Array(ERROR_SIZE);
  if (loadApi().licdf_strerror(code, text, ERROR_SIZE) !== 0) return statusName(code);
  return fromCString(text);
}

/** The attached dongles. */
export function devices(): Device[] {
  const api = loadApi();
  const count = new Int32Array(1);
  check("licdf_device_count", 0, api.licdf_device_count(count));
  const result: Device[] = [];
  for (let i = 0; i < count[0]; i++) {
    const text = new Uint8Array(PATH_SIZE);
    check("licdf_device_serial", 0, api.licdf_device_serial(i, text, PATH_SIZE));
    const serial = fromCString(text);
    check("licdf_device_path", 0, api.licdf_device_path(i, text, PATH_SIZE));
    result.push({ serial, path: fromCString(text) });
  }
  return result;
}

const finalizer = new FinalizationRegistry<number>((handle) => {
  try {
    loadApi().licdf_close(handle);
  } catch {
    // ignored
  }
});

/**
 * An open dongle. `close()` it, declare it with `using`, or use
 * {@linkcode withDongle}, which closes it on every exit path.
 */
export class Dongle implements Disposable {
  #handle: number;

  private constructor(handle: number) {
    this.#handle = handle;
    finalizer.register(this, handle, this);
  }

  /** Opens the dongle with this serial, or the first one found when `serial` is omitted or empty. */
  static open(serial?: string): Dongle {
    const handle = loadApi().licdf_open(cString(serial ?? ""));
    if (handle < 0) throw new LicDongleError("licdf_open", handle);
    return new Dongle(handle);
  }

  /** Opens the dongle at this device path (from {@linkcode devices}). */
  static openPath(path: string): Dongle {
    const handle = loadApi().licdf_open_path(cString(path));
    if (handle < 0) throw new LicDongleError("licdf_open_path", handle);
    return new Dongle(handle);
  }

  /** Whether `close()` has not been called yet. */
  get isOpen(): boolean {
    return this.#handle > 0;
  }

  /** Closes the dongle. Further calls fail with `Status.InvalidArg`. */
  close(): void {
    if (this.#handle <= 0) return;
    const handle = this.#handle;
    this.#handle = 0;
    finalizer.unregister(this);
    check("licdf_close", handle, loadApi().licdf_close(handle));
  }

  /** Closes the dongle at the end of a `using` block; never throws. */
  [Symbol.dispose](): void {
    try {
      this.close();
    } catch {
      // ignored
    }
  }

  /** The dongle's serial number (14 hex digits). */
  get serial(): string {
    const text = new Uint8Array(SERIAL_SIZE);
    this.#check("licdf_get_serial", loadApi().licdf_get_serial(this.#handle, text, SERIAL_SIZE));
    return fromCString(text);
  }

  /** Plaintext device information. */
  info(): Info {
    const v = new Int32Array(8);
    const at = (k: number) => v.subarray(k, k + 1);
    this.#check(
      "licdf_get_info",
      loadApi().licdf_get_info(this.#handle, at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7)),
    );
    const flags = v[5];
    return {
      protocolMajor: v[0],
      protocolMinor: v[1],
      firmwareMajor: v[2],
      firmwareMinor: v[3],
      firmwarePatch: v[4],
      secureElementReady: (flags & FLAG_SECURE_ELEMENT_READY) !== 0,
      provisioned: (flags & FLAG_PROVISIONED) !== 0,
      watchdogReboot: (flags & FLAG_WATCHDOG_REBOOT) !== 0,
      isolated: (flags & FLAG_ISOLATED) !== 0,
      writeAuthRotated: (flags & FLAG_WRITE_AUTH_ROTATED) !== 0,
      dataCapacity: v[6],
      dataFree: v[7],
    };
  }

  /**
   * Proves the dongle is genuine: certificate chain to the trusted root plus a
   * live challenge-response. Returns only when it is; throws otherwise.
   */
  verifyGenuine(): Genuine {
    const genuine = new Int32Array(1);
    const serial = new Uint8Array(SERIAL_SIZE);
    const date = new Uint8Array(DATE_SIZE);
    this.#check(
      "licdf_verify_genuine",
      loadApi().licdf_verify_genuine(this.#handle, genuine, serial, SERIAL_SIZE, date, DATE_SIZE),
    );
    if (genuine[0] === 0) throw new LicDongleError("licdf_verify_genuine", Status.NotGenuine);
    return { serial: fromCString(serial), provisionedDate: fromCString(date) };
  }

  /** The boolean form for a gate: true only when `verifyGenuine()` succeeds. Fails closed: every failure gives false. */
  isGenuine(): boolean {
    try {
      this.verifyGenuine();
      return true;
    } catch {
      return false;
    }
  }

  /** Overrides the CA root that `verifyGenuine()` checks against (DER). */
  setTrustRoot(der: Uint8Array): void {
    this.#check("licdf_set_trust_root", loadApi().licdf_set_trust_root(this.#handle, dataOf(der), lengthOf(der)));
  }

  /** Opens an authenticated session; records, counters and app crypto need one. */
  sessionOpen(): void {
    this.#check("licdf_session_open", loadApi().licdf_session_open(this.#handle));
  }

  /** Closes the session. */
  sessionClose(): void {
    this.#check("licdf_session_close", loadApi().licdf_session_close(this.#handle));
  }

  /** Opens a session, runs `body` and closes the session on every exit path. Returns what `body` returns. */
  withSession<T>(body: () => T): T {
    this.sessionOpen();
    try {
      return body();
    } finally {
      try {
        this.sessionClose();
      } catch {
        // ignored
      }
    }
  }

  /**
   * Elevates the session to the write role with a write-auth key (P-256 PKCS#8
   * DER). Belongs in licence-issuing tooling, not in the application your users run.
   */
  authorizeWrite(key: Uint8Array): void {
    this.#check("licdf_write_auth", loadApi().licdf_write_auth(this.#handle, dataOf(key), lengthOf(key)));
  }

  /**
   * Replaces the dongle's write-auth key with `key` (P-256 PKCS#8 DER). Call
   * `authorizeWrite()` first. From the next session on, only the new key elevates.
   */
  rotateWriteKey(key: Uint8Array): void {
    this.#check("licdf_write_auth_rotate", loadApi().licdf_write_auth_rotate(this.#handle, dataOf(key), lengthOf(key)));
  }

  /** The records on the dongle. */
  records(): DongleRecord[] {
    const api = loadApi();
    const count = new Int32Array(1);
    this.#check("licdf_record_count", api.licdf_record_count(this.#handle, count));
    const result: DongleRecord[] = [];
    for (let i = 0; i < count[0]; i++) {
      const text = new Uint8Array(NAME_SIZE);
      const size = new Int32Array(1);
      this.#check("licdf_record_name", api.licdf_record_name(this.#handle, i, text, NAME_SIZE, size));
      result.push({ name: fromCString(text), size: size[0] });
    }
    return result;
  }

  /** The content of a record. */
  readRecord(name: string): Uint8Array {
    const api = loadApi();
    const n = cString(name);
    return this.#readBytes(
      "licdf_record_read",
      (data, capacity, length) => api.licdf_record_read(this.#handle, n, data, capacity, length),
    );
  }

  /** Writes a record, replacing one of the same name. Needs the write role. */
  writeRecord(name: string, data: Uint8Array): void {
    this.#check(
      "licdf_record_write",
      loadApi().licdf_record_write(this.#handle, cString(name), dataOf(data), lengthOf(data)),
    );
  }

  /** Erases one record. Needs the write role. */
  eraseRecord(name: string): void {
    this.#check("licdf_record_erase", loadApi().licdf_record_erase(this.#handle, cString(name)));
  }

  /** Erases every record. Separate from `eraseRecord()` so that an accidentally empty name cannot wipe the dongle. */
  eraseAllRecords(): void {
    this.#check("licdf_record_erase_all", loadApi().licdf_record_erase_all(this.#handle));
  }

  /** The value of a hardware monotonic counter. */
  readCounter(counterId: number): number {
    const value = new Int32Array(1);
    this.#check("licdf_counter_read", loadApi().licdf_counter_read(this.#handle, counterId, value));
    return value[0];
  }

  /** Increments a counter and returns the new value. Needs the write role. */
  incrementCounter(counterId: number): number {
    const value = new Int32Array(1);
    this.#check("licdf_counter_increment", loadApi().licdf_counter_increment(this.#handle, counterId, value));
    return value[0];
  }

  /**
   * Seals data so that only a dongle can open it: this one (`Scope.Device`) or
   * any dongle issued by the same developer (`Scope.Developer`). Build the
   * licence check on this pair: put something the program needs through it, so
   * removing the check removes the data.
   */
  appEncrypt(scope: Scope, plaintext: Uint8Array): Uint8Array {
    const api = loadApi();
    const length = lengthOf(plaintext);
    const input = dataOf(plaintext);
    return this.#readBytes(
      "licdf_app_encrypt",
      (data, capacity, outLength) =>
        api.licdf_app_encrypt(this.#handle, scope, input, length, data, capacity, outLength),
    );
  }

  /** Opens data sealed with `appEncrypt()`. */
  appDecrypt(packed: Uint8Array): Uint8Array {
    const api = loadApi();
    const length = lengthOf(packed);
    const input = dataOf(packed);
    return this.#readBytes(
      "licdf_app_decrypt",
      (data, capacity, outLength) => api.licdf_app_decrypt(this.#handle, input, length, data, capacity, outLength),
    );
  }

  /** Diagnostic detail for the most recent failure on this dongle; may be empty. */
  lastErrorDetail(): string {
    return detailOf(this.#handle);
  }

  #check(operation: string, rc: number): void {
    check(operation, this.#handle, rc);
  }

  // The two-call convention: ask for the size, then read into a buffer of it.
  #readBytes(
    operation: string,
    call: (data: Uint8Array, capacity: number, length: Int32Array) => number,
  ): Uint8Array {
    const needed = new Int32Array(1);
    let rc = call(new Uint8Array(1), 0, needed);
    if (rc === 0) return new Uint8Array(0);
    if (rc !== Status.Range) throw new LicDongleError(operation, rc, this.lastErrorDetail());
    const data = new Uint8Array(needed[0] > 0 ? needed[0] : 1);
    const length = new Int32Array(1);
    rc = call(data, needed[0], length);
    if (rc !== 0) throw new LicDongleError(operation, rc, this.lastErrorDetail());
    return data.slice(0, length[0]);
  }
}

/**
 * Opens the first dongle (or the one with `serial`), runs `body` with it and
 * closes it on every exit path. Returns what `body` returns.
 */
export function withDongle<T>(body: (dongle: Dongle) => T, serial?: string): T {
  const dongle = Dongle.open(serial);
  try {
    return body(dongle);
  } finally {
    dongle[Symbol.dispose]();
  }
}
