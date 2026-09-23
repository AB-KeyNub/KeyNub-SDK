-- Every call of the binding against a stand-in for the C ABI
-- (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory),
-- compiled into a shared library with a C compiler from the path (cc, gcc,
-- clang, zig cc or cl). KEYNUB_LICDONGLE_LIBRARY naming an already compiled
-- stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the test
-- does not run inside a clone. Exit code 0 when every check passed.
--
--     luajit test/test_standin.lua        (from bindings/lua)

local ffi = require('ffi')
local windows = ffi.os == 'Windows'

if windows then
  ffi.cdef[[
  int _putenv_s(const char *name, const char *value);
  char *_getcwd(char *buffer, int size);
  ]]
else
  ffi.cdef[[
  int setenv(const char *name, const char *value, int overwrite);
  char *getcwd(char *buffer, size_t size);
  ]]
end

-- ---- the stand-in -------------------------------------------------------------

local function isFile(path)
  local file = io.open(path, 'rb')
  if file then
    file:close()
    return true
  end
  return false
end

local function cwd()
  local buffer = ffi.new('char[4096]')
  local result = windows and ffi.C._getcwd(buffer, 4096) or ffi.C.getcwd(buffer, 4096)
  return result ~= nil and ffi.string(buffer) or '.'
end

local function parent(dir)
  return dir:match('^(.*)[/\\][^/\\]+$')
end

local function sdkRoot()
  local given = os.getenv('KEYNUB_SDK_ROOT')
  if given and given ~= '' then
    return given
  end
  local dir = cwd()
  while dir and dir ~= '' do
    if isFile(dir .. '/bindings/flat/licd_flat.c') then
      return dir
    end
    dir = parent(dir)
  end
  print('the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT')
  os.exit(1)
end

local function quote(text)
  return '"' .. text .. '"'
end

local function buildStandIn()
  local root = sdkRoot()
  local tmp = windows and (os.getenv('TEMP') or os.getenv('TMP') or '.') or (os.getenv('TMPDIR') or '/tmp')
  -- Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf
  -- name even for an absolute-path dlopen, and a build tree on that path holds
  -- the real library under that name.
  local output = tmp .. (windows and '\\keynub_licdongle_standin.dll' or '/libkeynub_licdongle_standin.so')
  local include = root .. '/core/include'
  if not isFile(include .. '/licdongle.h') then
    include = root .. '/include'
  end
  local source = root .. '/bindings/julia/test/stub/licd_stub.c'
  local gcc = '-shared -O1 -DLICD_BUILD_SHARED -I' .. quote(include) .. ' -o ' .. quote(output)
      .. ' ' .. quote(source) .. (windows and '' or ' -fPIC')
  local cl = '/nologo /LD /O1 /DLICD_BUILD_SHARED /I' .. quote(include) .. ' /Fe:' .. quote(output)
      .. ' ' .. quote(source)
  -- In the temporary folder, where the compilers leave their byproducts.
  local prefix = windows and ('cd /d ' .. quote(tmp) .. ' && ') or ('cd ' .. quote(tmp) .. ' && ')
  local silence = windows and ' >NUL 2>&1' or ' >/dev/null 2>&1'
  for _, command in ipairs({ 'cc ' .. gcc, 'gcc ' .. gcc, 'clang ' .. gcc, 'zig cc ' .. gcc, 'cl ' .. cl }) do
    os.remove(output)
    local status = os.execute(prefix .. command .. silence)
    if (status == 0 or status == true) and isFile(output) then
      return output
    end
  end
  print('the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path')
  os.exit(1)
end

-- The library is chosen when the binding is first loaded, once per process.
local given = os.getenv('KEYNUB_LICDONGLE_LIBRARY')
if not given or given == '' then
  local library = buildStandIn()
  if windows then
    ffi.C._putenv_s('KEYNUB_LICDONGLE_LIBRARY', library)
  else
    ffi.C.setenv('KEYNUB_LICDONGLE_LIBRARY', library, 1)
  end
end

