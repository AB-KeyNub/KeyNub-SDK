# KeyNub License Dongle — Ada binding

```ada
with KeyNub_LicDongle; use KeyNub_LicDongle;

Ctx : aliased Context;
D   : Dongle;
...
Create (Ctx);
Open (Ctx, D);                                   -- first dongle, or Open (Ctx, D, Serial)
declare
   Result : constant Genuine_Result := Verify_Genuine (D);   -- raises unless genuine
begin
   Session_Open (D);
   declare
      Data : constant Bytes := App_Decrypt (D, Sealed);      -- <- build the licence check on this
   begin
      ...
   end;
   Session_Close (D);
end;
```

**Nothing to link.** The crate is Ada 2012 over the SDK's C ABI (records with
`Convention => C`, so the compiler lays them out as C does) and loads the
native library at run time with the system loader, so a project needs no
`-L` flag and nothing sits in the path of the check that a customer could
substitute. GNAT and `gprbuild`, through Alire.

## Setup

```
alr with keynub_licdongle
```

The crate does not carry the native library. Take `keynub_licdongle` for
your platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where the operating system finds libraries (`PATH`,
`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`) or name it before the first call:

```ada
Set_Library_Path ("/opt/keynub/libkeynub_licdongle.so");
```

`KEYNUB_LICDONGLE_LIBRARY` in the environment does the same. In a clone of the
SDK repository the crate finds `natives/<platform>/` on its own, from the
working directory upwards, so the samples run with nothing set. A process
loads the library once; `Library_Path` tells which. On Linux, install the udev
rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- `Context` and `Dongle` are limited controlled types: they close themselves
  when they go out of scope, and a context closes the dongles still open on
  it. `Close` is there for closing earlier.
- Results are plain records (`Info`, `Genuine_Result`, `Device_Info`,
  `Record_Info`); bytes are `Ada.Streams.Stream_Element_Array` (`Bytes`), with
  `To_Bytes`/`To_String` for text.
- Failures raise `License_Dongle_Error`, or one of `No_Device_Error`,
  `Not_Genuine_Error`, `Certificate_Invalid_Error`, `Session_Expired_Error`,
  `Not_Found_Error`, `Auth_Required_Error`, `Cancelled_Error`, with a message of
  the form `licd_open: no device (detail)`; `Last_Status` gives the code behind
  the most recent one. Loading problems raise `Library_Error`.
- `Is_Genuine (D)` is the non-raising form for a gate and **fails closed**.
- Sessions live on the dongle: `Session_Open`, then records, counters and
  app-crypto, then `Session_Close`.
- `Read_Record` and `Write_Record` take a `Progress_Callback`
  (`function (Done, Total : Natural) return Boolean`); returning `False`
  cancels. An exception raised inside cancels the transfer and is re-raised
  after the C frames have unwound, never through them.
- `Erase_All_Records` is deliberately separate from `Erase_Record`: to the C
  library a null name means "erase every record", and an accidentally empty
  string must not do that.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if not Is_Genuine (D) then raise ...` compiles to
> one conditional branch, and patching one of those in a release binary is a
> beginner exercise. Route something the program needs through
> `App_Encrypt`/`App_Decrypt`, so removing the check removes the data.

## Tests

`sh tests/run.sh` (with `alr`, `gprbuild` and a C compiler on the path) builds
the crate, compiles a stand-in for the C ABI from the SDK's
`bindings/julia/test/stub/licd_stub.c` and runs every call against it, without
a dongle.

## Links

- [KeyNub License Dongle for Ada](https://www.keynub.com/developers/ada/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
