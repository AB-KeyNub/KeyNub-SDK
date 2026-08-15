'use strict';
// FFI layer: locates the native core and declares the C ABI
// (include/licdongle.h). The object model in index.js works only in
// terms of what this module exports.
//
// koffi rather than a compiled N-API addon: the whole point of this binding is
// that an Electron app can depend on it without a node-gyp toolchain on every
// developer's machine and without rebuilding per Electron ABI. The cost is that
// the C signatures live here as strings rather than being checked by a compiler,
// which is why every one of them matters.

const path = require('path');
const fs = require('fs');
const koffi = require('koffi');

// --- library discovery -------------------------------------------------------

const BASENAMES = {
  win32: 'keynub_licdongle.dll',
  darwin: 'libkeynub_licdongle.dylib',
};
const DEFAULT_LIB = BASENAMES[process.platform] || 'libkeynub_licdongle.so';

function repoRid() {
  const os = { win32: 'win', darwin: 'osx', linux: 'linux' }[process.platform];
  const arch = { x64: 'x64', ia32: 'x86', arm64: 'arm64' }[process.arch];
  return os && arch ? `${os}-${arch}` : 'unknown';
}

function repoRid() {
  const os = { win32: 'win', darwin: 'osx', linux: 'linux' }[process.platform];
  const arch = { x64: 'x64', ia32: 'x86', arm64: 'arm64' }[process.arch];
  return os && arch ? `${os}-${arch}` : 'unknown';
}

function candidatePaths() {
  // 1) explicit override, an absolute path to a specific library
  const override = process.env.KEYNUB_LICDONGLE_LIBRARY;
  if (override) {
    return [override];
  }
  const here = __dirname;
  return [
    // 2) native shipped inside the package, per platform+arch
    path.join(here, '..', 'prebuilds', `${process.platform}-${process.arch}`, DEFAULT_LIB),
    // 3) the prebuilt library a checkout of the SDK carries, per platform. Makes a
    //    clone runnable with nothing set; an installed package hits 2) instead.
    path.join(here, '..', '..', '..', 'natives', repoRid(), DEFAULT_LIB),
    // 4) alongside the package
    path.join(here, '..', DEFAULT_LIB),
    // 5) next to the application executable — where an Electron build puts it
    path.join(path.dirname(process.execPath), DEFAULT_LIB),
    // 6) system search path
    DEFAULT_LIB,
  ];
}

function load() {
  const errors = [];
  for (const candidate of candidatePaths()) {
    try {
      return koffi.load(candidate);
    } catch (err) {
      errors.push(`${candidate}: ${err.message}`);
    }
  }
  const err = new Error(
    'could not load the keynub_licdongle native library; tried:\n  ' + errors.join('\n  ')
  );
  err.code = 'KEYNUB_NATIVE_NOT_FOUND';
  throw err;
}

const lib = load();

// --- structures (mirror licdongle.h) ----------------------------------------

const LicdInfo = koffi.struct('licd_info', {
  proto_version_major: 'uint8_t',
  proto_version_minor: 'uint8_t',
  fw_version_major: 'uint8_t',
  fw_version_minor: 'uint8_t',
  fw_version_patch: 'uint8_t',
  se_ready: 'int',
  provisioned: 'int',
  data_capacity: 'uint32_t',
  data_free: 'uint32_t',
  watchdog_reboot: 'int',
  isolated: 'int',
  writeauth_rotated: 'int',
});

const LicdGenuineResult = koffi.struct('licd_genuine_result', {
  genuine: 'int',
  serial: koffi.array('char', 15, 'String'),
  provisioned_date: koffi.array('char', 11, 'String'),
});

const LicdDeviceInfo = koffi.struct('licd_device_info', {
  serial: koffi.array('char', 15, 'String'),
  path: koffi.array('char', 512, 'String'),
  vendor_id: 'uint16_t',
  product_id: 'uint16_t',
});

// Callback prototypes. cdecl, matching the C ABI.
const ProgressCb = koffi.proto('int licd_progress_cb(uint32_t done, uint32_t total, void *user)');
const LogCb = koffi.proto('void licd_log_cb(int level, const char *msg, void *user)');

// --- prototypes --------------------------------------------------------------

