{ KeyNub License Dongle SDK - Delphi / Free Pascal binding.

  A thin translation of the C ABI (`include/licdongle.h`) - no protocol or
  crypto logic here. Link against the native keynub_licdongle shared library
  (keynub_licdongle.dll / libkeynub_licdongle.so / .dylib). Driverless on
  Windows, Linux, and macOS.

  Compiles under Delphi and under Free Pascal in Delphi mode. }
unit LicDongle;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$PACKRECORDS C}   // match the C compiler's struct layout exactly
{$ELSE}
  {$ALIGN 4}
{$ENDIF}
{$MINENUMSIZE 4}

interface

const
  {$IFDEF MSWINDOWS}
  LICD_LIB = 'keynub_licdongle.dll';
  {$ELSE}
    {$IFDEF DARWIN}
  LICD_LIB = 'libkeynub_licdongle.dylib';
    {$ELSE}
  LICD_LIB = 'libkeynub_licdongle.so';
    {$ENDIF}
  {$ENDIF}

  LICD_SERIAL_HEX_LEN = 18;

  // Status codes (licd_status). 0 = success; all errors are negative.
  LICD_OK                 = 0;
  LICD_E_INVALID_ARG      = -1;
  LICD_E_NO_DEVICE        = -2;
  LICD_E_ACCESS_DENIED    = -3;
  LICD_E_IO               = -4;
  LICD_E_TIMEOUT          = -5;
  LICD_E_PROTOCOL         = -6;
  LICD_E_NOT_GENUINE      = -7;
  LICD_E_CERT_INVALID     = -8;
  LICD_E_SESSION_EXPIRED  = -9;
  LICD_E_TAG_MISMATCH     = -10;
  LICD_E_RANGE            = -11;
  LICD_E_STORAGE_FULL     = -12;
  LICD_E_BUSY             = -13;
  LICD_E_NOT_FOUND        = -14;
  LICD_E_AUTH_REQUIRED    = -15;
  LICD_E_FW_INCOMPATIBLE  = -16;
  LICD_E_SDK_TOO_OLD      = -17;
  LICD_E_CANCELLED        = -18;
  LICD_E_NOT_IMPLEMENTED  = -19;
  LICD_E_INTERNAL         = -20;

  // App-data encryption scope (licd_scope).
  LICD_SCOPE_DEVICE    = 0;
  LICD_SCOPE_DEVELOPER = 1;

  // Log levels (licd_log_level).
  LICD_LOG_ERROR = 0;
  LICD_LOG_WARN  = 1;
  LICD_LOG_INFO  = 2;
  LICD_LOG_DEBUG = 3;

type
  // Opaque handles (C: licd_ctx* / licd_device*).
  TLicdCtx = Pointer;
  TLicdDevice = Pointer;

  // One discovered dongle (licd_device_info).
  PLicdDeviceInfo = ^TLicdDeviceInfo;
  TLicdDeviceInfo = record
    serial: array[0..18] of AnsiChar;  // NUL-terminated
    path: array[0..511] of AnsiChar;   // NUL-terminated platform path
    vendor_id: Word;
    product_id: Word;
  end;

  // Plaintext device info (licd_info).
  PLicdInfo = ^TLicdInfo;
  TLicdInfo = record
    proto_version_major: Byte;
    proto_version_minor: Byte;
    fw_version_major: Byte;
    fw_version_minor: Byte;
    fw_version_patch: Byte;
    se_ready: Integer;   // C int (nonzero = true)
    provisioned: Integer;
    data_capacity: LongWord;
    data_free: LongWord;
    // Nonzero if the PREVIOUS boot ended in a watchdog timeout (the firmware
    // hung and reset itself). Cleared by a power cycle.
    watchdog_reboot: Integer;
    // Nonzero if the dongle confirmed at boot that its USB and parsing code
    // is fenced off from keys and storage. The simulator reports zero.
    isolated: Integer;
  end;

  // Result of licd_verify_genuine (licd_genuine_result).
  PLicdGenuineResult = ^TLicdGenuineResult;
  TLicdGenuineResult = record
    genuine: Integer;
    serial: array[0..18] of AnsiChar;
    batch: array[0..63] of AnsiChar;
    provisioned_date: array[0..10] of AnsiChar;
  end;

  // Optional callbacks.
  TLicdLogCallback = procedure(level: Integer; msg: PAnsiChar; user: Pointer); cdecl;
  // Return nonzero to continue, zero to cancel the transfer.
  TLicdProgressCallback = function(done: LongWord; total: LongWord; user: Pointer): Integer; cdecl;

// ============================================================================
// Context / version
// ============================================================================

procedure licd_version(out major: Integer; out minor: Integer; out patch: Integer); cdecl;
  external LICD_LIB name 'licd_version';
function licd_init(out ctx: TLicdCtx): Integer; cdecl;
  external LICD_LIB name 'licd_init';
procedure licd_free(ctx: TLicdCtx); cdecl;
  external LICD_LIB name 'licd_free';
procedure licd_set_log_callback(ctx: TLicdCtx; cb: TLicdLogCallback; user: Pointer); cdecl;
  external LICD_LIB name 'licd_set_log_callback';
