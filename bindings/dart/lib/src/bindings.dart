// The C ABI of the KeyNub library as dart:ffi sees it: the plain structures
// with the layout the C compiler gives them (Dart computes the padding from
// the field types), the function signatures, and the table that binds them
// from the loaded library by name.

import 'dart:ffi';

const int serialHexLen = 14;

final class LicdDeviceInfo extends Struct {
  @Array(serialHexLen + 1)
  external Array<Uint8> serial;
  @Array(512)
  external Array<Uint8> path;
  @Uint16()
  external int vendorId;
  @Uint16()
  external int productId;
}

final class LicdInfo extends Struct {
  @Uint8()
  external int protoVersionMajor;
  @Uint8()
  external int protoVersionMinor;
  @Uint8()
  external int fwVersionMajor;
  @Uint8()
  external int fwVersionMinor;
  @Uint8()
  external int fwVersionPatch;
  @Int32()
  external int seReady;
  @Int32()
  external int provisioned;
  @Uint32()
  external int dataCapacity;
  @Uint32()
  external int dataFree;
  @Int32()
  external int watchdogReboot;
  @Int32()
  external int isolated;
  @Int32()
  external int writeauthRotated;
}

final class LicdGenuineResult extends Struct {
  @Int32()
  external int genuine;
  @Array(serialHexLen + 1)
  external Array<Uint8> serial;
  @Array(11)
  external Array<Uint8> provisionedDate;
}

/// A NUL-terminated char array field as a Dart string.
String cString(Array<Uint8> field, int capacity) {
  final bytes = <int>[];
  for (var i = 0; i < capacity; i++) {
    final b = field[i];
    if (b == 0) break;
    bytes.add(b);
  }
  return String.fromCharCodes(bytes);
}

// Native signatures.
typedef VersionN = Void Function(
    Pointer<Int32>, Pointer<Int32>, Pointer<Int32>);
typedef InitN = Int32 Function(Pointer<Pointer<Void>>);
typedef FreeN = Void Function(Pointer<Void>);
typedef BytesN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef EnumerateN = Int32 Function(
    Pointer<Void>, Pointer<Pointer<LicdDeviceInfo>>, Pointer<Size>);
typedef FreeDeviceListN = Void Function(Pointer<LicdDeviceInfo>, Size);
typedef OpenN = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef GetInfoN = Int32 Function(Pointer<Void>, Pointer<LicdInfo>);
typedef GetSerialN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef VerifyGenuineN = Int32 Function(
    Pointer<Void>, Pointer<LicdGenuineResult>);
typedef DeviceN = Int32 Function(Pointer<Void>);
typedef RecordListN = Int32 Function(Pointer<Void>,
    Pointer<Pointer<Pointer<Uint8>>>, Pointer<Pointer<Uint32>>, Pointer<Size>);
typedef FreeRecordListN = Void Function(
    Pointer<Pointer<Uint8>>, Pointer<Uint32>, Size);
typedef ProgressN = Int32 Function(Uint32, Uint32, Pointer<Void>);
typedef RecordReadN = Int32 Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Uint32,
    Pointer<Uint8>,
    Uint32,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<NativeFunction<ProgressN>>,
    Pointer<Void>);
typedef RecordWriteN = Int32 Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Uint8>, Uint32, Pointer<NativeFunction<ProgressN>>, Pointer<Void>);
typedef RecordEraseN = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef CounterN = Int32 Function(Pointer<Void>, Uint8, Pointer<Uint32>);
typedef AppEncryptN = Int32 Function(Pointer<Void>, Int32, Pointer<Uint8>,
    Uint32, Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef AppDecryptN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32,
    Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef FreeBufferN = Void Function(Pointer<Uint8>);
typedef StrerrorN = Pointer<Uint8> Function(Int32);
typedef ErrorDetailN = Pointer<Uint8> Function(Pointer<Void>);

// Dart-side signatures.
typedef VersionD = void Function(
    Pointer<Int32>, Pointer<Int32>, Pointer<Int32>);
typedef InitD = int Function(Pointer<Pointer<Void>>);
typedef FreeD = void Function(Pointer<Void>);
typedef BytesD = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef EnumerateD = int Function(
    Pointer<Void>, Pointer<Pointer<LicdDeviceInfo>>, Pointer<Size>);
typedef FreeDeviceListD = void Function(Pointer<LicdDeviceInfo>, int);
typedef OpenD = int Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Pointer<Void>>);
typedef GetInfoD = int Function(Pointer<Void>, Pointer<LicdInfo>);
typedef GetSerialD = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef VerifyGenuineD = int Function(
    Pointer<Void>, Pointer<LicdGenuineResult>);
typedef DeviceD = int Function(Pointer<Void>);
typedef RecordListD = int Function(Pointer<Void>,
    Pointer<Pointer<Pointer<Uint8>>>, Pointer<Pointer<Uint32>>, Pointer<Size>);
typedef FreeRecordListD = void Function(
    Pointer<Pointer<Uint8>>, Pointer<Uint32>, int);