local here = debug.getinfo(1, 'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
package.path = here .. '/../?.lua;./?.lua;' .. package.path
local keynub = require('keynub_licdongle')
local Status = keynub.Status

-- ---- the checks ------------------------------------------------------------------

local SERIAL = '04A1B2C3D4E5F6'
local FACTORY_KEY = '\48\16\1\2\3'
local REPLACEMENT_KEY = '\48\17\9\8\7\6'
local failures = 0

local function check(condition, what)
  if not condition then
    failures = failures + 1
    print('  FAIL  ' .. what)
  end
end

-- Checks that `action` raises; with a status, a binding error carrying it,
-- otherwise a plain error message.
local function fails(status, what, action)
  local ok, err = pcall(action)
  if ok then
    check(false, what .. ': no failure')
  elseif status then
    check(type(err) == 'table' and err.status == status, what .. ': ' .. tostring(err))
  else
    check(type(err) == 'string', what .. ': ' .. tostring(err))
  end
end

local function bytes(...)
  return string.char(...)
end

local major, minor, patch = keynub.libraryVersion()
check(major == 9 and minor == 8 and patch == 7, 'library version')
check(Status.NO_DEVICE == -2, 'status code')

local ctx = keynub.Context()
local ok, err = pcall(function() return ctx:open('nope') end)
check(not ok and getmetatable(err) == keynub.Error, 'error type')
check(err.status == Status.NO_DEVICE and err.operation == 'licd_open', 'error status')
check(err.message == 'no device', 'status text')
check(err.detail == 'no dongle with that serial', 'error detail')
check(tostring(err) == 'licd_open: no device (no dongle with that serial)', 'error text')
check(ctx:lastErrorDetail() == 'no dongle with that serial', 'last error detail')

local devices = ctx:enumerate()
check(#devices == 1 and devices[1].serial == SERIAL and devices[1].path == 'stub:0'
      and devices[1].vendorId == 0x1234 and devices[1].productId == 0xABCD, 'devices')
fails(Status.NO_DEVICE, 'open by unknown serial', function() return ctx:open('nope') end)
fails(Status.NO_DEVICE, 'open by unknown path', function() return ctx:openPath('stub:9') end)
local bySerial = ctx:open(SERIAL)
check(bySerial:getSerial() == SERIAL, 'open by serial')
bySerial:close()
local byPath = ctx:openPath('stub:0')
check(byPath:getSerial() == SERIAL, 'open by path')
byPath:close()

local d = ctx:open()
check(d:isOpen(), 'open')
check(d:getSerial() == SERIAL, 'serial')
local i = d:getInfo()
check(i.protocolVersion[1] == 1 and i.protocolVersion[2] == 0, 'protocol version')
check(i.firmwareVersion[1] == 2 and i.firmwareVersion[2] == 3 and i.firmwareVersion[3] == 4, 'firmware version')
check(i.seReady == true and i.provisioned == true and i.isolated == true, 'flags set')
check(i.watchdogReboot == false and i.writeauthRotated == false, 'flags clear')
check(i.dataCapacity == 1024 * 1024 and i.dataFree == 1000000, 'capacity')

local g = d:verifyGenuine()
check(g.genuine == true and g.serial == SERIAL and g.provisionedDate == '2026-08-15', 'genuine')
check(d:isGenuine() == true, 'isGenuine')
fails(Status.CERTIFICATE_INVALID, 'malformed trust root', function() ctx:setTrustRoot(bytes(0x02, 0x01, 0x00)) end)
fails(Status.INVALID_ARGUMENT, 'empty trust root', function() ctx:setTrustRoot('') end)
ctx:setTrustRoot(bytes(0x30, 0x82, 0x01, 0x00) .. string.rep('\171', 128))
fails(Status.CERTIFICATE_INVALID, 'verify against a foreign root', function() return d:verifyGenuine() end)
check(d:isGenuine() == false, 'isGenuine fails closed')
ctx:setTrustRoot(bytes(0x30, 0x82, 0x01, 0x00) .. string.rep('\1', 128))
check(d:isGenuine() == true, 'isGenuine after the right root')

-- A second session object ends the dongle's session under the first one.
local first = d:openSession()
local second = d:openSession()
second:close()
fails(Status.SESSION_EXPIRED, 'records without a session', function() return first:listRecords() end)
first:close()
check(not first:isOpen(), 'closed session reports closed')
fails(Status.SESSION_EXPIRED, 'closed session', function() return first:listRecords() end)
first:close() -- idempotent

local s = d:openSession()
local payload = 'license-blob-0123456789'
fails(Status.AUTH_REQUIRED, 'write before the write role', function() s:writeRecord('lic', payload) end)
fails(Status.AUTH_REQUIRED, 'increment before the write role', function() return s:incrementCounter(0) end)
fails(Status.NOT_GENUINE, 'write role with a bad key', function() s:authorizeWrite(bytes(0x30, 0x00)) end)
s:authorizeWrite(FACTORY_KEY)
s:writeRecord('lic', payload)
check(s:readRecord('lic') == payload, 'read back')
s:writeRecord('cfg', 'cfgdata')
local recs = s:listRecords()
local names, licSize = {}, nil
for _, r in ipairs(recs) do
  names[#names + 1] = r.name
  if r.name == 'lic' then
    licSize = r.size
  end
end
table.sort(names)
check(#names == 2 and names[1] == 'cfg' and names[2] == 'lic', 'record names')
check(licSize == #payload, 'record size')
check(s:readRecord('cfg') == 'cfgdata', 'second record')
fails(Status.NOT_FOUND, 'read a missing record', function() return s:readRecord('nope') end)
fails(Status.NOT_FOUND, 'erase a missing record', function() s:eraseRecord('nope') end)
fails(nil, 'erase with an empty name', function() s:eraseRecord('') end)
fails(nil, 'read with an empty name', function() return s:readRecord('') end)
check(#s:listRecords() == 2, 'two records')
s:eraseRecord('cfg')
recs = s:listRecords()
check(#recs == 1 and recs[1].name == 'lic', 'one record left')
s:writeRecord('empty', '')
check(s:readRecord('empty') == '', 'empty record')
local bigBytes = {}
for k = 0, 1999 do
  bigBytes[#bigBytes + 1] = string.char((k * 31 + 5) % 256)
end
local big = table.concat(bigBytes)
s:writeRecord('big', big)
check(s:readRecord('big') == big, 'record larger than one transfer chunk')

local writes = {}
s:writeRecord('big', big, function(done, total) writes[#writes + 1] = { done, total } end)
check(#writes > 0 and writes[#writes][1] == 2000 and writes[#writes][2] == 2000, 'write progress')
local reads = {}
local data = s:readRecord('big', function(done, total)
  reads[#reads + 1] = { done, total }
  return true
end)
check(data == big and reads[#reads][1] == 2000 and reads[#reads][2] == 2000, 'read progress')
fails(Status.CANCELLED, 'read cancelled', function() return s:readRecord('big', function() return false end) end)
fails(Status.CANCELLED, 'write cancelled', function() s:writeRecord('big', big, function() return false end) end)
ok, err = pcall(function() return s:readRecord('big', function() error('callback exploded', 0) end) end)
check(not ok and err == 'callback exploded', 'an error in the callback is re-raised')
check(s:readRecord('big', function() return nil end) == big, 'a callback returning nothing does not cancel')

local before = s:readCounter(0)
check(s:incrementCounter(0) == before + 1, 'increment')
check(s:readCounter(0) == before + 1 and s:readCounter(1) == 0, 'counters')
fails(Status.RANGE, 'counter out of range', function() return s:readCounter(7) end)
fails(Status.RANGE, 'increment out of range', function() return s:incrementCounter(7) end)

local secretBytes = {}
for k = 0, 99 do
  secretBytes[#secretBytes + 1] = string.char((3 * k + 7) % 256)
end
local secret = table.concat(secretBytes)
for _, scope in ipairs({ keynub.Scope.DEVICE, keynub.Scope.DEVELOPER }) do
  local blob = s:appEncrypt(scope, secret)
  check(#blob > #secret, 'sealed data is longer, scope ' .. scope)
  check(blob:byte(1) == scope, 'scope byte, scope ' .. scope)
  check(s:appDecrypt(blob) == secret, 'round trip, scope ' .. scope)
  local tampered = blob:sub(1, #blob - 1) .. string.char(bit.bxor(blob:byte(#blob), 1))
  fails(Status.TAG_MISMATCH, 'tampered blob, scope ' .. scope, function() return s:appDecrypt(tampered) end)
end
fails(nil, 'unknown scope', function() return s:appEncrypt(7, secret) end)
check(s:appDecrypt(s:appEncrypt(keynub.Scope.DEVICE, '')) == '', 'empty plaintext')
fails(Status.INVALID_ARGUMENT, 'short blob', function() return s:appDecrypt(bytes(0, 1)) end)

s:eraseAllRecords()
check(#s:listRecords() == 0, 'erase all')

s:close()
s = d:openSession()
fails(Status.AUTH_REQUIRED, 'rotate before the write role', function() s:rotateWriteKey(REPLACEMENT_KEY) end)
s:authorizeWrite(FACTORY_KEY)
s:rotateWriteKey(REPLACEMENT_KEY)
s:writeRecord('lic', 'still-writable')
s:close()
check(d:getInfo().writeauthRotated == true, 'rotated flag')
s = d:openSession()
fails(Status.NOT_GENUINE, 'factory key after rotation', function() s:authorizeWrite(FACTORY_KEY) end)
s:authorizeWrite(REPLACEMENT_KEY)
s:writeRecord('lic', 'new-key-writes')
check(s:readRecord('lic') == 'new-key-writes', 'write with the new key')

d:close()
d:close() -- idempotent
check(not d:isOpen(), 'closed')
fails(Status.INVALID_ARGUMENT, 'serial after close', function() return d:getSerial() end)
-- A session whose dongle was closed refuses, and closing it does not touch the device.
fails(Status.INVALID_ARGUMENT, 'session after its dongle closed', function() return s:listRecords() end)
s:close()

local out = ffi.new('licd_device*[1]')
check(keynub.lib.licd_open(ctx:checkedHandle(), nil, out) == 0, 'raw open')
local adopted = ctx:adopt(out[0])
check(adopted:getSerial() == SERIAL, 'adopt')
adopted:close()

ctx:close()
ctx:close() -- idempotent
check(not ctx:isOpen(), 'context closed')
fails(Status.INVALID_ARGUMENT, 'context after close', function() return ctx:enumerate() end)

if failures > 0 then
  print(failures .. ' check(s) failed')
  os.exit(1)
end
print('keynub-licdongle: every call passed against the ABI stand-in')
os.exit(0)