// Override the CA root that licd_verify_genuine checks against (DER X.509).
// Applications do not need this - a release build embeds the KeyNub production
// root; it is for vendor tooling verifying dongles from a different CA.
function licd_set_trust_root(ctx: TLicdCtx; der: PByte; len: NativeUInt): Integer; cdecl;
  external LICD_LIB name 'licd_set_trust_root';

// ============================================================================
// Enumeration / open / close
// ============================================================================

function licd_enumerate(ctx: TLicdCtx; out list: PLicdDeviceInfo; out count: NativeUInt): Integer; cdecl;
  external LICD_LIB name 'licd_enumerate';
procedure licd_free_device_list(list: PLicdDeviceInfo; count: NativeUInt); cdecl;
  external LICD_LIB name 'licd_free_device_list';
function licd_open(ctx: TLicdCtx; serial_or_nil: PAnsiChar; out dev: TLicdDevice): Integer; cdecl;
  external LICD_LIB name 'licd_open';
function licd_open_path(ctx: TLicdCtx; path: PAnsiChar; out dev: TLicdDevice): Integer; cdecl;
  external LICD_LIB name 'licd_open_path';
procedure licd_close(dev: TLicdDevice); cdecl;
  external LICD_LIB name 'licd_close';

// ============================================================================
// Info (plaintext, no session required)
// ============================================================================

function licd_get_info(dev: TLicdDevice; out info: TLicdInfo): Integer; cdecl;
  external LICD_LIB name 'licd_get_info';
// out_serial must hold >= LICD_SERIAL_HEX_LEN + 1 bytes.
function licd_get_serial(dev: TLicdDevice; out_serial: PAnsiChar; serial_size: NativeUInt): Integer; cdecl;
  external LICD_LIB name 'licd_get_serial';

// ============================================================================
// Authenticity + session
// ============================================================================

function licd_verify_genuine(dev: TLicdDevice; out result: TLicdGenuineResult): Integer; cdecl;
  external LICD_LIB name 'licd_verify_genuine';
function licd_session_open(dev: TLicdDevice): Integer; cdecl;
  external LICD_LIB name 'licd_session_open';
function licd_session_close(dev: TLicdDevice): Integer; cdecl;
  external LICD_LIB name 'licd_session_close';
// Elevate the session to the write role using the developer master key (DER).
function licd_write_auth(dev: TLicdDevice; master_key_der: PByte; len: NativeUInt): Integer; cdecl;
  external LICD_LIB name 'licd_write_auth';

// ============================================================================
// License data records (session required; write/erase need the write role)
// ============================================================================

function licd_record_list(dev: TLicdDevice; out names: PPAnsiChar; out sizes: PLongWord;
  out count: NativeUInt): Integer; cdecl;
  external LICD_LIB name 'licd_record_list';
procedure licd_free_record_list(names: PPAnsiChar; sizes: PLongWord; count: NativeUInt); cdecl;
  external LICD_LIB name 'licd_free_record_list';
function licd_record_read(dev: TLicdDevice; name: PAnsiChar; offset: LongWord; buf: Pointer;
  buf_size: LongWord; out out_len: LongWord; out out_total: LongWord;
  progress: TLicdProgressCallback; user: Pointer): Integer; cdecl;
  external LICD_LIB name 'licd_record_read';
function licd_record_write(dev: TLicdDevice; name: PAnsiChar; data: Pointer; len: LongWord;
  progress: TLicdProgressCallback; user: Pointer): Integer; cdecl;
  external LICD_LIB name 'licd_record_write';
// name = nil erases all records.
function licd_record_erase(dev: TLicdDevice; name: PAnsiChar): Integer; cdecl;
  external LICD_LIB name 'licd_record_erase';

// ============================================================================
// Monotonic counters (session required; increment needs the write role)
// ============================================================================

function licd_counter_read(dev: TLicdDevice; counter_id: Byte; out value: LongWord): Integer; cdecl;
  external LICD_LIB name 'licd_counter_read';
function licd_counter_increment(dev: TLicdDevice; counter_id: Byte; out value: LongWord): Integer; cdecl;
  external LICD_LIB name 'licd_counter_increment';

// ============================================================================
// App-data envelope encryption (session required; read role)
// ============================================================================

// Allocates out_buf (free with licd_free_buffer) and sets out_len.
function licd_app_encrypt(dev: TLicdDevice; scope: Integer; plaintext: Pointer; len: LongWord;
  out out_buf: PByte; out out_len: LongWord): Integer; cdecl;
  external LICD_LIB name 'licd_app_encrypt';
function licd_app_decrypt(dev: TLicdDevice; packed_data: Pointer; packed_len: LongWord;
  out out_buf: PByte; out out_len: LongWord): Integer; cdecl;
  external LICD_LIB name 'licd_app_decrypt';
procedure licd_free_buffer(buf: PByte); cdecl;
  external LICD_LIB name 'licd_free_buffer';

// ============================================================================
// Errors
// ============================================================================

function licd_strerror(status: Integer): PAnsiChar; cdecl;
  external LICD_LIB name 'licd_strerror';
function licd_error_detail(ctx: TLicdCtx): PAnsiChar; cdecl;
  external LICD_LIB name 'licd_error_detail';

implementation

end.
