'use strict';
// KeyNub License Dongle — Node.js / Electron binding.
//
//   const { Context, Scope } = require('@keynub/licdongle');
//
//   const ctx = new Context();
//   const dongle = ctx.open();
//   dongle.verifyGenuine();                    // throws unless genuine
//   const session = dongle.openSession();
//   const data = session.appDecrypt(blob);     // <- build the licence check here
//   session.close(); dongle.close(); ctx.close();
//
// Every call is synchronous and blocking. A dongle round trip is a millisecond or
// two of USB HID, so this is fine on a CLI's main thread — but in an Electron app
// do it in the main process (or a worker), never on the renderer's event loop
// where it would stutter the UI.
//
// Read docs/integration-security.md before deciding where the check goes.
// `if (await isLicensed())` in JavaScript is one line to delete, and in an
// Electron app the attacker has your source in an asar they can unpack. What
// cannot be deleted is data the app needs and only the dongle can decrypt.

const koffi = require('koffi');
const native = require('./lib/native');
const { fn, LicdInfo, LicdGenuineResult, ProgressCb, LogCb } = native;
const errors = require('./lib/errors');
const { Status, check, fail } = errors;

const Scope = Object.freeze({
  DEVICE: 0, // only this one physical dongle can decrypt
  DEVELOPER: 1, // any dongle issued by the same developer
});

const LogLevel = Object.freeze({ ERROR: 0, WARN: 1, INFO: 2, DEBUG: 3 });

const SERIAL_BUFFER = 15; // LICD_SERIAL_HEX_LEN + 1

/** Coerces user input to a Buffer without silently mangling it. */
function toBuffer(value, what) {
  if (Buffer.isBuffer(value)) {
    return value;
  }
  if (value instanceof Uint8Array) {
    return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  }
  if (value instanceof ArrayBuffer) {
    return Buffer.from(value);
  }
  if (typeof value === 'string') {
    return Buffer.from(value, 'utf8');
  }
  throw new TypeError(`${what} must be a Buffer, Uint8Array, ArrayBuffer or string`);
}

/**
 * Bridges a JS progress callback to the C callback, holding any exception it
 * throws until the SDK has finished unwinding its own transfer. Returns null when
 * no callback was supplied, so the C side gets a null pointer.
 */
function withProgress(progress, body) {
  if (progress === undefined || progress === null) {
    return body(null, () => {});
  }
  if (typeof progress !== 'function') {
    throw new TypeError('progress must be a function (done, total) => boolean');
  }
  const state = { error: null };
  const registered = koffi.register((done, total) => {
    if (state.error) {
      return 0;
    }
    try {
      // Anything other than an explicit false continues, so a callback that just
      // updates a progress bar and returns nothing is safe.
      return progress(done, total) === false ? 0 : 1;
    } catch (err) {
      // Throwing through C would skip the SDK's own cleanup and strand the device.
      state.error = err;
      return 0;
    }
  }, koffi.pointer(ProgressCb));
  try {
    return body(registered, () => {
      if (state.error) {
        throw state.error;
      }
    });
  } finally {
    koffi.unregister(registered);
  }
}

class Context {
  constructor() {
    const out = [null];
    check(fn.init(out), null, 'licd_init');
    this._handle = out[0];
    this._logCb = null;
  }

  static libraryVersion() {
    const major = [0];
    const minor = [0];
    const patch = [0];
    fn.version(major, minor, patch);
    return { major: major[0], minor: minor[0], patch: patch[0] };
  }

  get closed() {
    return this._handle === null;
  }

  close() {
    if (this._handle !== null) {
      const handle = this._handle;
      this._handle = null;
      if (this._logCb) {
        // Clear it on the C side before unregistering, or a late log call would
        // jump into a freed trampoline.
        fn.setLogCallback(handle, null, null);
        koffi.unregister(this._logCb);
        this._logCb = null;
      }
      fn.free(handle);
    }
  }

  /** Support for `using ctx = new Context()` where the runtime has it. */
  [Symbol.dispose ?? Symbol.for('nodejs.dispose')]() {
    this.close();
  }

  get handle() {
    if (this._handle === null) {
      fail(Status.INVALID_ARGUMENT, 'the context has been closed');
    }
    return this._handle;
  }

  /** Diagnostic log callback `(level, message)`, or null to clear it. */
  setLogCallback(callback) {
    const handle = this.handle;
    if (this._logCb) {
      fn.setLogCallback(handle, null, null);
      koffi.unregister(this._logCb);
      this._logCb = null;
    }
    if (callback) {
      this._logCb = koffi.register((level, msg) => {
        try {
          callback(level, msg || '');
        } catch {
          // A logging callback must never break the operation being logged.
        }
      }, koffi.pointer(LogCb));
      fn.setLogCallback(handle, this._logCb, null);
    }
  }

