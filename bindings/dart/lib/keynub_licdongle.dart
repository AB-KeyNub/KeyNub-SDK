/// KeyNub License Dongle: verify a genuine KeyNub USB dongle, read and write
/// its license records, use its counters and encrypt data so that only a dongle
/// can decrypt it. Pure Dart over the SDK's C library through `dart:ffi`; the
/// library is loaded at run time, see [LicDongleLibrary].
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/bindings.dart';
import 'src/library.dart';

export 'src/library.dart' show LicDongleLibrary, LibraryLoadError, libraryVersion;

/// The status codes the native library reports; `ok` is zero, every failure is
/// negative.
enum Status {
  ok(0),
  invalidArgument(-1),
  noDevice(-2),
  accessDenied(-3),
  io(-4),
  timeout(-5),
  protocolError(-6),
  notGenuine(-7),
  certificateInvalid(-8),
  sessionExpired(-9),
  tagMismatch(-10),
  range(-11),
  storageFull(-12),
  busy(-13),
  notFound(-14),
  authRequired(-15),
  firmwareIncompatible(-16),
  sdkTooOld(-17),
  cancelled(-18),
  notImplemented(-19),
  internalError(-20);

  const Status(this.code);

  /// The numeric code of the C ABI.
  final int code;

  /// The status for a code; unknown codes map to [internalError].
  static Status fromCode(int code) =>
      values.firstWhere((s) => s.code == code, orElse: () => internalError);

  /// The library's short text for the code.
  String get message {
    try {
      return LicDongleLibrary.api().strerror(code).cast<Utf8>().toDartString();
    } on LibraryLoadError {
      return 'status $code';
    }
  }
}

/// A failure reported by the native library.
///
/// [status] is what happened, [operation] the SDK function that reported it,
/// and [detail] the library's diagnostic text for this failure, or `''`. Log
/// the detail; do not parse it.
class LicenseDongleError implements Exception {
  LicenseDongleError(int code, this.operation, this.detail)
      : status = Status.fromCode(code),
        message = Status.fromCode(code).message;

  final Status status;
  final String operation;
  final String detail;

  /// The library's text for [status], read when the error was created.
  final String message;

  @override
  String toString() =>
      detail.isEmpty ? '$operation: $message' : '$operation: $message ($detail)';
}

/// Who can decrypt data produced by [Session.appEncrypt].
enum Scope {
  /// Only the one physical dongle that encrypted it.
  device(0),

  /// Any dongle issued by the same developer, so one blob serves every customer.
  developer(1);

  const Scope(this.code);
  final int code;
}

/// One attached dongle, as enumerated.
class DeviceInfo {
  const DeviceInfo(this.serial, this.path, this.vendorId, this.productId);

  /// The serial as hex.
  final String serial;

  /// The operating system's device path, accepted by [Context.openPath].
  final String path;
  final int vendorId;
  final int productId;

  @override
  String toString() =>
      'DeviceInfo($serial, $path, ${vendorId.toRadixString(16)}:${productId.toRadixString(16)})';
}

/// Plaintext device information from [Dongle.info].
class Info {
  const Info({
    required this.protocolVersion,
    required this.firmwareVersion,
    required this.secureElementReady,
    required this.provisioned,
    required this.dataCapacity,
    required this.dataFree,
    required this.watchdogReboot,
    required this.isolated,
    required this.writeAuthRotated,
  });

  final ({int major, int minor}) protocolVersion;
  final ({int major, int minor, int patch}) firmwareVersion;

  /// The secure element responded.
  final bool secureElementReady;

  /// Factory provisioning is complete.
  final bool provisioned;
  final int dataCapacity;
  final int dataFree;

  /// The dongle's *previous* boot ended in a watchdog timeout: the firmware
  /// hung and reset itself. The only trace a field hang leaves; log it.
  final bool watchdogReboot;

  /// The dongle confirmed at boot that its USB code is fenced off from keys
  /// and storage.
  final bool isolated;

  /// The write key has been rotated away from the public factory one. Rotate
  /// on receipt, and check this before shipping a dongle to anyone.
  final bool writeAuthRotated;
}

/// The result of a successful [Dongle.verifyGenuine].
class GenuineResult {
  const GenuineResult(this.genuine, this.serial, this.provisionedDate);
  final bool genuine;

  /// The serial from the verified certificate.
  final String serial;

  /// `YYYY-MM-DD`, or `''`.
  final String provisionedDate;
}

/// One record as listed: its name and size in bytes.
class RecordInfo {
  const RecordInfo(this.name, this.size);
  final String name;
  final int size;

