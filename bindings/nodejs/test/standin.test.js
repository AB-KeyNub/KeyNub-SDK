'use strict';
// Every call of the binding against a stand-in for the C ABI
// (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory),
// compiled into a shared library with a C compiler from the path (cc, gcc,
// clang, zig cc or cl). KEYNUB_LICDONGLE_LIBRARY naming an already compiled
// stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the test
// does not run inside a clone.
//
//     node --test test/standin.test.js        (from bindings/nodejs)

const test = require('node:test');
const assert = require('node:assert');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const SERIAL = '04A1B2C3D4E5F6';
const FACTORY_KEY = Buffer.from([0x30, 0x10, 0x01, 0x02, 0x03]);
const REPLACEMENT_KEY = Buffer.from([0x30, 0x11, 0x09, 0x08, 0x07, 0x06]);

// ---- the stand-in -------------------------------------------------------------

function sdkRoot() {
  if (process.env.KEYNUB_SDK_ROOT) {
    return process.env.KEYNUB_SDK_ROOT;
  }
  for (let dir = process.cwd(); ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, 'bindings', 'flat', 'licd_flat.c'))) {
      return dir;
    }
    if (path.dirname(dir) === dir) {
      break;
    }
  }
  throw new Error('the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT');
}

function buildStandIn() {
  const root = sdkRoot();
  const windows = process.platform === 'win32';
  const tmp = os.tmpdir();
  // Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf
  // name even for an absolute-path dlopen, and a build tree on that path holds
  // the real library under that name.
  const output = path.join(tmp, windows ? 'keynub_licdongle_standin.dll' : 'libkeynub_licdongle_standin.so');
  let include = path.join(root, 'core', 'include');
  if (!fs.existsSync(path.join(include, 'licdongle.h'))) {
    include = path.join(root, 'include');
  }
  const source = path.join(root, 'bindings', 'julia', 'test', 'stub', 'licd_stub.c');
  const gcc = ['-shared', '-O1', '-DLICD_BUILD_SHARED', `-I${include}`, '-o', output, source];
  if (!windows) {
    gcc.push('-fPIC');
  }
  const cl = ['/nologo', '/LD', '/O1', '/DLICD_BUILD_SHARED', `/I${include}`, `/Fe:${output}`, source];
  const compilers = [['cc', ...gcc], ['gcc', ...gcc], ['clang', ...gcc], ['zig', 'cc', ...gcc], ['cl', ...cl]];
  for (const [command, ...args] of compilers) {
    // In the temporary folder, where the compilers leave their byproducts.
    const done = childProcess.spawnSync(command, args, { cwd: tmp, stdio: 'ignore' });
    if (!done.error && done.status === 0 && fs.existsSync(output)) {
      return output;
    }
  }
  throw new Error('the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path');
}

// The library is chosen when the binding is first loaded, once per process, so
// this file runs in a process of its own (the node --test default).
function loadBinding() {
  const binding = path.resolve(__dirname, '..');
  if (require.cache[path.join(binding, 'lib', 'native.js')]) {
    throw new Error('the binding is already loaded in this process; run this file in a process of its own');
  }
  process.env.KEYNUB_LICDONGLE_LIBRARY = process.env.KEYNUB_LICDONGLE_LIBRARY || buildStandIn();
  return require(binding);
}

const keynub = loadBinding();
const { Context, Scope, Status } = keynub;

// ---- the checks ----------------------------------------------------------------

// Runs `body(dongle, ctx)` against a freshly opened stand-in and always tears down.
function withDongle(body) {
  const ctx = new Context();
  const dongle = ctx.open();
  try {
    return body(dongle, ctx);
  } finally {
    dongle.close();
    ctx.close();
  }
}

function fails(ErrorType, status, action) {
  assert.throws(action, (err) => err instanceof ErrorType && err.status === status);
}

test('library version', () => {
  assert.deepStrictEqual(Context.libraryVersion(), { major: 9, minor: 8, patch: 7 });
});