typedef RecordReadD = int Function(
    Pointer<Void>,
    Pointer<Uint8>,
    int,
    Pointer<Uint8>,
    int,
    Pointer<Uint32>,
    Pointer<Uint32>,
    Pointer<NativeFunction<ProgressN>>,
    Pointer<Void>);
typedef RecordWriteD = int Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Uint8>, int, Pointer<NativeFunction<ProgressN>>, Pointer<Void>);
typedef RecordEraseD = int Function(Pointer<Void>, Pointer<Uint8>);
typedef CounterD = int Function(Pointer<Void>, int, Pointer<Uint32>);
typedef AppEncryptD = int Function(Pointer<Void>, int, Pointer<Uint8>, int,
    Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef AppDecryptD = int Function(Pointer<Void>, Pointer<Uint8>, int,
    Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef FreeBufferD = void Function(Pointer<Uint8>);
typedef StrerrorD = Pointer<Uint8> Function(int);
typedef ErrorDetailD = Pointer<Uint8> Function(Pointer<Void>);

/// Every SDK function, bound from one loaded library.
final class Api {
  Api(DynamicLibrary lib)
      : version = lib.lookupFunction<VersionN, VersionD>('licd_version'),
        init = lib.lookupFunction<InitN, InitD>('licd_init'),
        free = lib.lookupFunction<FreeN, FreeD>('licd_free'),
        setTrustRoot =
            lib.lookupFunction<BytesN, BytesD>('licd_set_trust_root'),
        enumerate =
            lib.lookupFunction<EnumerateN, EnumerateD>('licd_enumerate'),
        freeDeviceList = lib.lookupFunction<FreeDeviceListN, FreeDeviceListD>(
            'licd_free_device_list'),
        open = lib.lookupFunction<OpenN, OpenD>('licd_open'),
        openPath = lib.lookupFunction<OpenN, OpenD>('licd_open_path'),
        close = lib.lookupFunction<FreeN, FreeD>('licd_close'),
        getInfo = lib.lookupFunction<GetInfoN, GetInfoD>('licd_get_info'),
        getSerial =
            lib.lookupFunction<GetSerialN, GetSerialD>('licd_get_serial'),
        verifyGenuine = lib.lookupFunction<VerifyGenuineN, VerifyGenuineD>(
            'licd_verify_genuine'),
        sessionOpen =
            lib.lookupFunction<DeviceN, DeviceD>('licd_session_open'),
        sessionClose =
            lib.lookupFunction<DeviceN, DeviceD>('licd_session_close'),
        writeAuth = lib.lookupFunction<BytesN, BytesD>('licd_write_auth'),
        writeAuthRotate =
            lib.lookupFunction<BytesN, BytesD>('licd_write_auth_rotate'),
        recordList =
            lib.lookupFunction<RecordListN, RecordListD>('licd_record_list'),
        freeRecordList = lib.lookupFunction<FreeRecordListN, FreeRecordListD>(
            'licd_free_record_list'),
        recordRead =
            lib.lookupFunction<RecordReadN, RecordReadD>('licd_record_read'),
        recordWrite =
            lib.lookupFunction<RecordWriteN, RecordWriteD>('licd_record_write'),
        recordErase =
            lib.lookupFunction<RecordEraseN, RecordEraseD>('licd_record_erase'),
        counterRead =
            lib.lookupFunction<CounterN, CounterD>('licd_counter_read'),
        counterIncrement =
            lib.lookupFunction<CounterN, CounterD>('licd_counter_increment'),
        appEncrypt =
            lib.lookupFunction<AppEncryptN, AppEncryptD>('licd_app_encrypt'),
        appDecrypt =
            lib.lookupFunction<AppDecryptN, AppDecryptD>('licd_app_decrypt'),
        freeBuffer =
            lib.lookupFunction<FreeBufferN, FreeBufferD>('licd_free_buffer'),
        strerror = lib.lookupFunction<StrerrorN, StrerrorD>('licd_strerror'),
        errorDetail =
            lib.lookupFunction<ErrorDetailN, ErrorDetailD>('licd_error_detail');

  final VersionD version;
  final InitD init;
  final FreeD free;
  final BytesD setTrustRoot;
  final EnumerateD enumerate;
  final FreeDeviceListD freeDeviceList;
  final OpenD open;
  final OpenD openPath;
  final FreeD close;
  final GetInfoD getInfo;
  final GetSerialD getSerial;
  final VerifyGenuineD verifyGenuine;
  final DeviceD sessionOpen;
  final DeviceD sessionClose;
  final BytesD writeAuth;
  final BytesD writeAuthRotate;
  final RecordListD recordList;
  final FreeRecordListD freeRecordList;
  final RecordReadD recordRead;
  final RecordWriteD recordWrite;
  final RecordEraseD recordErase;
  final CounterD counterRead;
  final CounterD counterIncrement;
  final AppEncryptD appEncrypt;
  final AppDecryptD appDecrypt;
  final FreeBufferD freeBuffer;
  final StrerrorD strerror;
  final ErrorDetailD errorDetail;
}