  @override
  String toString() => 'RecordInfo($name, $size bytes)';
}

/// Reports a transfer: `(done, total)` in bytes. Return `false` to cancel,
/// which makes the call throw [Status.cancelled]. An exception thrown inside
/// cancels the transfer as well and is rethrown after the C frames have
/// unwound.
typedef ProgressCallback = bool Function(int done, int total);

LicenseDongleError _fail(Api api, int rc, String operation, Pointer<Void> ctx) {
  final detail = ctx == nullptr
      ? ''
      : api.errorDetail(ctx).cast<Utf8>().toDartString();
  return LicenseDongleError(rc, operation, detail);
}

void _check(Api api, int rc, String operation, Pointer<Void> ctx) {
  if (rc != 0) throw _fail(api, rc, operation, ctx);
}

Pointer<Uint8> _cstr(String s) => s.toNativeUtf8().cast<Uint8>();

Uint8List _bytes(Object data, String what) {
  if (data is Uint8List) return data;
  if (data is List<int>) return Uint8List.fromList(data);
  if (data is String) return Uint8List.fromList(utf8.encode(data));
  throw ArgumentError('$what must be a Uint8List, a List<int> or a String');
}

/// A library context. It owns the connection to the operating system's USB
/// layer and the dongles opened on it; one per program is usual. Close it with
/// [close] when done, which also closes every dongle still open on it.
class Context {
  /// Creates a context, loading the native library if this is the first call.
  Context() : _api = LicDongleLibrary.api() {
    final out = calloc<Pointer<Void>>();
    try {
      final rc = _api.init(out);
      if (rc != 0) throw LicenseDongleError(rc, 'licd_init', '');
      _handle = out.value;
    } finally {
      calloc.free(out);
    }
  }

  final Api _api;
  Pointer<Void> _handle = nullptr;
  final List<Dongle> _dongles = [];

  /// `true` while the context can be used.
  bool get isOpen => _handle != nullptr;

  Pointer<Void> get _ctx {
    if (_handle == nullptr) {
      throw LicenseDongleError(
          Status.invalidArgument.code, 'licd_ctx', 'the context has been closed');
    }
    return _handle;
  }

  /// Closes every dongle still open on this context, then the context. Safe to
  /// call more than once.
  void close() {
    for (final dongle in List.of(_dongles)) {
      dongle.close();
    }
    _dongles.clear();
    if (_handle != nullptr) {
      _api.free(_handle);
      _handle = nullptr;
    }
  }

  /// The library's diagnostic text for the most recent failure on this thread.
  String get lastErrorDetail => _handle == nullptr
      ? ''
      : _api.errorDetail(_handle).cast<Utf8>().toDartString();

  /// Replaces the CA root certificate (DER) that [Dongle.verifyGenuine] checks
  /// the dongle's certificate chain against. Applications do not need this: a
  /// release build of the library embeds the KeyNub production root.
  void setTrustRoot(List<int> der) {
    final ctx = _ctx;
    final bytes = _bytes(der, 'der');
    final p = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      p.asTypedList(bytes.isEmpty ? 1 : bytes.length).setAll(0, bytes);
      _check(_api, _api.setTrustRoot(ctx, bytes.isEmpty ? nullptr : p, bytes.length),
          'licd_set_trust_root', ctx);
    } finally {
      calloc.free(p);
    }
  }

  /// The attached dongles, without opening any.
  List<DeviceInfo> enumerate() {
    final ctx = _ctx;
    final list = calloc<Pointer<LicdDeviceInfo>>();
    final count = calloc<Size>();
    try {
      _check(_api, _api.enumerate(ctx, list, count), 'licd_enumerate', ctx);
      final n = count.value;
      final out = <DeviceInfo>[];
      for (var i = 0; i < n; i++) {
        final d = list.value[i];
        out.add(DeviceInfo(cString(d.serial, serialHexLen + 1),
            cString(d.path, 512), d.vendorId, d.productId));
      }
      _api.freeDeviceList(list.value, n);
      return out;
    } finally {
      calloc.free(list);
      calloc.free(count);
    }
  }

  /// Opens the dongle with [serial], or the first one found when `null`.
  /// Throws [LicenseDongleError] with [Status.noDevice] when none matches.
  Dongle open({String? serial}) {
    final ctx = _ctx;
    final out = calloc<Pointer<Void>>();
    final cserial = serial == null ? nullptr : _cstr(serial);
    try {
      _check(_api, _api.open(ctx, cserial, out), 'licd_open', ctx);
      return _register(Dongle._(this, _api, out.value));
    } finally {
      calloc.free(out);
      if (cserial != nullptr) calloc.free(cserial);
    }
  }

  /// Opens the dongle at a device path from [enumerate].
  Dongle openPath(String path) {
    final ctx = _ctx;
    final out = calloc<Pointer<Void>>();
    final cpath = _cstr(path);
    try {
      _check(_api, _api.openPath(ctx, cpath, out), 'licd_open_path', ctx);
      return _register(Dongle._(this, _api, out.value));
    } finally {
      calloc.free(out);
      calloc.free(cpath);
    }
  }

  Dongle _register(Dongle d) {
    _dongles.add(d);
    return d;
  }

  void _forget(Dongle d) => _dongles.remove(d);
}