test('status text and error detail', () => {
  withDongle((dongle, ctx) => {
    assert.strictEqual(Status.NO_DEVICE, -2);
    assert.throws(() => ctx.open('nope'), (err) =>
      err instanceof keynub.DeviceNotFoundError &&
      err.code === 'KEYNUB_NO_DEVICE' &&
      err.message === 'licd_open: no device (no dongle with that serial)' &&
      err.detail === 'no dongle with that serial');
    assert.strictEqual(ctx.lastErrorDetail, 'no dongle with that serial');
  });
});

test('devices, open by serial and by path', () => {
  withDongle((dongle, ctx) => {
    assert.deepStrictEqual(ctx.enumerate(),
      [{ serial: SERIAL, path: 'stub:0', vendorId: 0x1234, productId: 0xabcd }]);
    fails(keynub.DeviceNotFoundError, Status.NO_DEVICE, () => ctx.open('nope'));
    fails(keynub.DeviceNotFoundError, Status.NO_DEVICE, () => ctx.openPath('stub:9'));
    const bySerial = ctx.open(SERIAL);
    assert.strictEqual(bySerial.getSerial(), SERIAL);
    bySerial.close();
    const byPath = ctx.openPath('stub:0');
    assert.strictEqual(byPath.getSerial(), SERIAL);
    byPath.close();
  });
});

test('info fields and flags', () => {
  withDongle((dongle) => {
    assert.strictEqual(dongle.getSerial(), SERIAL);
    assert.deepStrictEqual(dongle.getInfo(), {
      protocolVersion: [1, 0],
      firmwareVersion: [2, 3, 4],
      seReady: true,
      provisioned: true,
      dataCapacity: 1024 * 1024,
      dataFree: 1000000,
      watchdogReboot: false,
      isolated: true,
      writeAuthRotated: false,
    });
  });
});

test('verifyGenuine, isGenuine and the trust root', () => {
  withDongle((dongle, ctx) => {
    assert.deepStrictEqual(dongle.verifyGenuine(),
      { genuine: true, serial: SERIAL, provisionedDate: '2026-08-15' });
    assert.deepStrictEqual(dongle.isGenuine(), { genuine: true, code: null });

    fails(keynub.CertificateInvalidError, Status.CERTIFICATE_INVALID,
      () => ctx.setTrustRoot(Buffer.from([0x02, 0x01, 0x00])));
    fails(keynub.LicenseDongleError, Status.INVALID_ARGUMENT, () => ctx.setTrustRoot(Buffer.alloc(0)));
    assert.throws(() => ctx.setTrustRoot(42), TypeError);

    const root = Buffer.alloc(132, 0xab);
    root.set([0x30, 0x82, 0x01, 0x00]);
    ctx.setTrustRoot(root);
    fails(keynub.CertificateInvalidError, Status.CERTIFICATE_INVALID, () => dongle.verifyGenuine());
    assert.deepStrictEqual(dongle.isGenuine(), { genuine: false, code: 'KEYNUB_CERTIFICATE_INVALID' });
    root.fill(0x01, 4);
    ctx.setTrustRoot(new Uint8Array(root));
    assert.deepStrictEqual(dongle.isGenuine(), { genuine: true, code: null });
  });
});

test('a session is required', () => {
  withDongle((dongle) => {
    // A second Session object ends the dongle's session under the first one.
    const first = dongle.openSession();
    const second = dongle.openSession();
    second.close();
    fails(keynub.SessionExpiredError, Status.SESSION_EXPIRED, () => first.listRecords());
    first.close();
    assert.strictEqual(first.closed, true);
    fails(keynub.SessionExpiredError, Status.SESSION_EXPIRED, () => first.listRecords());
    first.close(); // idempotent
  });
});

test('the write role', () => {
  withDongle((dongle) => {
    const s = dongle.openSession();
    fails(keynub.WriteAuthorizationRequiredError, Status.AUTH_REQUIRED, () => s.writeRecord('lic', 'x'));
    fails(keynub.WriteAuthorizationRequiredError, Status.AUTH_REQUIRED, () => s.incrementCounter(0));
    fails(keynub.NotGenuineError, Status.NOT_GENUINE, () => s.authorizeWrite(Buffer.from([0x30, 0x00])));
    s.authorizeWrite(FACTORY_KEY);
    s.writeRecord('lic', 'x');
    s.close();
  });
});

