# KeyNub License Dongle — Lua binding (LuaJIT)

```lua
local keynub = require('keynub_licdongle')

local ctx = keynub.Context()
local dongle = ctx:open()                    -- first dongle, or ctx:open(serial)
dongle:verifyGenuine()                       -- errors unless genuine
local session = dongle:openSession()
local data = session:appDecrypt(blob)        -- <- build the licence check here
session:close(); dongle:close(); ctx:close()
```

**Requires LuaJIT.** Its `ffi` module is what makes this one file with nothing to
compile; plain Lua 5.x has no FFI and would need a C extension module, which
defeats the point. Verified with LuaJIT 2.1.

Point it at a specific library with `KEYNUB_LICDONGLE_LIBRARY`.

## Why Lua is on this list

Lua is rarely the language a product is *written* in — it is the language a product
is *extended* in: a CAD package, a simulator, an instrument's scripting host, a
game engine. That makes it a natural place for a licence check on a paid plugin or
add-on, and it is also the case where the check is most exposed, because the
script usually ships as readable source alongside the application.

Which is exactly why the answer is not a boolean. See
[`../../docs/integration-security.md`](../../docs/integration-security.md):
`if not licensed then os.exit() end` is one line of a file the customer can edit.
Put what the add-on needs through `appEncrypt`/`appDecrypt` instead.

## Notes

- Errors are raised as tables with `status`, `operation`, `message` and `detail`,
  and a `__tostring` so they stay readable if they reach a log unhandled. Compare
  `err.status` against `keynub.Status.*`.
- `dongle:isGenuine()` is the non-erroring form for a gate and **fails closed**.
- Byte data is a Lua string throughout, which is what LuaJIT's `ffi.string`
  produces and what `#s` measures correctly for binary data.
- `readRecord`/`writeRecord` take an optional `progress(done, total)`; returning
  `false` cancels. An error raised inside it is held and re-raised once the SDK has
  unwound its own transfer.
- Progress callbacks are freed explicitly after use: LuaJIT allocates a
  machine-code trampoline per `ffi.cast` of a function and they are a finite
  resource, so a long-running host that forgot would eventually run out.

## Testing

```
KEYNUB_SIM_PATH=../../build/keynub_licdongle_sim.dll luajit test/test_end_to_end.lua
```

46 assertions against an in-process software dongle — **no hardware** — covering
the full protocol stack plus the struct layout across the FFI boundary (a mistake
shows up as a garbage value, not a wrong boolean), the progress bridge with
cancellation and an error thrown from inside a callback, and a session outliving
its dongle. A plain assertion harness, so no rocks are needed.
