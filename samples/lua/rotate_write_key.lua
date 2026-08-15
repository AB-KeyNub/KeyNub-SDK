-- KeyNub SDK - Lua sample: take ownership of a new dongle.
--
-- A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
-- that from the next session onward only your key can write records, erase them or
-- increment counters. Run it once per dongle, when it arrives.
--
-- Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
--
--   openssl ecparam -name prime256v1 -genkey -noout |
--     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
--
--   KEYNUB_LICDONGLE_LIBRARY=../../build/keynub_licdongle.dll \
--     luajit -e "package.path='../../bindings/lua/?.lua;'..package.path" \
--     rotate_write_key.lua ../../keys/keynub-shipping-writeauth.key.der my-key.der
--
-- Targets real hardware: with no dongle attached it prints guidance and exits 0.
--
-- The replacement key is worth what your licence-signing key is worth. It cannot be
-- recovered from the dongle, and a unit rotated to a key you have lost has to come
-- back to be re-provisioned.

local ok, keynub = pcall(require, 'keynub_licdongle')
if not ok then
  -- Running from a checkout, where the rock is not installed.
  local dir = debug.getinfo(1, 'S').source:match('^@(.*)[/\\][^/\\]*$') or '.'
  package.path = dir .. '/../../bindings/lua/?.lua;' .. package.path
  keynub = require('keynub_licdongle')
end

local function readKey(path)
    local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
    local der = f:read('*a')
    f:close()
    return der
end

local function main(args)
    if #args ~= 2 then
        io.stderr:write('usage: rotate_write_key.lua <current-key.der> <new-key.der>\n')
        return 2
    end
    local current, replacement = readKey(args[1]), readKey(args[2])

    local ctx = keynub.Context()
    if #ctx:enumerate() == 0 then
        print('Connect a KeyNub dongle and re-run.')
        ctx:close()
        return 0
    end

    local dongle = ctx:open()
    print('dongle ' .. dongle:getSerial())

    local session = dongle:openSession()
    session:authorizeWrite(current)
    session:rotateWriteKey(replacement)
    print('rotated: this dongle now answers only to your key')
    session:close()

    -- A fresh session is the only place the change is observable: the session
    -- above keeps the role it was already granted.
    session = dongle:openSession()
    local elevated = pcall(function() session:authorizeWrite(current) end)
    if elevated then
        io.stderr:write('WARNING: the old key still works -- do not ship this unit\n')
        return 1
    end
    print('confirmed: the old key no longer elevates')
    session:authorizeWrite(replacement)
    print('confirmed: your key elevates')
    session:close()

    dongle:close()
    ctx:close()

    print('\nKeep the replacement key safe. Every future write to this dongle needs it.')
    return 0
end

local ok, result = pcall(main, { ... })
if not ok then
    io.stderr:write('KeyNub error: ' .. tostring(result) .. '\n')
    os.exit(1)
end
os.exit(result)
