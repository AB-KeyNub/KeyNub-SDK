--- KeyNub License Dongle — Lua binding (LuaJIT).
--
--   local keynub = require('keynub_licdongle')
--
--   local ctx = keynub.Context()
--   local dongle = ctx:open()                 -- first dongle, or ctx:open(serial)
--   dongle:verifyGenuine()                    -- errors unless genuine
--   local session = dongle:openSession()
--   local data = session:appDecrypt(blob)     -- <- build the licence check here
--   session:close(); dongle:close(); ctx:close()
--
-- Requires **LuaJIT**, whose `ffi` module is what makes this a single file with no
-- C extension to compile. Plain Lua 5.x has no FFI; there it would need a
-- compiled module, which defeats the point.
--
-- Lua matters here because it is so often the *embedded* language: a CAD package,
-- a simulator, a plugin host. That is also where the licence check belongs — see
-- docs/integration-security.md. `if not licensed then os.exit() end` is one
-- line of a script the customer can read and edit. Put something the program
-- needs through appEncrypt/appDecrypt instead.
--
-- Set KEYNUB_LICDONGLE_LIBRARY to point at a specific library.

local ffi = require('ffi')

-- The subset of licdongle.h this binding calls, as C. LuaJIT parses real
-- declarations, so this is the header's own text rather than a translation.
ffi.cdef[[
typedef struct licd_ctx licd_ctx;
typedef struct licd_device licd_device;

typedef struct {
    char serial[15];
    char path[512];
    uint16_t vendor_id;
    uint16_t product_id;
} licd_device_info;

typedef struct {
    uint8_t proto_version_major;
    uint8_t proto_version_minor;
    uint8_t fw_version_major;
    uint8_t fw_version_minor;
    uint8_t fw_version_patch;
    int se_ready;
    int provisioned;
    uint32_t data_capacity;
    uint32_t data_free;
    int watchdog_reboot;
    int isolated;
    int writeauth_rotated;
} licd_info;

typedef struct {
    int genuine;
    char serial[15];
    char provisioned_date[11];
} licd_genuine_result;

typedef int (*licd_progress_cb)(uint32_t done, uint32_t total, void *user);

void licd_version(int *major, int *minor, int *patch);
int licd_init(licd_ctx **out_ctx);
void licd_free(licd_ctx *ctx);
int licd_set_trust_root(licd_ctx *ctx, const uint8_t *der, size_t len);

int licd_enumerate(licd_ctx *ctx, licd_device_info **out_list, size_t *out_count);
void licd_free_device_list(licd_device_info *list, size_t count);
int licd_open(licd_ctx *ctx, const char *serial_or_null, licd_device **out_dev);
int licd_open_path(licd_ctx *ctx, const char *path, licd_device **out_dev);
void licd_close(licd_device *dev);

int licd_get_info(licd_device *dev, licd_info *out_info);
int licd_get_serial(licd_device *dev, char *out_serial, size_t serial_size);

int licd_verify_genuine(licd_device *dev, licd_genuine_result *out_result);
int licd_session_open(licd_device *dev);
int licd_session_close(licd_device *dev);
int licd_write_auth(licd_device *dev, const uint8_t *master_key_der, size_t len);
int licd_write_auth_rotate(licd_device *dev, const uint8_t *new_key_der, size_t len);

int licd_record_list(licd_device *dev, char ***out_names, uint32_t **out_sizes,
                     size_t *out_count);
void licd_free_record_list(char **names, uint32_t *sizes, size_t count);
int licd_record_read(licd_device *dev, const char *name, uint32_t offset,
                     void *buf, uint32_t buf_size, uint32_t *out_len,
                     uint32_t *out_total, licd_progress_cb progress, void *user);
int licd_record_write(licd_device *dev, const char *name, const void *data,
                      uint32_t len, licd_progress_cb progress, void *user);
int licd_record_erase(licd_device *dev, const char *name);

int licd_counter_read(licd_device *dev, uint8_t counter_id, uint32_t *out_value);
int licd_counter_increment(licd_device *dev, uint8_t counter_id, uint32_t *out_value);

int licd_app_encrypt(licd_device *dev, int scope, const void *plaintext,
                     uint32_t len, uint8_t **out, uint32_t *out_len);
int licd_app_decrypt(licd_device *dev, const void *packed, uint32_t packed_len,
                     uint8_t **out, uint32_t *out_len);
void licd_free_buffer(uint8_t *buf);

const char *licd_strerror(int status);
const char *licd_error_detail(licd_ctx *ctx);
]]

