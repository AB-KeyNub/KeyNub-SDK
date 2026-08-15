-- KeyNub dongle check from Lua: enumerate -> open -> verify -> session ->
-- read a record -> app-crypto round trip.
--
--   KEYNUB_LICDONGLE_LIBRARY=../../build/keynub_licdongle.dll \
--     luajit -e "package.path='../../bindings/lua/?.lua;'..package.path" verify_and_read.lua
--
-- Requires LuaJIT: its ffi module is what makes the binding one file with nothing
-- to compile.
--
-- Targets real hardware: with no dongle attached it prints guidance and exits 0.
--
-- READ FIRST: docs/integration-security.md. This sample prints whether the dongle
-- is genuine, which is the one thing a real licence check must not do -- a printed
-- boolean is a deleted line away from nothing. protectSomething shows the shape
-- that actually protects something, and Lua is where it matters most: a plugin
-- usually ships as readable source alongside the application, so
-- `if not licensed then os.exit() end` is one line of a file the customer can edit.

local ok, keynub = pcall(require, 'keynub_licdongle')
if not ok then
  -- Running from a checkout, where the rock is not installed.
  local dir = debug.getinfo(1, 'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
  package.path = dir .. '/../../bindings/lua/?.lua;' .. package.path
  keynub = require('keynub_licdongle')
end

local function report(dongle)
    local info = dongle:getInfo()
    print(string.format('Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.',
        info.protocolMajor, info.protocolMinor,
        info.firmwareMajor, info.firmwareMinor, info.firmwarePatch,
        info.dataFree, info.dataCapacity))

    if info.watchdogReboot then
        -- The only trace a firmware hang leaves behind. Worth reporting to support.
        print("WARNING: this dongle's previous boot ended in a watchdog reset.")
    end

    local result = dongle:verifyGenuine()
    print(string.format('Genuine: %s (serial %s)',
        tostring(result.genuine), result.serial))
end

local function readRecords(session)
    local records = session:listRecords()
    print(string.format('%d record(s) on the dongle:', #records))
    for _, record in ipairs(records) do
        print(string.format('  %-16s %6d bytes', record.name, record.size))
    end

    for _, record in ipairs(records) do
        if record.name == 'license' then
            local data = session:readRecord('license')
            -- #data is correct for binary here: byte data is a Lua string throughout.
            print(string.format('Read %d bytes from the license record.', #data))
            break
        end
    end
end

-- The part that actually protects something. At licence-issue time you would call
-- appEncrypt once, with a developer dongle, and ship only the blob; the add-on then
-- cannot proceed without a dongle, because it holds no other copy of the data.
-- Scope.DEVELOPER lets any dongle you have issued decrypt it, so one file serves
-- every customer; Scope.DEVICE locks it to one dongle.
local function protectSomething(session)
    local needed = 'the data this program cannot run without'

    local sealed = session:appEncrypt(keynub.Scope.DEVELOPER, needed)
    local recovered = session:appDecrypt(sealed)

    print(string.format('App-crypto round trip: %d bytes -> %d sealed -> %s',
        #needed, #sealed, recovered == needed and 'recovered intact' or 'MISMATCH'))
end

local function run()
    local ctx = keynub.Context()

    local devices = ctx:enumerate()
    print(string.format('Found %d KeyNub dongle(s).', #devices))
    for i, d in ipairs(devices) do
        print(string.format('  [%d] serial %s (VID %04X PID %04X)',
            i - 1, d.serial, d.vendorId, d.productId))
    end
    if #devices == 0 then
        print('No dongle attached; nothing to do.')
        ctx:close()
        return
    end

    -- No argument = first dongle found; pass a serial to pick a specific one.
    local dongle = ctx:open()
    report(dongle)

    local session = dongle:openSession()
    readRecords(session)
    protectSomething(session)

    session:close()
    dongle:close()
    ctx:close()
end

local major, minor, patch = keynub.libraryVersion()
print(string.format('KeyNub SDK %d.%d.%d', major, minor, patch))

-- Errors are raised as tables with status/operation/message/detail and a
-- __tostring, so this stays readable whichever way it arrives.
local ok, err = pcall(run)
if not ok then
    io.stderr:write('KeyNub error: ' .. tostring(err) .. '\n')
    os.exit(1)
end