const fn = {
  version: lib.func('void licd_version(_Out_ int *major, _Out_ int *minor, _Out_ int *patch)'),
  init: lib.func('int licd_init(_Out_ void **out_ctx)'),
  free: lib.func('void licd_free(void *ctx)'),
  setLogCallback: lib.func('void licd_set_log_callback(void *ctx, licd_log_cb *cb, void *user)'),
  setTrustRoot: lib.func('int licd_set_trust_root(void *ctx, const void *der, size_t len)'),

  enumerate: lib.func('int licd_enumerate(void *ctx, _Out_ void **list, _Out_ size_t *count)'),
  freeDeviceList: lib.func('void licd_free_device_list(void *list, size_t count)'),
  open: lib.func('int licd_open(void *ctx, const char *serial, _Out_ void **out_dev)'),
  openPath: lib.func('int licd_open_path(void *ctx, const char *path, _Out_ void **out_dev)'),
  close: lib.func('void licd_close(void *dev)'),

  getInfo: lib.func('int licd_get_info(void *dev, _Out_ licd_info *out)'),
  getSerial: lib.func('int licd_get_serial(void *dev, _Out_ uint8_t *out, size_t size)'),

  verifyGenuine: lib.func('int licd_verify_genuine(void *dev, _Out_ licd_genuine_result *out)'),
  sessionOpen: lib.func('int licd_session_open(void *dev)'),
  sessionClose: lib.func('int licd_session_close(void *dev)'),
  writeAuth: lib.func('int licd_write_auth(void *dev, const void *der, size_t len)'),
  writeAuthRotate: lib.func('int licd_write_auth_rotate(void *dev, const void *der, size_t len)'),

  recordList: lib.func(
    'int licd_record_list(void *dev, _Out_ void **names, _Out_ void **sizes, _Out_ size_t *count)'
  ),
  freeRecordList: lib.func('void licd_free_record_list(void *names, void *sizes, size_t count)'),
  recordRead: lib.func(
    'int licd_record_read(void *dev, const char *name, uint32_t offset, _Out_ void *buf, ' +
      'uint32_t buf_size, _Out_ uint32_t *out_len, _Out_ uint32_t *out_total, ' +
      'licd_progress_cb *progress, void *user)'
  ),
  recordWrite: lib.func(
    'int licd_record_write(void *dev, const char *name, const void *data, uint32_t len, ' +
      'licd_progress_cb *progress, void *user)'
  ),
  recordErase: lib.func('int licd_record_erase(void *dev, const char *name)'),

  counterRead: lib.func('int licd_counter_read(void *dev, uint8_t id, _Out_ uint32_t *out)'),
  counterIncrement: lib.func(
    'int licd_counter_increment(void *dev, uint8_t id, _Out_ uint32_t *out)'
  ),

  appEncrypt: lib.func(
    'int licd_app_encrypt(void *dev, int scope, const void *plaintext, uint32_t len, ' +
      '_Out_ void **out, _Out_ uint32_t *out_len)'
  ),
  appDecrypt: lib.func(
    'int licd_app_decrypt(void *dev, const void *packed, uint32_t packed_len, ' +
      '_Out_ void **out, _Out_ uint32_t *out_len)'
  ),
  freeBuffer: lib.func('void licd_free_buffer(void *buf)'),

  strerror: lib.func('const char *licd_strerror(int status)'),
  errorDetail: lib.func('const char *licd_error_detail(void *ctx)'),
};

// --- decoding helpers --------------------------------------------------------

/** Copies `len` bytes out of a library-allocated buffer into a Buffer. */
function readBytes(pointer, len) {
  if (!pointer || len === 0) {
    return Buffer.alloc(0);
  }
  return Buffer.from(koffi.decode(pointer, koffi.array('uint8_t', len, 'Typed')));
}

/** Takes ownership of a licd_free_buffer-owned buffer: copy, then always free. */
function takeBuffer(pointerOut, lenOut) {
  try {
    return readBytes(pointerOut[0], lenOut[0]);
  } finally {
    if (pointerOut[0]) {
      fn.freeBuffer(pointerOut[0]);
    }
  }
}

/** Decodes an array of NUL-terminated C strings from a char**. */
function readStringArray(pointer, count) {
  if (!pointer || count === 0) {
    return [];
  }
  const pointers = koffi.decode(pointer, koffi.array('void *', count, 'Array'));
  return pointers.map((p) => (p ? koffi.decode(p, 'char', -1) : ''));
}

function readUint32Array(pointer, count) {
  if (!pointer || count === 0) {
    return [];
  }
  return koffi.decode(pointer, koffi.array('uint32_t', count, 'Array'));
}

function readDeviceList(pointer, count) {
  if (!pointer || count === 0) {
    return [];
  }
  return koffi.decode(pointer, koffi.array(LicdDeviceInfo, count, 'Array'));
}

/** A NUL-terminated string sitting in a fixed-size output Buffer. */
function bufferToString(buf) {
  const end = buf.indexOf(0);
  return buf.subarray(0, end === -1 ? buf.length : end).toString('utf8');
}

module.exports = {
  koffi,
  lib,
  fn,
  LicdInfo,
  LicdGenuineResult,
  LicdDeviceInfo,
  ProgressCb,
  LogCb,
  readBytes,
  takeBuffer,
  readStringArray,
  readUint32Array,
  readDeviceList,
  bufferToString,
  libraryPathTried: candidatePaths,
  fs,
};