  /**
   * Overrides the CA root verifyGenuine checks against. Applications do not need
   * this — a release build embeds the KeyNub production root. It exists for
   * dongles provisioned against a different CA and for vendor tooling.
   */
  setTrustRoot(der) {
    const buf = toBuffer(der, 'the trust root');
    check(fn.setTrustRoot(this.handle, buf, buf.length), this._handle, 'licd_set_trust_root');
  }

  /** Connected dongles; an empty array when none are attached. */
  enumerate() {
    const list = [null];
    const count = [0];
    check(fn.enumerate(this.handle, list, count), this._handle, 'licd_enumerate');
    try {
      return native.readDeviceList(list[0], count[0]).map((entry) => ({
        serial: entry.serial,
        path: entry.path,
        vendorId: entry.vendor_id,
        productId: entry.product_id,
      }));
    } finally {
      if (list[0]) {
        fn.freeDeviceList(list[0], count[0]);
      }
    }
  }

  /** Opens the dongle with this serial, or the first one found. */
  open(serial = null) {
    const out = [null];
    check(fn.open(this.handle, serial || null, out), this._handle, 'licd_open');
    return new Dongle(this, out[0]);
  }

  openPath(path) {
    const out = [null];
    check(fn.openPath(this.handle, path, out), this._handle, 'licd_open_path');
    return new Dongle(this, out[0]);
  }

  get lastErrorDetail() {
    return fn.errorDetail(this.handle) || '';
  }
}

class Dongle {
  constructor(context, handle) {
    this._context = context;
    this._handle = handle;
  }

  get closed() {
    return this._handle === null;
  }

  close() {
    if (this._handle !== null) {
      const handle = this._handle;
      this._handle = null;
      fn.close(handle);
    }
  }

  [Symbol.dispose ?? Symbol.for('nodejs.dispose')]() {
    this.close();
  }

  get handle() {
    if (this._handle === null) {
      fail(Status.INVALID_ARGUMENT, 'the dongle has been closed');
    }
    return this._handle;
  }

  get _ctx() {
    return this._context._handle;
  }

  getInfo() {
    const info = {};
    check(fn.getInfo(this.handle, info), this._ctx, 'licd_get_info');
    return {
      protocolVersion: [info.proto_version_major, info.proto_version_minor],
      firmwareVersion: [info.fw_version_major, info.fw_version_minor, info.fw_version_patch],
      seReady: info.se_ready !== 0,
      provisioned: info.provisioned !== 0,
      dataCapacity: info.data_capacity,
      dataFree: info.data_free,
      // The dongle's PREVIOUS boot ended in a watchdog timeout: the firmware hung
      // and reset itself. The only trace a field hang leaves, so log it.
      watchdogReboot: info.watchdog_reboot !== 0,
      isolated: info.isolated !== 0,
      writeAuthRotated: info.writeauth_rotated !== 0,
    };
  }

  getSerial() {
    const buf = Buffer.alloc(SERIAL_BUFFER);
    check(fn.getSerial(this.handle, buf, buf.length), this._ctx, 'licd_get_serial');
    return native.bufferToString(buf);
  }

  /** Throws unless the dongle proves it is genuine. */
  verifyGenuine() {
    const result = {};
    check(fn.verifyGenuine(this.handle, result), this._ctx, 'licd_verify_genuine');
    return {
      genuine: result.genuine !== 0,
      serial: result.serial,
      provisionedDate: result.provisioned_date,
    };
  }

  /**
   * Non-throwing form for a licence gate. Fails closed: no dongle, an I/O error
   * and an invalid certificate all report false. The second element is the error
   * code when you need to tell a missing dongle from a rejected one.
   */
  isGenuine() {
    try {
      return { genuine: this.verifyGenuine().genuine, code: null };
    } catch (err) {
      return { genuine: false, code: err.code || 'KEYNUB_INTERNAL' };
    }
  }

  openSession() {
    check(fn.sessionOpen(this.handle), this._ctx, 'licd_session_open');
    return new Session(this);
  }
}

class Session {
  constructor(dongle) {
    this._dongle = dongle;
    this._closed = false;
  }

  get closed() {
    return this._closed;
  }

  /** Ends the session, zeroizing the session keys on the dongle. Never throws. */
  close() {
    if (!this._closed) {
      this._closed = true;
      if (!this._dongle.closed) {
        fn.sessionClose(this._dongle.handle);
      }
    }
  }

  [Symbol.dispose ?? Symbol.for('nodejs.dispose')]() {
    this.close();
  }

  get _dev() {
    if (this._closed) {
      fail(Status.SESSION_EXPIRED, 'the session has been closed');
    }
    return this._dongle.handle;
  }

  get _ctx() {
    return this._dongle._ctx;
  }