local M = {}

--- Native status codes (mirrors licd_status). OK is 0; errors are negative.
M.Status = {
  OK = 0,
  INVALID_ARGUMENT = -1,
  NO_DEVICE = -2,
  ACCESS_DENIED = -3,
  IO = -4,
  TIMEOUT = -5,
  PROTOCOL = -6,
  NOT_GENUINE = -7,
  CERTIFICATE_INVALID = -8,
  SESSION_EXPIRED = -9,
  TAG_MISMATCH = -10,
  RANGE = -11,
  STORAGE_FULL = -12,
  BUSY = -13,
  NOT_FOUND = -14,
  AUTH_REQUIRED = -15,
  FIRMWARE_INCOMPATIBLE = -16,
  SDK_TOO_OLD = -17,
  CANCELLED = -18,
  NOT_IMPLEMENTED = -19,
  INTERNAL = -20,
}

--- Who can decrypt data produced by Session:appEncrypt.
M.Scope = {
  DEVICE = 0,    -- only this one physical dongle
  DEVELOPER = 1, -- any dongle issued by the same developer
}

-- --- library discovery ------------------------------------------------------

local function defaultName()
  if ffi.os == 'Windows' then
    return 'keynub_licdongle.dll'
  elseif ffi.os == 'OSX' then
    return 'libkeynub_licdongle.dylib'
  end
  return 'libkeynub_licdongle.so'
end

-- The natives/<rid> directory a checkout of the SDK carries, if this file is
-- being required from one. Nothing to set: the path is derived from this file.
local function repoNative()
  local source = debug.getinfo(1, 'S').source
  local dir = source and source:match('^@(.*)[/\\][^/\\]*$')
  if not dir then
    return nil
  end
  local os_name = ffi.os == 'Windows' and 'win' or (ffi.os == 'OSX' and 'osx' or 'linux')
  local arch = ({ x64 = 'x64', x86 = 'x86', arm64 = 'arm64' })[ffi.arch]
  if not arch then
    return nil
  end
  return dir .. '/../../natives/' .. os_name .. '-' .. arch .. '/' .. defaultName()
end