test('records', () => {
  withDongle((dongle) => {
    const s = dongle.openSession();
    s.authorizeWrite(FACTORY_KEY);
    const payload = Buffer.from('license-blob-0123456789');
    s.writeRecord('lic', payload);
    assert.deepStrictEqual(s.readRecord('lic'), payload);
    s.writeRecord('cfg', 'cfgdata');
    const recs = s.listRecords();
    assert.deepStrictEqual(recs.map((r) => r.name).sort(), ['cfg', 'lic']);
    assert.ok(recs.some((r) => r.name === 'lic' && r.size === payload.length));
    assert.deepStrictEqual(s.readRecord('cfg'), Buffer.from('cfgdata'));
    fails(keynub.RecordNotFoundError, Status.NOT_FOUND, () => s.readRecord('nope'));
    fails(keynub.RecordNotFoundError, Status.NOT_FOUND, () => s.eraseRecord('nope'));
    assert.throws(() => s.eraseRecord(''), TypeError);
    assert.throws(() => s.readRecord(''), TypeError);
    assert.throws(() => s.writeRecord('bad', 42), TypeError);
    assert.strictEqual(s.listRecords().length, 2);
    s.eraseRecord('cfg');
    assert.deepStrictEqual(s.listRecords().map((r) => r.name), ['lic']);
    s.writeRecord('empty', Buffer.alloc(0));
    const empty = s.readRecord('empty');
    assert.ok(Buffer.isBuffer(empty) && empty.length === 0);
    s.writeRecord('typed', new Uint8Array([1, 2, 3]));
    assert.deepStrictEqual(s.readRecord('typed'), Buffer.from([1, 2, 3]));
    s.writeRecord('arraybuffer', new Uint8Array([4, 5]).buffer);
    assert.deepStrictEqual(s.readRecord('arraybuffer'), Buffer.from([4, 5]));
    const big = Buffer.from(Array.from({ length: 2000 }, (_, k) => (k * 31 + 5) & 0xff));
    s.writeRecord('big', big);
    assert.deepStrictEqual(s.readRecord('big'), big);
    s.eraseAllRecords();
    assert.deepStrictEqual(s.listRecords(), []);
    s.close();
  });
});

test('progress and cancellation', () => {
  withDongle((dongle) => {
    const s = dongle.openSession();
    s.authorizeWrite(FACTORY_KEY);
    const big = Buffer.from(Array.from({ length: 2000 }, (_, k) => (k * 31 + 5) & 0xff));
    const writes = [];
    s.writeRecord('big', big, (done, total) => {
      writes.push([done, total]);
    });
    assert.deepStrictEqual(writes[writes.length - 1], [2000, 2000]);
    const reads = [];
    assert.deepStrictEqual(s.readRecord('big', (done, total) => {
      reads.push([done, total]);
      return true;
    }), big);
    assert.deepStrictEqual(reads[reads.length - 1], [2000, 2000]);
    fails(keynub.OperationCancelledError, Status.CANCELLED, () => s.readRecord('big', () => false));
    fails(keynub.OperationCancelledError, Status.CANCELLED, () => s.writeRecord('big', big, () => false));
    const sentinel = new Error('callback exploded');
    assert.throws(() => s.readRecord('big', () => {
      throw sentinel;
    }), (err) => err === sentinel);
    assert.deepStrictEqual(s.readRecord('big'), big);
    assert.throws(() => s.readRecord('big', 'nope'), TypeError);
    s.writeRecord('empty', Buffer.alloc(0));
    const ticks = [];
    s.readRecord('empty', (done, total) => {
      ticks.push([done, total]);
    });
    assert.deepStrictEqual(ticks, [[0, 0]]);
    s.close();
  });
});