/// An open connection to one dongle. Obtained from [Context.open].
class Dongle {
  Dongle._(this.context, this._api, this._handle);

  /// The context this dongle was opened on.
  final Context context;
  final Api _api;
  Pointer<Void> _handle;

  /// `true` while the dongle can be used.
  bool get isOpen => _handle != nullptr;

  Pointer<Void> get _dev {
    if (_handle == nullptr) {
      throw LicenseDongleError(Status.invalidArgument.code, 'licd_device',
          'the dongle has been closed');
    }
    return _handle;
  }

  Pointer<Void> get _ctx => context._handle;

  /// Releases the dongle. Safe to call more than once.
  void close() {
    if (_handle != nullptr) {
      _api.close(_handle);
      _handle = nullptr;
      context._forget(this);
    }
  }

  /// Plaintext device information; needs no session.
  Info info() {
    final dev = _dev;
    final raw = calloc<LicdInfo>();
    try {
      _check(_api, _api.getInfo(dev, raw), 'licd_get_info', _ctx);
      final r = raw.ref;
      return Info(
        protocolVersion: (major: r.protoVersionMajor, minor: r.protoVersionMinor),
        firmwareVersion: (
          major: r.fwVersionMajor,
          minor: r.fwVersionMinor,
          patch: r.fwVersionPatch
        ),
        secureElementReady: r.seReady != 0,
        provisioned: r.provisioned != 0,
        dataCapacity: r.dataCapacity,
        dataFree: r.dataFree,
        watchdogReboot: r.watchdogReboot != 0,
        isolated: r.isolated != 0,
        writeAuthRotated: r.writeauthRotated != 0,
      );
    } finally {
      calloc.free(raw);
    }
  }

  /// The dongle's serial as hex.
  String serial() {
    final dev = _dev;
    final buffer = calloc<Uint8>(serialHexLen + 1);
    try {
      _check(_api, _api.getSerial(dev, buffer, serialHexLen + 1),
          'licd_get_serial', _ctx);
      return buffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buffer);
    }
  }

  /// Proves authenticity: the certificate chain to the trusted root plus a
  /// live challenge-response. Throws unless the dongle is genuine.
  GenuineResult verifyGenuine() {
    final dev = _dev;
    final raw = calloc<LicdGenuineResult>();
    try {
      _check(_api, _api.verifyGenuine(dev, raw), 'licd_verify_genuine', _ctx);
      final r = raw.ref;
      if (r.genuine == 0) {
        throw LicenseDongleError(Status.notGenuine.code, 'licd_verify_genuine', '');
      }
      return GenuineResult(true, cString(r.serial, serialHexLen + 1),
          cString(r.provisionedDate, 11));
    } finally {
      calloc.free(raw);
    }
  }

  /// The non-throwing form of [verifyGenuine], for a gate. **Fails closed**: a
  /// missing dongle, an I/O error and an invalid certificate all give `false`.
  bool get isGenuine {
    try {
      verifyGenuine();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens the encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM) that
  /// records, counters and app-data encryption need. Close it with
  /// [Session.close], or use [withSession].
  Session openSession() {
    final dev = _dev;
    _check(_api, _api.sessionOpen(dev), 'licd_session_open', _ctx);
    return Session._(this, _api);
  }

  /// Opens a session, runs [body] with it and closes the session afterwards,
  /// whatever happens inside [body].
  T withSession<T>(T Function(Session session) body) {
    final session = openSession();
    try {
      return body(session);
    } finally {
      session.close();
    }
  }

  void _closeSession() {
    if (_handle != nullptr) _api.sessionClose(_handle);
  }
}

/// An open session on a dongle. Obtained from [Dongle.openSession] or
/// [Dongle.withSession]. Reading needs the session; writing, erasing and
/// counter increments need the write role, see [authorizeWrite].
class Session {
  Session._(this.dongle, this._api);

