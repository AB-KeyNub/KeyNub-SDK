{ KeyNub SDK - Delphi/FPC sample: take ownership of a new dongle.

  A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
  that from the next session onward only your key can write records, erase them or
  increment counters. Run it once per dongle, when it arrives.

  Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
    openssl ecparam -name prime256v1 -genkey -noout |
      openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der

  Build (Delphi): dcc32 RotateWriteKey.dpr -U..\..\bindings\delphi
  Build (FPC):    fpc -Mdelphi -Fu..\..\bindings\delphi RotateWriteKey.dpr
  Run:            RotateWriteKey ../../keys/keynub-shipping-writeauth.key.der my-key.der

  Targets real hardware; prints guidance and exits 0 when no dongle is attached.

  The replacement key is worth what your licence-signing key is worth. It cannot be
  recovered from the dongle, and a unit rotated to a key you have lost has to come
  back to be re-provisioned. }
program RotateWriteKey;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}SysUtils, Classes{$ELSE}System.SysUtils, System.Classes{$ENDIF},
  LicDongle;

{ The DER file as a byte array, which is what licd_write_auth takes. }
function ReadKey(const path: string): TBytes;
var
  stream: TFileStream;
begin
  Result := nil;
  stream := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, stream.Size);
    if stream.Size > 0 then
      stream.ReadBuffer(Result[0], stream.Size);
  finally
    stream.Free;
  end;
  if Length(Result) = 0 then
    raise Exception.CreateFmt('%s is empty', [path]);
end;

var
  ctx: TLicdCtx;
  dev: TLicdDevice;
  list: PLicdDeviceInfo;
  count: NativeUInt;
  serialBuf: array[0..LICD_SERIAL_HEX_LEN] of AnsiChar;
  current, replacement: TBytes;
  rc: Integer;
begin
  if ParamCount <> 2 then
  begin
    WriteLn('usage: RotateWriteKey <current-key.der> <new-key.der>');
    Halt(2);
  end;

  try
    current := ReadKey(ParamStr(1));
    replacement := ReadKey(ParamStr(2));
  except
    on E: Exception do
    begin
      WriteLn(E.Message);
      Halt(2);
    end;
  end;

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
      if licd_get_serial(dev, @serialBuf[0], SizeOf(serialBuf)) = LICD_OK then
        WriteLn('dongle ', StrPas(PAnsiChar(@serialBuf[0])));

      if licd_session_open(dev) <> LICD_OK then
      begin
        WriteLn('session_open failed');
        Halt(1);
      end;
      rc := licd_write_auth(dev, @current[0], Length(current));
      if rc <> LICD_OK then
      begin
        WriteLn('write_auth: ', StrPas(licd_strerror(rc)));
        Halt(1);
      end;
      rc := licd_write_auth_rotate(dev, @replacement[0], Length(replacement));
      if rc <> LICD_OK then
      begin
        WriteLn('write_auth_rotate: ', StrPas(licd_strerror(rc)),
                ' (', StrPas(licd_error_detail(ctx)), ')');
        Halt(1);
      end;
      WriteLn('rotated: this dongle now answers only to your key');
      licd_session_close(dev);

      { A fresh session is the only place the change is observable: the session
        above keeps the role it was already granted. }
      if licd_session_open(dev) <> LICD_OK then
      begin
        WriteLn('re-opening the session failed');
        Halt(1);
      end;
      if licd_write_auth(dev, @current[0], Length(current)) = LICD_OK then
      begin
        WriteLn('WARNING: the old key still works -- do not ship this unit');
        Halt(1);
      end;
      WriteLn('confirmed: the old key no longer elevates');
      rc := licd_write_auth(dev, @replacement[0], Length(replacement));
      if rc <> LICD_OK then
      begin
        WriteLn('the new key does not elevate: ', StrPas(licd_strerror(rc)));
        Halt(1);
      end;
      WriteLn('confirmed: your key elevates');
      licd_session_close(dev);

      WriteLn;
      WriteLn('Keep the replacement key safe. Every future write to this dongle needs it.');
    finally
      licd_close(dev);
    end;
  finally
    licd_free(ctx);
  end;
end.
