// Tests against a stand-in for the C ABI: the SDK's
// bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory,
// compiled here with a C compiler from the path (cc, gcc, clang, or zig cc)
// and loaded through LicDongleLibrary.path. Every call of the package runs end
// to end without hardware. KEYNUB_LICDONGLE_LIBRARY naming an already compiled
// stand-in skips the build. Without any compiler the tests are skipped, and
// the reason is printed.

import 'dart:io';
import 'dart:typed_data';

import 'package:keynub_licdongle/keynub_licdongle.dart';
import 'package:test/test.dart';

const factoryKey = [0x30, 0x10, 0x01, 0x02, 0x03];
const replacementKey = [0x30, 0x11, 0x09, 0x08, 0x07, 0x06];
const serial = '04A1B2C3D4E5F6';

/// The repository root: `dart test` runs in the package directory
/// (bindings/dart), two levels below it. KEYNUB_SDK_ROOT overrides.
Directory repositoryRoot() {
  final env = Platform.environment['KEYNUB_SDK_ROOT'];
  if (env != null && env.isNotEmpty) return Directory(env);
  return Directory.current.absolute.parent.parent;
}

String? buildStub() {
  final root = repositoryRoot();
  final envSource = Platform.environment['KEYNUB_STUB_SOURCE'];
  final source = envSource != null && envSource.isNotEmpty
      ? File(envSource)
      : File('${root.path}/bindings/julia/test/stub/licd_stub.c');
  final include = ['include', 'core/include']
      .map((d) => Directory('${root.path}/$d'))
      .where((d) => File('${d.path}/licdongle.h').existsSync())
      .firstOrNull;
  if (!source.existsSync() || include == null) {
    print('no stand-in source (${source.path}) or header under ${root.path}');
    return null;
  }
  final dir = Directory.systemTemp.createTempSync('keynub-dart-');
  final ext = Platform.isWindows ? 'dll' : (Platform.isMacOS ? 'dylib' : 'so');
  final out = '${dir.path}${Platform.pathSeparator}licd_stub.$ext';
  final pic = Platform.isWindows ? <String>[] : ['-fPIC'];
  final attempts = <List<String>>[
    ['cc'],
    ['gcc'],
    ['clang'],
    ['zig', 'cc'],
  ];
  for (final compiler in attempts) {
    try {
      final r = Process.runSync(compiler.first, [
        ...compiler.skip(1),
        '-shared',
        ...pic,
        '-O1',
        '-DLICD_BUILD_SHARED',
        '-I${include.path}',
        '-o',
        out,
        source.path,
      ]);
      if (r.exitCode == 0 && File(out).existsSync()) return out;
      print('${compiler.join(' ')} failed: ${r.stderr}');
    } on ProcessException {
      // Not on the path; try the next one.
    }
  }
  print('no C compiler found for the stand-in');
  return null;
}

