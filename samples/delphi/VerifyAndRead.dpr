{ KeyNub SDK - Delphi/FPC sample: enumerate a dongle, verify authenticity, open an
  encrypted session, read a "license" record, and round-trip app-data encryption.
  Targets real hardware; prints guidance and exits 0 when no dongle is attached.

  Build (Delphi): dcc32 VerifyAndRead.dpr -U..\..\bindings\delphi
  Build (FPC):    fpc -Mdelphi -Fu..\..\bindings\delphi VerifyAndRead.dpr }
program VerifyAndRead;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  LicDongle;

function VersionString: string;
var
  maj, min, pat: Integer;
begin
  licd_version(maj, min, pat);
  Result := Format('%d.%d.%d', [maj, min, pat]);
end;

var
  ctx: TLicdCtx;
  dev: TLicdDevice;
  list: PLicdDeviceInfo;
  count: NativeUInt;
  info: TLicdInfo;
  genuine: TLicdGenuineResult;
  serialBuf: array[0..LICD_SERIAL_HEX_LEN] of AnsiChar;
  rc: Integer;
  secret: AnsiString;
  packedBuf, plainBuf: PByte;
  packedLen, plainLen: LongWord;
  outLen, total: LongWord;
  buf: array[0..511] of Byte;
begin
  WriteLn('KeyNub SDK ', VersionString);

  if licd_init(ctx) <> LICD_OK then
  begin
    WriteLn('licd_init failed');
    Halt(1);
  end;
  try
    if licd_enumerate(ctx, list, count) <> LICD_OK then
    begin
      WriteLn('enumerate failed');
      Halt(1);
    end;
    WriteLn('Dongles found: ', count);
    licd_free_device_list(list, count);
    if count = 0 then
    begin
      WriteLn('Connect a KeyNub dongle and re-run.');
      Halt(0);
    end;

    rc := licd_open(ctx, nil, dev);
    if rc <> LICD_OK then
    begin
      WriteLn('open: ', StrPas(licd_strerror(rc)));
      Halt(1);
    end;
    try
      if licd_get_info(dev, info) = LICD_OK then
        WriteLn(Format('protocol %d.%d, firmware %d.%d.%d, capacity %u bytes',
          [info.proto_version_major, info.proto_version_minor,
           info.fw_version_major, info.fw_version_minor, info.fw_version_patch,
           info.data_capacity]));

      if licd_get_serial(dev, @serialBuf[0], SizeOf(serialBuf)) = LICD_OK then
        WriteLn('serial ', StrPas(PAnsiChar(@serialBuf[0])));

      rc := licd_verify_genuine(dev, genuine);
      if rc <> LICD_OK then
      begin
        WriteLn('verify_genuine: ', StrPas(licd_strerror(rc)), ' (', StrPas(licd_error_detail(ctx)), ')');
        Halt(2);
      end;
      WriteLn('genuine: yes, cert serial ', StrPas(PAnsiChar(@genuine.serial[0])));

      if licd_session_open(dev) <> LICD_OK then
      begin
        WriteLn('session_open failed');
        Halt(3);
      end;

      rc := licd_record_read(dev, 'license', 0, @buf[0], SizeOf(buf), outLen, total, nil, nil);
      if rc = LICD_OK then
        WriteLn('license record: ', total, ' bytes')
      else if rc = LICD_E_NOT_FOUND then
        WriteLn('no ''license'' record on this dongle')
      else
        WriteLn('record_read: ', StrPas(licd_strerror(rc)));

      // App-data envelope encryption: the blob only decrypts with this dongle.
      secret := 'hello-keynub';
      if licd_app_encrypt(dev, LICD_SCOPE_DEVICE, PAnsiChar(secret), Length(secret),
                          packedBuf, packedLen) = LICD_OK then
      begin
        if (licd_app_decrypt(dev, packedBuf, packedLen, plainBuf, plainLen) = LICD_OK)
           and (plainLen = LongWord(Length(secret))) then
          WriteLn(Format('app-crypto round-trip OK (%d plaintext -> %u packed bytes)',
            [Length(secret), packedLen]))
        else
          WriteLn('app-crypto round-trip FAILED');
        licd_free_buffer(packedBuf);
        licd_free_buffer(plainBuf);
      end;

      licd_session_close(dev);
    finally
      licd_close(dev);
    end;
  finally
    licd_free(ctx);
  end;
end.
