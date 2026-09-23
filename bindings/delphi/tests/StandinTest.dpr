// Every call of the Delphi / Free Pascal unit (LicDongle.pas) against a stand-in
// for the C ABI: bindings/julia/test/stub/licd_stub.c, one imaginary dongle held
// in memory, compiled into a shared library under the real library's file name
// in a folder of its own, next to this program. The record layouts are checked
// against the sizes the C compiler reports. Exit code 0 when every check passed.
//
// Windows (from the repository root, with a C compiler and fpc on the PATH):
//
//     mkdir standin
//     cc -shared -DLICD_BUILD_SHARED -Iinclude bindings/julia/test/stub/licd_stub.c -o standin/keynub_licdongle.dll
//     fpc -Mdelphi -Fubindings/delphi -FUstandin -ostandin/StandinTest.exe bindings/delphi/tests/StandinTest.dpr
//     standin\StandinTest.exe
//
// Linux: the library is standin/libkeynub_licdongle.so (add -fPIC), fpc gets
// -Flstandin, and the program runs with LD_LIBRARY_PATH=standin.
program StandinTest;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, LicDongle;

procedure licd_stub_sizes(out info: Integer; out device_info: Integer; out genuine_result: Integer); cdecl;
  external LICD_LIB name 'licd_stub_sizes';

const
  SERIAL = '04A1B2C3D4E5F6';
  FACTORY_KEY: array[0..4] of Byte = ($30, $10, $01, $02, $03);
  REPLACEMENT_KEY: array[0..5] of Byte = ($30, $11, $09, $08, $07, $06);

var
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  if not Condition then
  begin
    Inc(Failures);
    WriteLn('  FAIL  ', What);
  end;
end;

procedure Expect(Got, Status: Integer; const What: string);
begin
  if Got <> Status then
  begin
    Inc(Failures);
    WriteLn('  FAIL  ', What, ': ', Got, ', expected ', Status);
  end;
end;

function ReadRecord(Dev: TLicdDevice; const Name: AnsiString; out Data: AnsiString): Integer;
var
  Buf: array[0..4095] of Byte;
  Len, Total: LongWord;
begin
  Data := '';
  Result := licd_record_read(Dev, PAnsiChar(Name), 0, @Buf[0], SizeOf(Buf), Len, Total, nil, nil);
  if Result = LICD_OK then
    SetString(Data, PAnsiChar(@Buf[0]), Len);
end;

function WriteRecord(Dev: TLicdDevice; const Name, Data: AnsiString): Integer;
begin
  Result := licd_record_write(Dev, PAnsiChar(Name), PAnsiChar(Data), Length(Data), nil, nil);
end;

var
  Major, Minor, Patch: Integer;
  InfoSize, DeviceInfoSize, GenuineSize: Integer;
  Ctx: TLicdCtx;
  Dev: TLicdDevice;
  List: PLicdDeviceInfo;
  Count: NativeUInt;
  Info: TLicdInfo;
  Genuine: TLicdGenuineResult;
  SerialBuf: array[0..14] of AnsiChar;
  Root: array[0..131] of Byte;
  BadRoot: array[0..2] of Byte;
  BadKey: array[0..1] of Byte;
  Names: PPAnsiChar;
  Sizes: PLongWord;
  Data: AnsiString;
  Before, Value: LongWord;
  Secret: array[0..99] of Byte;
  Blob, Plain: PByte;
  BlobLen, PlainLen: LongWord;
  Scope, K: Integer;
  SawLic, SawCfg: Boolean;
  P: PPAnsiChar;
  S: PLongWord;