test('counters', () => {
  withDongle((dongle) => {
    const s = dongle.openSession();
    s.authorizeWrite(FACTORY_KEY);
    const before = s.readCounter(0);
    assert.strictEqual(s.incrementCounter(0), before + 1);
    assert.strictEqual(s.readCounter(0), before + 1);
    assert.strictEqual(s.readCounter(1), 0);
    fails(keynub.LicenseDongleError, Status.RANGE, () => s.readCounter(7));
    fails(keynub.LicenseDongleError, Status.RANGE, () => s.incrementCounter(7));
    s.close();
  });
});

test('appEncrypt and appDecrypt, both scopes', () => {
  withDongle((dongle) => {
    const s = dongle.openSession();
    const secret = Buffer.from(Array.from({ length: 100 }, (_, k) => (3 * k + 7) % 256));
    for (const scope of [Scope.DEVICE, Scope.DEVELOPER]) {
      const blob = s.appEncrypt(scope, secret);
      assert.ok(blob.length > secret.length, `sealed data is longer, scope ${scope}`);
      assert.strictEqual(blob[0], scope, `scope byte, scope ${scope}`);
      assert.deepStrictEqual(s.appDecrypt(blob), secret);
      const tampered = Buffer.from(blob);
      tampered[tampered.length - 1] ^= 1;
      assert.throws(() => s.appDecrypt(tampered),
        (err) => err.status === Status.TAG_MISMATCH && err.code === 'KEYNUB_TAG_MISMATCH');
    }
    assert.throws(() => s.appEncrypt(7, secret), TypeError);
    assert.deepStrictEqual(s.appDecrypt(s.appEncrypt(Scope.DEVICE, Buffer.alloc(0))), Buffer.alloc(0));
    fails(keynub.LicenseDongleError, Status.INVALID_ARGUMENT, () => s.appDecrypt(Buffer.from([0, 1])));
    s.close();
  });
});

test('write-key rotation', () => {
  withDongle((dongle) => {
    let s = dongle.openSession();
    fails(keynub.WriteAuthorizationRequiredError, Status.AUTH_REQUIRED, () => s.rotateWriteKey(REPLACEMENT_KEY));
    s.authorizeWrite(FACTORY_KEY);
    s.rotateWriteKey(REPLACEMENT_KEY);
    s.writeRecord('lic', 'still-writable');
    s.close();
    assert.strictEqual(dongle.getInfo().writeAuthRotated, true);
    s = dongle.openSession();
    fails(keynub.NotGenuineError, Status.NOT_GENUINE, () => s.authorizeWrite(FACTORY_KEY));
    s.authorizeWrite(REPLACEMENT_KEY);
    s.writeRecord('lic', 'new-key-writes');
    assert.deepStrictEqual(s.readRecord('lic'), Buffer.from('new-key-writes'));
    s.close();
  });
});

test('the log callback can be set and cleared', () => {
  withDongle((dongle, ctx) => {
    const lines = [];
    ctx.setLogCallback((level, message) => lines.push([level, message]));
    dongle.getInfo();
    ctx.setLogCallback(null);
    assert.strictEqual(dongle.getSerial(), SERIAL);
  });
});

test('close semantics', () => {
  const ctx = new Context();
  const dongle = ctx.open();
  const session = dongle.openSession();
  dongle.close();
  dongle.close(); // idempotent
  assert.strictEqual(dongle.closed, true);
  fails(keynub.LicenseDongleError, Status.INVALID_ARGUMENT, () => dongle.getSerial());
  // A session whose dongle was closed refuses, and closing it does not touch the device.
  fails(keynub.LicenseDongleError, Status.INVALID_ARGUMENT, () => session.listRecords());
  session.close();

  const disposable = ctx.open();
  disposable[Symbol.dispose ?? Symbol.for('nodejs.dispose')]();
  assert.strictEqual(disposable.closed, true);

  ctx.close();
  ctx.close(); // idempotent
  assert.strictEqual(ctx.closed, true);
  fails(keynub.LicenseDongleError, Status.INVALID_ARGUMENT, () => ctx.enumerate());
});