local function loadLibrary()
  local override = os.getenv('KEYNUB_LICDONGLE_LIBRARY')
  local candidates = override and override ~= '' and { override }
      or { repoNative(), defaultName() }
  local errors = {}
  for _, path in ipairs(candidates) do
    local ok, lib = pcall(ffi.load, path)
    if ok then
      return lib
    end
    errors[#errors + 1] = path .. ': ' .. tostring(lib)
  end
  error('could not load the keynub_licdongle native library; tried:\n  '
        .. table.concat(errors, '\n  '), 2)
end

local lib = loadLibrary()
M.lib = lib

-- --- errors -----------------------------------------------------------------

--- The error table raised on failure: { status, operation, message, detail }.
-- A table rather than a string so `if err.status == keynub.Status.NO_DEVICE` works;
-- __tostring keeps it readable when it reaches a log unhandled.
local Error = {}
Error.__index = Error
Error.__tostring = function(self)
  local text = self.operation .. ': ' .. self.message
  if self.detail ~= '' then
    text = text .. ' (' .. self.detail .. ')'
  end
  return text
end
M.Error = Error

local function statusText(status)
  local raw = lib.licd_strerror(status)
  return raw ~= nil and ffi.string(raw) or 'unknown error'
end

local function fail(status, operation, detail)
  error(setmetatable({
    status = status,
    operation = operation,
    message = statusText(status),
    detail = detail or '',
  }, Error), 3)
end

-- --- helpers ----------------------------------------------------------------

local function fixedString(array)
  return ffi.string(array)
end

--- A C byte buffer holding the bytes of s. A string initializer copies the
--- string and a terminating zero, so the buffer has one byte more than s.
local function byteBuffer(s)
  return ffi.new('uint8_t[?]', #s + 1, s)
end

--- Copies a library-allocated buffer into a Lua string and frees the original.
local function takeBuffer(outPointer, length)
  if outPointer[0] == nil then
    return ''
  end
  local ok, result = pcall(function()
    return length > 0 and ffi.string(outPointer[0], length) or ''
  end)
  lib.licd_free_buffer(outPointer[0])
  if not ok then
    error(result, 0)
  end
  return result
end

-- --- Context ----------------------------------------------------------------

local Context = {}
Context.__index = Context
M.Context = setmetatable({}, { __call = function() return Context.new() end })

--- The native core's version, as major, minor, patch.
function M.libraryVersion()
  local parts = ffi.new('int[3]')
  lib.licd_version(parts, parts + 1, parts + 2)
  return parts[0], parts[1], parts[2]
end

function Context.new()
  local out = ffi.new('licd_ctx*[1]')
  local rc = lib.licd_init(out)
  if rc ~= M.Status.OK then
    fail(rc, 'licd_init')
  end
  return setmetatable({ handle = out[0] }, Context)
end

function Context:isOpen()
  return self.handle ~= nil
end

function Context:close()
  if self.handle ~= nil then
    local handle = self.handle
    self.handle = nil
    lib.licd_free(handle)
  end
end

function Context:checkedHandle()
  if self.handle == nil then
    fail(M.Status.INVALID_ARGUMENT, 'context', 'the context has been closed')
  end
  return self.handle
end

--- The SDK's diagnostic detail for the most recent failure on this thread.
function Context:lastErrorDetail()
  local raw = lib.licd_error_detail(self:checkedHandle())
  return raw ~= nil and ffi.string(raw) or ''
end

function Context:check(rc, operation)
  if rc ~= M.Status.OK then
    fail(rc, operation, self.handle ~= nil and self:lastErrorDetail() or '')
  end
end

--- Overrides the CA root that verifyGenuine checks against. Applications do not
--- need this: a release build embeds the KeyNub production root. It exists for
--- dongles provisioned against a different CA, and for vendor tooling.
function Context:setTrustRoot(der)
  local buffer = byteBuffer(der)
  self:check(lib.licd_set_trust_root(self:checkedHandle(),
                                     #der > 0 and buffer or nil, #der),
             'licd_set_trust_root')
end

--- Connected dongles. An empty table means none are attached, which is normal.
function Context:enumerate()
  local list = ffi.new('licd_device_info*[1]')
  local count = ffi.new('size_t[1]')
  self:check(lib.licd_enumerate(self:checkedHandle(), list, count), 'licd_enumerate')
  local out = {}
  if list[0] ~= nil then
    for i = 0, tonumber(count[0]) - 1 do
      local entry = list[0][i]
      out[#out + 1] = {
        serial = fixedString(entry.serial),
        path = fixedString(entry.path),
        vendorId = entry.vendor_id,
        productId = entry.product_id,
      }
    end
    lib.licd_free_device_list(list[0], count[0])
  end
  return out
end

--- Opens the dongle with this serial, or the first one found.
function Context:open(serial)
  local out = ffi.new('licd_device*[1]')
  self:check(lib.licd_open(self:checkedHandle(), serial, out), 'licd_open')
  return M.Dongle(self, out[0])
end

--- Opens a specific dongle by the path from enumerate.
function Context:openPath(path)
  local out = ffi.new('licd_device*[1]')
  self:check(lib.licd_open_path(self:checkedHandle(), path, out), 'licd_open_path')
  return M.Dongle(self, out[0])
end

--- Adopts a device opened through the C ABI directly, so this binding can be
--- introduced into existing ffi code a call at a time.
function Context:adopt(handle)
  return M.Dongle(self, handle)
end

-- --- Dongle -----------------------------------------------------------------

local Dongle = {}
Dongle.__index = Dongle
M.Dongle = function(context, handle)
  return setmetatable({ context = context, handle = handle }, Dongle)
end

function Dongle:isOpen()
  return self.handle ~= nil
end

function Dongle:close()
  if self.handle ~= nil then
    local handle = self.handle
    self.handle = nil
    lib.licd_close(handle)
  end
end

function Dongle:checkedHandle()
  if self.handle == nil then
    fail(M.Status.INVALID_ARGUMENT, 'dongle', 'the dongle has been closed')
  end
  return self.handle
end

--- Plaintext device info.
---
--- `watchdogReboot` means the dongle's *previous* boot ended in a watchdog
--- timeout: the firmware hung and reset itself. It is the only trace a field hang
--- leaves behind, and a power cycle clears it, so log it.
function Dongle:getInfo()
  local raw = ffi.new('licd_info')
  self.context:check(lib.licd_get_info(self:checkedHandle(), raw), 'licd_get_info')
  return {
    protocolVersion = { raw.proto_version_major, raw.proto_version_minor },
    firmwareVersion = { raw.fw_version_major, raw.fw_version_minor, raw.fw_version_patch },
    seReady = raw.se_ready ~= 0,
    provisioned = raw.provisioned ~= 0,
    dataCapacity = raw.data_capacity,
    dataFree = raw.data_free,
    watchdogReboot = raw.watchdog_reboot ~= 0,
    isolated = raw.isolated ~= 0,
    writeauthRotated = raw.writeauth_rotated ~= 0,
  }
end

--- The dongle serial as hex.
function Dongle:getSerial()
  local buffer = ffi.new('char[15]')
  self.context:check(lib.licd_get_serial(self:checkedHandle(), buffer, 15), 'licd_get_serial')
  return ffi.string(buffer)
end

--- Proves authenticity: the certificate chain to the trusted root plus a live
--- ECDSA challenge-response. Errors unless the dongle is genuine.
function Dongle:verifyGenuine()
  local raw = ffi.new('licd_genuine_result')
  self.context:check(lib.licd_verify_genuine(self:checkedHandle(), raw), 'licd_verify_genuine')
  return {
    genuine = raw.genuine ~= 0,
    serial = fixedString(raw.serial),
    provisionedDate = fixedString(raw.provisioned_date),
  }
end

--- The non-erroring form, for a licence gate. Fails closed: a missing dongle, an
--- I/O error and an invalid certificate all return false.
function Dongle:isGenuine()
  local ok, result = pcall(self.verifyGenuine, self)
  return ok and result.genuine or false
end

--- Opens an encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM).
function Dongle:openSession()
  self.context:check(lib.licd_session_open(self:checkedHandle()), 'licd_session_open')
  return M.Session(self)
end

-- --- Session ----------------------------------------------------------------

local Session = {}
Session.__index = Session
M.Session = function(dongle)
  return setmetatable({ dongle = dongle, open = true }, Session)
end

function Session:isOpen()
  return self.open
end

--- Ends the session, zeroizing the session keys on the dongle. Never errors.
function Session:close()
  if self.open then
    self.open = false
    if self.dongle:isOpen() then
      lib.licd_session_close(self.dongle.handle)
    end
  end
end

function Session:device()
  if not self.open then
    fail(M.Status.SESSION_EXPIRED, 'session', 'the session has been closed')
  end
  return self.dongle:checkedHandle()
end

function Session:check(rc, operation)
  self.dongle.context:check(rc, operation)
end

local function requireName(name)
  if type(name) ~= 'string' or name == '' then
    error('the record name must be a non-empty string', 3)
  end
  return name
end

--- Elevates to the write role with the developer master key (a DER EC private
--- key). This belongs in your licence-issuing tooling; never ship
--- that key in the application your users run.
function Session:authorizeWrite(masterKeyDer)
  local buffer = byteBuffer(masterKeyDer)
  self:check(lib.licd_write_auth(self:device(), buffer, #masterKeyDer), 'licd_write_auth')
end

--- Replaces the dongle's write-auth key with your own (a DER EC private key).
--- Call authorizeWrite with the current key first. From the next session on, only
--- the new key elevates.
function Session:rotateWriteKey(newKeyDer)
  local buffer = byteBuffer(newKeyDer)
  self:check(lib.licd_write_auth_rotate(self:device(), buffer, #newKeyDer),
             'licd_write_auth_rotate')
end

--- Records stored on the dongle, as a list of { name, size }.
function Session:listRecords()
  local names = ffi.new('char**[1]')
  local sizes = ffi.new('uint32_t*[1]')
  local count = ffi.new('size_t[1]')
  self:check(lib.licd_record_list(self:device(), names, sizes, count), 'licd_record_list')
  local out = {}
  if names[0] ~= nil then
    for i = 0, tonumber(count[0]) - 1 do
      out[#out + 1] = { name = ffi.string(names[0][i]), size = sizes[0][i] }
    end
    lib.licd_free_record_list(names[0], sizes[0], count[0])
  end
  return out
end

--- Wraps a Lua progress function as a C callback.
---
--- The callback must be freed explicitly: LuaJIT allocates a machine-code
--- trampoline per ffi.cast of a function, and they are a finite resource. An error
--- raised inside it is held and re-raised once the SDK has unwound its own
--- transfer — throwing through the C frames would strand the device mid-transfer.
local function withProgress(progress, body)
  if progress == nil then
    return body(nil)
  end
  local raised = nil
  local callback = ffi.cast('licd_progress_cb', function(done, total, _user)
    if raised ~= nil then
      return 0
    end
    local ok, result = pcall(progress, tonumber(done), tonumber(total))
    if not ok then
      raised = result
      return 0
    end
    -- Anything but an explicit false continues, so a callback that only draws a
    -- progress bar is safe.
    return result == false and 0 or 1
  end)
  local ok, status = pcall(body, callback)
  callback:free()
  if not ok then
    error(status, 0)
  end
  if raised ~= nil then
    error(raised, 0)
  end
  return status
end

--- Reads a record. `progress(done, total)` may return false to cancel.
function Session:readRecord(name, progress)
  requireName(name)
  local device = self:device()
  local got = ffi.new('uint32_t[1]')
  local total = ffi.new('uint32_t[1]')

  -- Probe for the size first, so progress runs monotonically from 0 to total.
  local probe = ffi.new('uint8_t[1]')
  self:check(lib.licd_record_read(device, name, 0, probe, 1, got, total, nil, nil),
             'licd_record_read')
  local size = tonumber(total[0])
  if size == 0 then
    return ''
  end

  local buffer = ffi.new('uint8_t[?]', size)
  local rc = withProgress(progress, function(callback)
    return lib.licd_record_read(device, name, 0, buffer, size, got, total, callback, nil)
  end)
  self:check(rc, 'licd_record_read')
  return ffi.string(buffer, tonumber(got[0]))
end

--- Atomically replaces a record. Requires the write role.
function Session:writeRecord(name, data, progress)
  requireName(name)
  local device = self:device()
  local buffer = byteBuffer(data)
  local rc = withProgress(progress, function(callback)
    return lib.licd_record_write(device, name, #data > 0 and buffer or nil, #data,
                                 callback, nil)
  end)
  self:check(rc, 'licd_record_write')
end

--- Erases one record. Requires the write role.
function Session:eraseRecord(name)
  -- A nil name means "erase everything" to the C API; that is eraseAllRecords
  -- here, so an empty string cannot wipe the dongle.
  requireName(name)
  self:check(lib.licd_record_erase(self:device(), name), 'licd_record_erase')
end

--- Erases every record. Requires the write role.
function Session:eraseAllRecords()
  self:check(lib.licd_record_erase(self:device(), nil), 'licd_record_erase')
end

function Session:readCounter(counterId)
  local value = ffi.new('uint32_t[1]')
  self:check(lib.licd_counter_read(self:device(), counterId, value), 'licd_counter_read')
  return tonumber(value[0])
end

--- Irreversible: the counter is monotonic in hardware. Requires the write role.
function Session:incrementCounter(counterId)
  local value = ffi.new('uint32_t[1]')
  self:check(lib.licd_counter_increment(self:device(), counterId, value),
             'licd_counter_increment')
  return tonumber(value[0])
end

--- Encrypts so that only a dongle of `scope` can decrypt. This is the pair to
--- build a licence check on: put something the program genuinely needs through it,
--- so removing the check removes the data.
function Session:appEncrypt(scope, plaintext)
  if scope ~= M.Scope.DEVICE and scope ~= M.Scope.DEVELOPER then
    error('scope must be Scope.DEVICE or Scope.DEVELOPER', 2)
  end
  local buffer = byteBuffer(plaintext)
  local out = ffi.new('uint8_t*[1]')
  local outLen = ffi.new('uint32_t[1]')
  self:check(lib.licd_app_encrypt(self:device(), scope,
                                  #plaintext > 0 and buffer or nil, #plaintext,
                                  out, outLen),
             'licd_app_encrypt')
  return takeBuffer(out, tonumber(outLen[0]))
end

--- Decrypts a blob produced by appEncrypt, using the dongle.
function Session:appDecrypt(packed)
  local buffer = byteBuffer(packed)
  local out = ffi.new('uint8_t*[1]')
  local outLen = ffi.new('uint32_t[1]')
  self:check(lib.licd_app_decrypt(self:device(), #packed > 0 and buffer or nil, #packed,
                                  out, outLen),
             'licd_app_decrypt')
  return takeBuffer(out, tonumber(outLen[0]))
end

return M