  /// The dongle this session is on.
  final Dongle dongle;
  final Api _api;
  bool _open = true;

  /// `true` until [close].
  bool get isOpen => _open;

  /// Ends the session. Safe to call more than once.
  void close() {
    if (_open) {
      _open = false;
      dongle._closeSession();
    }
  }

  Pointer<Void> get _dev {
    if (!_open) {
      throw LicenseDongleError(Status.sessionExpired.code, 'licd_session',
          'the session has been closed');
    }
    return dongle._dev;
  }

  Pointer<Void> get _ctx => dongle._ctx;

  static void _requireName(String name) {
    if (name.isEmpty) {
      throw LicenseDongleError(Status.invalidArgument.code, 'licd_record',
          'the record name must not be empty');
    }
  }

  T _withBytes<T>(List<int> data, T Function(Pointer<Uint8> p, int len) body) {
    final bytes = _bytes(data, 'data');
    final p = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      p.asTypedList(bytes.isEmpty ? 1 : bytes.length).setAll(0, bytes);
      return body(bytes.isEmpty ? nullptr : p, bytes.length);
    } finally {
      calloc.free(p);
    }
  }

  /// Elevates to the write role with the dongle's write key (a P-256 private
  /// key in PKCS#8 DER). This belongs in your licence-issuing tooling; never
  /// ship that key in the application your users run. A key the dongle does
  /// not accept throws [Status.notGenuine].
  void authorizeWrite(List<int> key) {
    final dev = _dev;
    _withBytes(key, (p, len) =>
        _check(_api, _api.writeAuth(dev, p, len), 'licd_write_auth', _ctx));
  }

  /// Replaces the dongle's write key with [key], a key you hold. Needs the
  /// write role; this session keeps it, and from the next session on only the
  /// new key elevates. Do this once per dongle, when it arrives: the factory
  /// key is public.
  void rotateWriteKey(List<int> key) {
    final dev = _dev;
    _withBytes(key, (p, len) => _check(_api, _api.writeAuthRotate(dev, p, len),
        'licd_write_auth_rotate', _ctx));
  }

  /// The records on the dongle.
  List<RecordInfo> records() {
    final dev = _dev;
    final names = calloc<Pointer<Pointer<Uint8>>>();
    final sizes = calloc<Pointer<Uint32>>();
    final count = calloc<Size>();
    try {
      _check(_api, _api.recordList(dev, names, sizes, count), 'licd_record_list', _ctx);
      final n = count.value;
      final out = <RecordInfo>[];
      for (var i = 0; i < n; i++) {
        final name = names.value[i];
        out.add(RecordInfo(
            name == nullptr ? '' : name.cast<Utf8>().toDartString(),
            sizes.value[i]));
      }
      _api.freeRecordList(names.value, sizes.value, n);
      return out;
    } finally {
      calloc.free(names);
      calloc.free(sizes);
      calloc.free(count);
    }
  }

  /// Reads a record. A record that does not exist throws [Status.notFound].
  Uint8List readRecord(String name, {ProgressCallback? progress}) {
    _requireName(name);
    final dev = _dev;
    final cname = _cstr(name);
    final got = calloc<Uint32>();
    final total = calloc<Uint32>();
    final probe = calloc<Uint8>(1);
    try {
      // Probe for the size first, so progress runs from 0 to the total once.
      _check(_api, _api.recordRead(dev, cname, 0, probe, 1, got, total, nullptr, nullptr),
          'licd_record_read', _ctx);
      final size = total.value;
      if (size == 0) return Uint8List(0);
      final buffer = calloc<Uint8>(size);
      try {
        final bridge = _ProgressBridge(progress);
        final rc = bridge.call((fn, user) => _api.recordRead(
            dev, cname, 0, buffer, size, got, total, fn, user));
        bridge.rethrowIfFailed();
        _check(_api, rc, 'licd_record_read', _ctx);
        return Uint8List.fromList(buffer.asTypedList(got.value));
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(cname);
      calloc.free(got);
      calloc.free(total);
      calloc.free(probe);
    }
  }

  /// Atomically replaces a record with [data] (bytes, or a string's UTF-8).
  /// Needs the write role.
  void writeRecord(String name, Object data, {ProgressCallback? progress}) {
    _requireName(name);
    final dev = _dev;
    final cname = _cstr(name);
    try {
      _withBytes(_bytes(data, 'data'), (p, len) {
        final bridge = _ProgressBridge(progress);
        final rc = bridge.call(
            (fn, user) => _api.recordWrite(dev, cname, p, len, fn, user));
        bridge.rethrowIfFailed();
        _check(_api, rc, 'licd_record_write', _ctx);
      });
    } finally {
      calloc.free(cname);
    }
  }

  /// Erases one record. Needs the write role. A missing record throws
  /// [Status.notFound].
  void eraseRecord(String name) {
    // To the C library a null name means "erase everything"; that is
    // eraseAllRecords() here, so an empty string can never wipe the dongle.
    _requireName(name);
    final dev = _dev;
    final cname = _cstr(name);
    try {
      _check(_api, _api.recordErase(dev, cname), 'licd_record_erase', _ctx);
    } finally {
      calloc.free(cname);
    }
  }

  /// Erases every record. Needs the write role.
  void eraseAllRecords() {
    final dev = _dev;
    _check(_api, _api.recordErase(dev, nullptr), 'licd_record_erase', _ctx);
  }

  static int _counterId(int id) {
    if (id < 0 || id > 255) {
      throw ArgumentError.value(id, 'id', 'must be from 0 to 255');
    }
    return id;
  }

  /// Reads a hardware monotonic counter.
  int readCounter(int id) {
    final dev = _dev;
    final value = calloc<Uint32>();
    try {
      _check(_api, _api.counterRead(dev, _counterId(id), value), 'licd_counter_read', _ctx);
      return value.value;
    } finally {
      calloc.free(value);
    }
  }

  /// Increments a counter, irreversibly; needs the write role. Returns the new
  /// value.
  int incrementCounter(int id) {
    final dev = _dev;
    final value = calloc<Uint32>();
    try {
      _check(_api, _api.counterIncrement(dev, _counterId(id), value),
          'licd_counter_increment', _ctx);
      return value.value;
    } finally {
      calloc.free(value);
    }
  }

  Uint8List _takeBuffer(Pointer<Pointer<Uint8>> out, Pointer<Uint32> outLen) {
    final p = out.value;
    final n = outLen.value;
    try {
      return p == nullptr ? Uint8List(0) : Uint8List.fromList(p.asTypedList(n));
    } finally {
      if (p != nullptr) _api.freeBuffer(p);
    }
  }

  /// Seals [plaintext] (bytes, or a string's UTF-8) so that only a dongle of
  /// [scope] can open it. The pair to build a licence check on: put something
  /// the program needs through it and ship only the sealed form, so removing
  /// the check removes the data.
  Uint8List appEncrypt(Object plaintext, Scope scope) {
    final dev = _dev;
    final out = calloc<Pointer<Uint8>>();
    final outLen = calloc<Uint32>();
    try {
      _withBytes(_bytes(plaintext, 'plaintext'), (p, len) => _check(_api,
          _api.appEncrypt(dev, scope.code, p, len, out, outLen), 'licd_app_encrypt', _ctx));
      return _takeBuffer(out, outLen);
    } finally {
      calloc.free(out);
      calloc.free(outLen);
    }
  }

  /// Opens data sealed with [appEncrypt].
  Uint8List appDecrypt(List<int> packed) {
    final dev = _dev;
    final out = calloc<Pointer<Uint8>>();
    final outLen = calloc<Uint32>();
    try {
      _withBytes(packed, (p, len) => _check(_api,
          _api.appDecrypt(dev, p, len, out, outLen), 'licd_app_decrypt', _ctx));
      return _takeBuffer(out, outLen);
    } finally {
      calloc.free(out);
      calloc.free(outLen);
    }
  }
}

/// Carries a Dart progress callback across the C boundary as a
/// [NativeCallable]. An exception thrown by the callback is stored and the
/// transfer cancelled; it is rethrown once the C call has returned.
class _ProgressBridge {
  _ProgressBridge(this.progress);

  final ProgressCallback? progress;
  Object? error;
  StackTrace? trace;

  int call(int Function(Pointer<NativeFunction<ProgressN>>, Pointer<Void>) body) {
    final progress = this.progress;
    if (progress == null) return body(nullptr, nullptr);
    final callable = NativeCallable<ProgressN>.isolateLocal(
      (int done, int total, Pointer<Void> user) {
        try {
          return progress(done, total) ? 1 : 0;
        } catch (e, s) {
          error = e;
          trace = s;
          return 0;
        }
      },
      exceptionalReturn: 0,
    );
    try {
      return body(callable.nativeFunction, nullptr);
    } finally {
      callable.close();
    }
  }

  void rethrowIfFailed() {
    final e = error;
    if (e != null) Error.throwWithStackTrace(e, trace!);
  }
}