  static _requireName(name) {
    if (typeof name !== 'string' || name.length === 0) {
      throw new TypeError('the record name must be a non-empty string');
    }
    return name;
  }

  /**
   * Elevates to the write role with the developer master key. This belongs in your
   * licence-issuing tooling; never ship that key in the application your users run.
   */
  authorizeWrite(masterKeyDer) {
    const buf = toBuffer(masterKeyDer, 'the master key');
    check(fn.writeAuth(this._dev, buf, buf.length), this._ctx, 'licd_write_auth');
  }

  /**
   * Replaces the dongle's write-auth key with your own. Call authorizeWrite with
   * the current key first. From the next session on, only the new key elevates.
   */
  rotateWriteKey(newKeyDer) {
    const buf = toBuffer(newKeyDer, 'the replacement key');
    check(fn.writeAuthRotate(this._dev, buf, buf.length), this._ctx, 'licd_write_auth_rotate');
  }

  listRecords() {
    const names = [null];
    const sizes = [null];
    const count = [0];
    check(fn.recordList(this._dev, names, sizes, count), this._ctx, 'licd_record_list');
    try {
      const nameList = native.readStringArray(names[0], count[0]);
      const sizeList = native.readUint32Array(sizes[0], count[0]);
      return nameList.map((name, i) => ({ name, size: sizeList[i] }));
    } finally {
      if (names[0] || sizes[0]) {
        fn.freeRecordList(names[0], sizes[0], count[0]);
      }
    }
  }

  /** Reads a record. `progress(done, total)` may return false to cancel. */
  readRecord(name, progress) {
    Session._requireName(name);
    const dev = this._dev;

    // Probe for the size first so reported progress runs 0 -> total monotonically.
    const probe = Buffer.alloc(1);
    const got = [0];
    const total = [0];
    check(
      fn.recordRead(dev, name, 0, probe, 1, got, total, null, null),
      this._ctx,
      'licd_record_read'
    );
    if (total[0] === 0) {
      if (progress) {
        progress(0, 0);
      }
      return Buffer.alloc(0);
    }

    const buf = Buffer.alloc(total[0]);
    return withProgress(progress, (cb, rethrow) => {
      const status = fn.recordRead(dev, name, 0, buf, buf.length, got, total, cb, null);
      rethrow();
      check(status, this._ctx, 'licd_record_read');
      return got[0] === buf.length ? buf : buf.subarray(0, got[0]);
    });
  }

  /** Atomically replaces a record. Requires the write role. */
  writeRecord(name, data, progress) {
    Session._requireName(name);
    const buf = toBuffer(data, 'the record data');
    const dev = this._dev;
    withProgress(progress, (cb, rethrow) => {
      const status = fn.recordWrite(dev, name, buf, buf.length, cb, null);
      rethrow();
      check(status, this._ctx, 'licd_record_write');
    });
  }

  eraseRecord(name) {
    Session._requireName(name);
    check(fn.recordErase(this._dev, name), this._ctx, 'licd_record_erase');
  }

  eraseAllRecords() {
    check(fn.recordErase(this._dev, null), this._ctx, 'licd_record_erase');
  }

  readCounter(counterId) {
    const value = [0];
    check(fn.counterRead(this._dev, counterId, value), this._ctx, 'licd_counter_read');
    return value[0];
  }

  /** Irreversible: the counter is monotonic in hardware. Requires the write role. */
  incrementCounter(counterId) {
    const value = [0];
    check(fn.counterIncrement(this._dev, counterId, value), this._ctx, 'licd_counter_increment');
    return value[0];
  }

  /**
   * Encrypts so only a dongle of `scope` can decrypt. This is the pair to build a
   * licence check on: put something the app genuinely needs through it, so
   * removing the check removes the data.
   */
  appEncrypt(scope, plaintext) {
    if (scope !== Scope.DEVICE && scope !== Scope.DEVELOPER) {
      throw new TypeError('scope must be Scope.DEVICE or Scope.DEVELOPER');
    }
    const buf = toBuffer(plaintext, 'the plaintext');
    const out = [null];
    const outLen = [0];
    check(
      fn.appEncrypt(this._dev, scope, buf, buf.length, out, outLen),
      this._ctx,
      'licd_app_encrypt'
    );
    return native.takeBuffer(out, outLen);
  }

  appDecrypt(packed) {
    const buf = toBuffer(packed, 'the packed blob');
    const out = [null];
    const outLen = [0];
    check(fn.appDecrypt(this._dev, buf, buf.length, out, outLen), this._ctx, 'licd_app_decrypt');
    return native.takeBuffer(out, outLen);
  }
}

module.exports = {
  Context,
  Dongle,
  Session,
  Scope,
  LogLevel,
  ...errors,
};