void main() {
  var lib = Platform.environment['KEYNUB_LICDONGLE_LIBRARY'] ?? '';
  if (lib.isEmpty) lib = buildStub() ?? '';
  if (lib.isEmpty) {
    print('keynub_licdongle: the ABI stand-in could not be compiled here, '
        'so the end-to-end tests did not run');
    return;
  }
  LicDongleLibrary.path = lib;

  Matcher failsWith(Status status) => throwsA(isA<LicenseDongleError>()
      .having((e) => e.status, 'status', status));

  void withDevice(void Function(Context ctx, Dongle dongle) body) {
    final ctx = Context();
    try {
      final dongle = ctx.open();
      try {
        body(ctx, dongle);
      } finally {
        dongle.close();
      }
    } finally {
      ctx.close();
    }
  }

  test('library and status codes', () {
    expect(LicDongleLibrary.resolvedPath, lib);
    expect(libraryVersion(), (major: 9, minor: 8, patch: 7));
    expect(LicDongleLibrary.loadedPath, lib);
    expect(Status.noDevice.message, 'no device');
    for (final s in Status.values) {
      expect(s.message, isNotEmpty);
    }
    final e = LicenseDongleError(-2, 'licd_op', 'the detail');
    expect(e.status, Status.noDevice);
    expect(e.toString(), 'licd_op: no device (the detail)');
    expect(LicenseDongleError(-4, 'licd_op', '').toString(), 'licd_op: I/O error');
    expect(Status.fromCode(-99), Status.internalError);
    expect(['win-x64', 'win-x86', 'win-arm64', 'linux-x64', 'linux-arm64', 'osx-x64', 'osx-arm64'],
        contains(LicDongleLibrary.platform));
    expect(() => LicDongleLibrary.path = 'other', throwsStateError);
  });

  test('enumerate and open', () {
    final ctx = Context();
    expect(ctx.isOpen, isTrue);
    final devices = ctx.enumerate();
    expect(devices, hasLength(1));
    expect(devices[0].serial, serial);
    expect(devices[0].path, 'stub:0');
    expect(devices[0].vendorId, 0x1234);
    expect(devices[0].productId, 0xABCD);

    try {
      ctx.open(serial: 'nope');
      fail('no error');
    } on LicenseDongleError catch (e) {
      expect(e.status, Status.noDevice);
      expect(e.operation, 'licd_open');
      expect(e.detail, 'no dongle with that serial');
    }
    expect(ctx.lastErrorDetail, 'no dongle with that serial');
    expect(() => ctx.openPath('stub:9'), failsWith(Status.noDevice));

    for (final dongle in [ctx.open(), ctx.open(serial: serial), ctx.openPath('stub:0')]) {
      expect(dongle.isOpen, isTrue);
      expect(dongle.serial(), serial);
      dongle.close();
      dongle.close();
      expect(dongle.isOpen, isFalse);
      expect(() => dongle.serial(), failsWith(Status.invalidArgument));
    }

    final dongle = ctx.open();
    ctx.close();
    expect(ctx.isOpen, isFalse);
    expect(dongle.isOpen, isFalse, reason: 'closing the context closes its dongles');
    expect(() => ctx.open(), failsWith(Status.invalidArgument));
    ctx.close();
  });

  test('info, serial and genuine', () {
    withDevice((_, dongle) {
      final info = dongle.info();
      expect(info.protocolVersion, (major: 1, minor: 0));
      expect(info.firmwareVersion, (major: 2, minor: 3, patch: 4));
      expect(info.secureElementReady && info.provisioned && info.isolated, isTrue);
      expect(info.dataCapacity, 1024 * 1024);
      expect(info.dataFree, 1000000);
      expect(info.watchdogReboot, isFalse);
      expect(info.writeAuthRotated, isFalse);

      final result = dongle.verifyGenuine();
      expect(result.genuine, isTrue);
      expect(result.serial, serial);
      expect(result.provisionedDate, '2026-08-15');
      expect(dongle.isGenuine, isTrue);
    });
  });

  test('the trust root is consulted', () {
    withDevice((ctx, dongle) {
      expect(() => ctx.setTrustRoot([]), failsWith(Status.invalidArgument));
      expect(() => ctx.setTrustRoot([0x02, 0x01, 0x00]), failsWith(Status.certificateInvalid));
      ctx.setTrustRoot([0x30, 0x82, 0x01, 0x00, ...List.filled(128, 0xAB)]);
      expect(() => dongle.verifyGenuine(), failsWith(Status.certificateInvalid));
      expect(dongle.isGenuine, isFalse, reason: 'isGenuine fails closed');
      ctx.setTrustRoot([0x30, 0x82, 0x01, 0x00, ...List.filled(128, 0x01)]);
      expect(dongle.isGenuine, isTrue);
    });
  });

  test('records, counters and app-crypto', () {
    withDevice((_, dongle) {
      dongle.withSession((s) {
        expect(s.isOpen, isTrue);
        final payload = Uint8List.fromList('license-blob-0123456789'.codeUnits);
        expect(() => s.writeRecord('lic', payload), failsWith(Status.authRequired));
        expect(() => s.authorizeWrite([0x30, 0x00]), failsWith(Status.notGenuine));
        expect(() => s.authorizeWrite([]), failsWith(Status.invalidArgument));
        s.authorizeWrite(factoryKey);
        s.writeRecord('lic', payload);
        expect(s.readRecord('lic'), payload);

        s.writeRecord('cfg', 'cfgdata');
        final records = s.records();
        expect(records.map((r) => r.name).toList()..sort(), ['cfg', 'lic']);
        expect(records.firstWhere((r) => r.name == 'lic').size, payload.length);
        expect(String.fromCharCodes(s.readRecord('cfg')), 'cfgdata');

        expect(() => s.readRecord('nope'), failsWith(Status.notFound));
        expect(() => s.eraseRecord('nope'), failsWith(Status.notFound));
        expect(() => s.eraseRecord(''), failsWith(Status.invalidArgument));
        expect(s.records(), hasLength(2));
        s.eraseRecord('cfg');
        expect(s.records().map((r) => r.name), ['lic']);

        s.writeRecord('empty', Uint8List(0));
        expect(s.readRecord('empty'), isEmpty);

        final before = s.readCounter(0);
        expect(s.incrementCounter(0), before + 1);
        expect(s.readCounter(0), before + 1);
        expect(s.readCounter(1), 0);
        expect(() => s.readCounter(7), failsWith(Status.range));
        expect(() => s.readCounter(-1), throwsArgumentError);

        final secret = Uint8List.fromList(List.generate(100, (i) => (i * 3 + 7) % 256));
        for (final scope in Scope.values) {
          final blob = s.appEncrypt(secret, scope);
          expect(blob.length, greaterThan(secret.length));
          expect(blob[0], scope.code);
          expect(s.appDecrypt(blob), secret);
          final tampered = Uint8List.fromList(blob);
          tampered[tampered.length - 1] ^= 0x01;
          expect(() => s.appDecrypt(tampered), failsWith(Status.tagMismatch));
        }
        expect(String.fromCharCodes(s.appDecrypt(s.appEncrypt('text', Scope.device))), 'text');
        expect(s.appDecrypt(s.appEncrypt(Uint8List(0), Scope.device)), isEmpty);

        s.eraseAllRecords();
        expect(s.records(), isEmpty);
      });
      expect(() => dongle.openSession().records(), returnsNormally);
    });
  });

  test('rotation replaces the key that elevates', () {
    withDevice((_, dongle) {
      dongle.withSession((s) {
        expect(() => s.rotateWriteKey(replacementKey), failsWith(Status.authRequired));
        s.authorizeWrite(factoryKey);
        expect(() => s.rotateWriteKey([]), failsWith(Status.invalidArgument));
        s.rotateWriteKey(replacementKey);
        s.writeRecord('lic', 'still-writable');
      });
      expect(dongle.info().writeAuthRotated, isTrue);
      dongle.withSession((s) {
        expect(() => s.authorizeWrite(factoryKey), failsWith(Status.notGenuine));
        s.authorizeWrite(replacementKey);
        s.writeRecord('lic', 'new-key-writes');
        expect(String.fromCharCodes(s.readRecord('lic')), 'new-key-writes');
      });
    });
  });

  test('progress and cancellation', () {
    withDevice((_, dongle) {
      dongle.withSession((s) {
        s.authorizeWrite(factoryKey);
        final blob = Uint8List.fromList(List.generate(2000, (i) => (i * 31 + 5) % 256));
        final writes = <(int, int)>[];
        s.writeRecord('big', blob, progress: (done, total) {
          writes.add((done, total));
          return true;
        });
        expect(writes.last, (2000, 2000));
        expect(() => s.writeRecord('big2', blob, progress: (_, __) => false),
            failsWith(Status.cancelled));

        final ticks = <(int, int)>[];
        final data = s.readRecord('big', progress: (done, total) {
          ticks.add((done, total));
          return true;
        });
        expect(data, blob);
        expect(ticks, hasLength(4));
        expect(ticks.last, (2000, 2000));
        expect(() => s.readRecord('big', progress: (_, __) => false), failsWith(Status.cancelled));
        expect(() => s.readRecord('big', progress: (_, __) => throw StateError('boom')),
            throwsStateError);
        expect(s.readRecord('big'), blob, reason: 'the dongle is usable afterwards');
      });
    });
  });

  test('closed session and dongle are refused', () {
    final ctx = Context();
    final dongle = ctx.open();
    final s = dongle.openSession();
    s.close();
    s.close();
    expect(s.isOpen, isFalse);
    expect(() => s.readRecord('lic'), failsWith(Status.sessionExpired));

    final second = dongle.openSession();
    dongle.close();
    expect(() => second.readRecord('lic'), failsWith(Status.invalidArgument));
    second.close();
    ctx.close();
    print('keynub_licdongle: every call passed against the ABI stand-in');
  });
}