begin
  licd_stub_sizes(InfoSize, DeviceInfoSize, GenuineSize);
  Check(SizeOf(TLicdInfo) = InfoSize, Format('TLicdInfo layout (%d, C %d)', [SizeOf(TLicdInfo), InfoSize]));
  Check(SizeOf(TLicdDeviceInfo) = DeviceInfoSize,
        Format('TLicdDeviceInfo layout (%d, C %d)', [SizeOf(TLicdDeviceInfo), DeviceInfoSize]));
  Check(SizeOf(TLicdGenuineResult) = GenuineSize,
        Format('TLicdGenuineResult layout (%d, C %d)', [SizeOf(TLicdGenuineResult), GenuineSize]));

  licd_version(Major, Minor, Patch);
  Check((Major = 9) and (Minor = 8) and (Patch = 7), 'library version');
  Check(StrPas(licd_strerror(LICD_E_NO_DEVICE)) = 'no device', 'status text');

  Expect(licd_init(Ctx), LICD_OK, 'licd_init');
  Expect(licd_enumerate(Ctx, List, Count), LICD_OK, 'licd_enumerate');
  Check((Count = 1) and (StrPas(List^.serial) = SERIAL) and (StrPas(List^.path) = 'stub:0'), 'devices');
  licd_free_device_list(List, Count);
  Expect(licd_open(Ctx, 'nope', Dev), LICD_E_NO_DEVICE, 'open by unknown serial');
  Expect(licd_open_path(Ctx, 'stub:9', Dev), LICD_E_NO_DEVICE, 'open by unknown path');

  Expect(licd_open(Ctx, nil, Dev), LICD_OK, 'licd_open');
  Expect(licd_get_serial(Dev, @SerialBuf[0], SizeOf(SerialBuf)), LICD_OK, 'licd_get_serial');
  Check(StrPas(PAnsiChar(@SerialBuf[0])) = SERIAL, 'serial');
  Expect(licd_get_info(Dev, Info), LICD_OK, 'licd_get_info');
  Check((Info.proto_version_major = 1) and (Info.proto_version_minor = 0), 'protocol version');
  Check((Info.fw_version_major = 2) and (Info.fw_version_minor = 3) and (Info.fw_version_patch = 4),
        'firmware version');
  Check((Info.se_ready <> 0) and (Info.provisioned <> 0) and (Info.isolated <> 0), 'flags set');
  Check((Info.watchdog_reboot = 0) and (Info.writeauth_rotated = 0), 'flags clear');
  Check((Info.data_capacity = 1024 * 1024) and (Info.data_free = 1000000), 'capacity');
  Expect(licd_verify_genuine(Dev, Genuine), LICD_OK, 'licd_verify_genuine');
  Check((Genuine.genuine = 1) and (StrPas(Genuine.serial) = SERIAL) and
        (StrPas(Genuine.provisioned_date) = '2026-08-15'), 'genuine');

  BadRoot[0] := $02; BadRoot[1] := $01; BadRoot[2] := $00;
  Expect(licd_set_trust_root(Ctx, @BadRoot[0], SizeOf(BadRoot)), LICD_E_CERT_INVALID, 'malformed trust root');
  FillChar(Root, SizeOf(Root), $AB);
  Root[0] := $30; Root[1] := $82; Root[2] := $01; Root[3] := $00;
  Expect(licd_set_trust_root(Ctx, @Root[0], SizeOf(Root)), LICD_OK, 'foreign trust root');
  Expect(licd_verify_genuine(Dev, Genuine), LICD_E_CERT_INVALID, 'verify against a foreign root');
  FillChar(Root[4], SizeOf(Root) - 4, $01);
  Expect(licd_set_trust_root(Ctx, @Root[0], SizeOf(Root)), LICD_OK, 'right trust root');
  Expect(licd_verify_genuine(Dev, Genuine), LICD_OK, 'verify after the right root');

  Expect(licd_record_list(Dev, Names, Sizes, Count), LICD_E_SESSION_EXPIRED, 'records without a session');
  Expect(licd_session_open(Dev), LICD_OK, 'licd_session_open');
  Expect(WriteRecord(Dev, 'lic', 'license-blob-0123456789'), LICD_E_AUTH_REQUIRED, 'write before the write role');
  BadKey[0] := $30; BadKey[1] := $00;
  Expect(licd_write_auth(Dev, @BadKey[0], SizeOf(BadKey)), LICD_E_NOT_GENUINE, 'write role with a bad key');
  Expect(licd_write_auth(Dev, @FACTORY_KEY[0], SizeOf(FACTORY_KEY)), LICD_OK, 'licd_write_auth');
  Expect(WriteRecord(Dev, 'lic', 'license-blob-0123456789'), LICD_OK, 'licd_record_write');
  Expect(ReadRecord(Dev, 'lic', Data), LICD_OK, 'licd_record_read');
  Check(Data = 'license-blob-0123456789', 'read back');
  Expect(WriteRecord(Dev, 'cfg', 'cfgdata'), LICD_OK, 'second record');
  Expect(licd_record_list(Dev, Names, Sizes, Count), LICD_OK, 'licd_record_list');
  Check(Count = 2, 'two records');
  SawLic := False;
  SawCfg := False;
  P := Names;
  S := Sizes;
  for K := 1 to Integer(Count) do
  begin
    if (StrPas(P^) = 'lic') and (S^ = 23) then SawLic := True;
    if (StrPas(P^) = 'cfg') and (S^ = 7) then SawCfg := True;
    Inc(P);
    Inc(S);
  end;
  Check(SawLic and SawCfg, 'record names and sizes');
  licd_free_record_list(Names, Sizes, Count);
  Expect(ReadRecord(Dev, 'nope', Data), LICD_E_NOT_FOUND, 'read a missing record');
  Check(StrPas(licd_error_detail(Ctx)) = 'no such record', 'error detail');
  Expect(licd_record_erase(Dev, 'cfg'), LICD_OK, 'licd_record_erase');
  Expect(WriteRecord(Dev, 'empty', ''), LICD_OK, 'empty record');
  Expect(ReadRecord(Dev, 'empty', Data), LICD_OK, 'read the empty record');
  Check(Data = '', 'empty record length');

  Expect(licd_counter_read(Dev, 0, Before), LICD_OK, 'licd_counter_read');
  Expect(licd_counter_increment(Dev, 0, Value), LICD_OK, 'licd_counter_increment');
  Check(Value = Before + 1, 'increment');
  Expect(licd_counter_read(Dev, 1, Value), LICD_OK, 'second counter');
  Check(Value = 0, 'counters');
  Expect(licd_counter_read(Dev, 7, Value), LICD_E_RANGE, 'counter out of range');

  for K := 0 to 99 do
    Secret[K] := Byte((3 * K + 7) mod 256);
  for Scope := LICD_SCOPE_DEVICE to LICD_SCOPE_DEVELOPER do
  begin
    Expect(licd_app_encrypt(Dev, Scope, @Secret[0], SizeOf(Secret), Blob, BlobLen), LICD_OK, 'licd_app_encrypt');
    Check((BlobLen > SizeOf(Secret)) and (Blob^ = Scope), 'sealed data and scope byte');
    Expect(licd_app_decrypt(Dev, Blob, BlobLen, Plain, PlainLen), LICD_OK, 'licd_app_decrypt');
    Check((PlainLen = SizeOf(Secret)) and CompareMem(Plain, @Secret[0], SizeOf(Secret)), 'round trip');
    licd_free_buffer(Plain);
    PByte(NativeUInt(Blob) + BlobLen - 1)^ := PByte(NativeUInt(Blob) + BlobLen - 1)^ xor 1;
    Expect(licd_app_decrypt(Dev, Blob, BlobLen, Plain, PlainLen), LICD_E_TAG_MISMATCH, 'tampered blob');
    licd_free_buffer(Blob);
  end;

  // A nil name erases every record.
  Expect(licd_record_erase(Dev, nil), LICD_OK, 'erase all');
  Expect(licd_record_list(Dev, Names, Sizes, Count), LICD_OK, 'licd_record_list');
  Check(Count = 0, 'no records left');
  licd_free_record_list(Names, Sizes, Count);

  Expect(licd_write_auth_rotate(Dev, @REPLACEMENT_KEY[0], SizeOf(REPLACEMENT_KEY)), LICD_OK, 'licd_write_auth_rotate');
  Expect(WriteRecord(Dev, 'lic', 'still-writable'), LICD_OK, 'still writable');
  Expect(licd_session_close(Dev), LICD_OK, 'licd_session_close');
  Expect(licd_get_info(Dev, Info), LICD_OK, 'licd_get_info');
  Check(Info.writeauth_rotated <> 0, 'rotated flag');
  Expect(licd_session_open(Dev), LICD_OK, 'second session');
  Expect(licd_write_auth(Dev, @FACTORY_KEY[0], SizeOf(FACTORY_KEY)), LICD_E_NOT_GENUINE, 'factory key after rotation');
  Expect(licd_write_auth(Dev, @REPLACEMENT_KEY[0], SizeOf(REPLACEMENT_KEY)), LICD_OK, 'new key');
  Expect(WriteRecord(Dev, 'lic', 'new-key-writes'), LICD_OK, 'write with the new key');
  Expect(ReadRecord(Dev, 'lic', Data), LICD_OK, 'read with the new key');
  Check(Data = 'new-key-writes', 'new key content');
  Expect(licd_session_close(Dev), LICD_OK, 'licd_session_close');

  licd_close(Dev);
  licd_free(Ctx);

  if Failures > 0 then
  begin
    WriteLn(Failures, ' check(s) failed');
    Halt(1);
  end;
  WriteLn('LicDongle.pas: every call passed against the ABI stand-in');
end.
