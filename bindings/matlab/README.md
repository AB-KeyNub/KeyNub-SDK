# KeyNub License Dongle — MATLAB / Simulink binding

MATLAB binding for the KeyNub USB-C license dongle, on the same C core as every
other binding. Requires **MATLAB R2016b or newer**; no toolboxes for the MATLAB
API, Simulink for the block, MATLAB Coder for the code-generation path.

```matlab
addpath('<SDK>/bindings/matlab');

ctx     = keynub.Context();
dongle  = ctx.open();                    % first dongle, or pass a serial
result  = dongle.verifyGenuine();        % errors if it is not genuine

session = dongle.openSession();          % ECDH / HKDF / AES-256-GCM
data    = session.appDecrypt(blob);      % <- build your licence check on this
session.close();
```

> **Read [`../../docs/integration-security.md`](../../docs/integration-security.md)
> before writing your check.** `if licensed ... end` in a `.m` file — or in P-code,
> or in a MATLAB Compiler executable — is one line for an attacker to remove. Put
> something the program actually needs through `appEncrypt`/`appDecrypt`: plant
> coefficients, a lookup table, a trained network's weights. See
> [`../../samples/matlab/licence_protected_parameters.m`](../../samples/matlab/licence_protected_parameters.m)
> for the shape that protects a toolbox instead of decorating it.

## Layout

```
+keynub/Context.m        enumerate / open / trust root
+keynub/Dongle.m         getInfo, getSerial, verifyGenuine, isGenuine, openSession
+keynub/Session.m        records, counters, appEncrypt/appDecrypt, authorizeWrite
+keynub/Scope.m          Device | Developer
+keynub/LicenseCheck.m   Simulink licence gate (matlab.System)
+keynub/build.m          compiles the MEX gateway from source
+keynub/+internal/       not API
src/licd_mex.c           the MEX gateway (all validation and marshalling)
mex/                     built gateway: licd_mex.<mexext>
```

Results are plain structs, which is what MATLAB code expects — `info.dataFree`,
`result.genuine`, `records(3).name`. Byte data is `uint8`; a `double` vector of
whole numbers in 0..255 is accepted too, because in MATLAB `[1 2 3]` is a double
and refusing it would be needlessly hostile. A value that cannot be a byte is an
error rather than a silent truncation.

Failures are MATLAB errors with stable identifiers — `KeyNub:licdongle:noDevice`,
`:notGenuine`, `:recordNotFound`, `:writeAuthorizationRequired`, `:cancelled`, one
per status code — so `catch err; switch err.identifier` works.

## Building the gateway

A release ships `mex/licd_mex.<mexext>` prebuilt, so **customers need no
compiler**. Building from source needs one command after the prebuilt native package:

```matlab
keynub.build('native/')                 % production gateway
keynub.build('native/', 'Sim', true)    % + device simulator, for the tests
```

It links the SDK **statically**, so the gateway is one self-contained file. That
is not just tidiness: Windows resolves a MEX file's DLL dependencies against the
MATLAB executable's directory, not the MEX file's own, so a gateway that depended
on `keynub_licdongle.dll` would need that DLL on the system `PATH` at every
customer site.

Never ship a `'Sim'` gateway — it exposes test entry points the shipping library
deliberately does not export.

### Why MEX and not `loadlibrary`

`loadlibrary` would need no compile step from us, but it needs one from the
*customer*: on 64-bit platforms it builds a thunk with a supported C compiler and
Perl at load time. Worse for a licensing product, MathWorks state that loading a
library **via a header file is not supported in compiled applications**, so a
MATLAB Compiler or MATLAB Runtime deployment — exactly where a licence check
earns its keep — would need a pre-generated prototype file plus a thunk DLL
shipped alongside. A MEX file is an ordinary deployment dependency.

## Simulink

`keynub.LicenseCheck` is a `matlab.System` object for a **MATLAB System** block.
It verifies at model initialisation, optionally re-verifies every N steps so
unplugging the dongle is noticed, and outputs a logical `licensed` signal.
[`../../samples/simulink/keynub_license_gate.m`](../../samples/simulink/keynub_license_gate.m)
builds a demo model in code.

The block is pinned to **interpreted execution**: it calls a MEX file, so there is
nothing to generate code from. To carry a licence check into *generated* code,
call the C ABI from the generated build instead —
[`../../samples/matlab/codegen/`](../../samples/matlab/codegen/) has the C shim, a
`coder.ceval` entry point that behaves identically in simulation and in generated
code, and the MATLAB Coder configuration that links it.

| You are shipping | Use |
| --- | --- |
| A MATLAB toolbox or `.m`/P-code library | `+keynub` classes, gate on `appDecrypt` |
| A MATLAB Compiler standalone / web app | same, with `mex/licd_mex.*` added via `mcc -a` |
| A Simulink model or blockset | `keynub.LicenseCheck`, plus `appDecrypt` for parameters |
| Generated C from Coder / Simulink Coder | `samples/matlab/codegen` (`keynub_gate.c`) |

## Testing

The binding is tested from two directions, because MATLAB cannot be installed on
the machines that run the automated tests:

1. **The SDK's own test suite, on every push.** All of
   the binding's logic lives in `src/licd_mex.c`: dispatch and arity, type and
   range checks, handle validation and lifetime, struct field names, the
   progress-callback bridge with its cancel and rethrow paths, and the
   reentrancy guard. The test drives `mexFunction` through a minimal
   implementation of the `mx`/`mex` API
   (a stand-in `mex.h` that ships with the SDK's test suite) that also
   reproduces MATLAB's memory rules, so a leaked `mxArray` fails the build. That
   header documents exactly what this does and does not prove.

2. **the binding's MATLAB test class — needs MATLAB.** The `+keynub` classes against the
   in-process device simulator: the full protocol stack with no hardware, plus
   the things only MATLAB can execute (object lifetimes, `delete` ordering,
   progress callbacks as real function handles).

```matlab
keynub.build('native/', 'Sim', true)
runtests('tests')
```

The classes are deliberately thin: the gateway they call is covered as above, so
there is as little logic as possible between MATLAB and the tested ABI.

## License

Apache-2.0, the same as the rest of the SDK — see [`../../LICENSE`](../../LICENSE),
[`../../NOTICE`](../../NOTICE) and
[`../../THIRD-PARTY-NOTICES.txt`](../../THIRD-PARTY-NOTICES.txt). The gateway
statically links Mbed TLS and hidapi, so those notices ship with it.
