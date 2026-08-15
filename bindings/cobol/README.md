# KeyNub License Dongle — COBOL binding

COBOL calls the KeyNub dongle through the SDK's
[flat companion API](../flat/README.md) — plain C functions with integer handles,
caller-provided buffers and no callbacks, which is exactly the subset COBOL's
`CALL` can express. The binding is a copybook:
[`KEYNUB.cpy`](KEYNUB.cpy), holding the status codes, the flag bits and working
storage with the right picture clauses.

```cobol
       WORKING-STORAGE SECTION.
       COPY KEYNUB.

       PROCEDURE DIVISION.
           MOVE 0 TO KN-HANDLE
           CALL "licdf_open" USING BY REFERENCE WS-SERIAL
                RETURNING KN-HANDLE
           IF KN-HANDLE NOT > 0
               DISPLAY "no KeyNub dongle attached"
               MOVE 16 TO RETURN-CODE
               STOP RUN
           END-IF

           CALL "licdf_verify_genuine" USING BY VALUE KN-HANDLE
                                             BY REFERENCE KN-GENUINE
                                             BY REFERENCE KN-SERIAL
                                             BY VALUE KEYNUB-SERIAL-SIZE
                                             BY REFERENCE KN-PROV-DATE
                                             BY VALUE KEYNUB-DATE-SIZE
                RETURNING KN-STATUS
```

Verified with **GnuCOBOL 3.2**. The calling conventions are the ones IBM Enterprise
COBOL and Micro Focus use for C interop, so those should work unchanged, but they
have not been tried here.

## Calling conventions

| C parameter | COBOL |
| --- | --- |
| `int32_t` in | `BY VALUE` a `PIC S9(9) COMP-5` item |
| `int32_t *` out | `BY REFERENCE` a `PIC S9(9) COMP-5` item |
| `const char *` | `BY REFERENCE` a NUL-terminated `PIC X` item — `VALUE Z"lic"` |
| `char *` out | `BY REFERENCE` a `PIC X(n)`, with `n` `BY VALUE` |
| `uint8_t *` | `BY REFERENCE` a `PIC X(n)`, with `n` `BY VALUE` |
| return value | `RETURNING` a `PIC S9(9) COMP-5` item |

**Use `COMP-5`, not `COMP`.** Under GnuCOBOL's default dialect the two coincide for
values this small, so a mistake will not show up in testing — but `COMP` is
dialect-defined, and under an IBM or Micro Focus dialect it is big-endian and
decimal-truncated, which hands C the wrong bytes.

Getting `BY VALUE` and `BY REFERENCE` the wrong way round *does* fail immediately,
which is the mistake worth being careful about. This binding has a deliberate
control for it.

Every call returns zero on success or a negative status; `licdf_open` is the
exception and returns a positive handle. `licdf_strerror` turns a status into text
and needs no handle.

## Linking, or rather not

Nothing is linked at compile time. GnuCOBOL resolves `CALL "licdf_..."` by name at
run time out of the libraries named in `COB_PRE_LOAD`:

```
cobc -x -free myprogram.cob
COB_PRE_LOAD=libkeynub_licdongle_flat COB_LIBRARY_PATH=/path/to/lib ./myprogram
```

That is the whole deployment story, and it avoids per-platform link flags and
rpath handling. The preload name is the library's file name without its
extension — `libkeynub_licdongle_flat` where the platform adds a `lib` prefix,
`keynub_licdongle_flat` where it does not.

A note for Windows: a MinGW GnuCOBOL is usually built against **MSVCRT** while a
current MinGW-w64 is **UCRT**, and the two cannot be linked together. Loading the
library at run time is unaffected, because the flat API never hands back memory
the caller has to free — no allocation crosses between the two C runtimes.

## Where the licence check goes

The natural COBOL reflex is

```cobol
           IF KN-GENUINE NOT = 1
               DISPLAY "unlicensed"
               STOP RUN            *> <- one line for someone to remove
           END-IF
```

which protects nothing. `licdf_app_decrypt` cannot be removed the same way,
because without a genuine dongle it returns no data. Encrypt whatever the program
cannot run without — a rate table, a fee schedule, the parameters of a calculation
— once with `licdf_app_encrypt` and `KEYNUB-SCOPE-DEVELOPER` when you issue the
licence, ship the blob, and decrypt at run time.

See [`../../docs/integration-security.md`](../../docs/integration-security.md).
