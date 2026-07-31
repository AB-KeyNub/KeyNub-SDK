      *>****************************************************************
      *> KEYNUB.cpy - KeyNub License Dongle SDK, COBOL copybook.
      *>
      *> Status codes, flag bits and the field definitions for calling the
      *> SDK's flat companion API (bindings/flat/licd_flat.h) from COBOL.
      *> The flat API exists for callers like this one: integer handles
      *> instead of opaque pointers, caller-provided buffers instead of
      *> library-allocated ones, and no callbacks anywhere.
      *>
      *>     COPY KEYNUB.
      *>
      *> Calling conventions (GnuCOBOL; the same shape for IBM COBOL and
      *> Micro Focus, whose CALL syntax for C is compatible):
      *>
      *>   int32_t  in   BY VALUE     a PIC S9(9) COMP-5 item
      *>   int32_t* out  BY REFERENCE a PIC S9(9) COMP-5 item
      *>   char*    in   BY REFERENCE a NUL-terminated PIC X item, e.g.
      *>                              VALUE Z"lic", or MOVE plus X"00"
      *>   char*    out  BY REFERENCE a PIC X(n) item, with n BY VALUE
      *>   uint8_t* both BY REFERENCE a PIC X(n) item, with n BY VALUE
      *>   returns       RETURNING    a PIC S9(9) COMP-5 item
      *>
      *> Use COMP-5 (native binary, no decimal truncation), not COMP. Under
      *> GnuCOBOL's default dialect the two happen to coincide for values
      *> this small, so a mistake here will not show up in testing - but
      *> COMP is dialect-defined, and under an IBM or Micro Focus dialect
      *> it is big-endian and decimal-truncated, which hands C the wrong
      *> bytes. COMP-5 means the same thing everywhere.
      *>
      *> Every call returns zero on success, otherwise a negative status.
      *> licdf_open is the exception and returns a positive handle.
      *>
      *> Read docs/integration-security.md before deciding where the
      *> check goes: a paragraph that STOP RUNs on a flag is one line for
      *> someone to remove. Put data the program needs through
      *> licdf_app_encrypt / licdf_app_decrypt instead.
      *>****************************************************************

      *>--- status codes ----------------------------------------------
       78  LICD-OK                      VALUE 0.
       78  LICD-E-INVALID-ARG           VALUE -1.
       78  LICD-E-NO-DEVICE             VALUE -2.
       78  LICD-E-ACCESS-DENIED         VALUE -3.
       78  LICD-E-IO                    VALUE -4.
       78  LICD-E-TIMEOUT               VALUE -5.
       78  LICD-E-PROTOCOL              VALUE -6.
       78  LICD-E-NOT-GENUINE           VALUE -7.
       78  LICD-E-CERT-INVALID          VALUE -8.
       78  LICD-E-SESSION-EXPIRED       VALUE -9.
       78  LICD-E-TAG-MISMATCH          VALUE -10.
       78  LICD-E-RANGE                 VALUE -11.
       78  LICD-E-STORAGE-FULL          VALUE -12.
       78  LICD-E-BUSY                  VALUE -13.
       78  LICD-E-NOT-FOUND             VALUE -14.
       78  LICD-E-AUTH-REQUIRED         VALUE -15.
       78  LICD-E-FW-INCOMPATIBLE       VALUE -16.
       78  LICD-E-SDK-TOO-OLD           VALUE -17.
       78  LICD-E-CANCELLED             VALUE -18.
       78  LICD-E-NOT-IMPLEMENTED       VALUE -19.
       78  LICD-E-INTERNAL              VALUE -20.

      *>--- flag bits in the licdf-get-info bitmask --------------------
       78  LICDF-FLAG-SE-READY          VALUE 1.
       78  LICDF-FLAG-PROVISIONED       VALUE 2.
       78  LICDF-FLAG-WATCHDOG-REBOOT   VALUE 4.
       78  LICDF-FLAG-ISOLATED          VALUE 8.

      *>--- app-crypto scopes -----------------------------------------
      *> DEVICE: only this one physical dongle can decrypt.
      *> DEVELOPER: any dongle from the same batch, so one encrypted file
      *> ships to every customer.
       78  KEYNUB-SCOPE-DEVICE          VALUE 0.
       78  KEYNUB-SCOPE-DEVELOPER       VALUE 1.

      *>--- buffer sizes ----------------------------------------------
       78  KEYNUB-SERIAL-SIZE           VALUE 19.
       78  KEYNUB-PATH-SIZE             VALUE 512.
       78  KEYNUB-BATCH-SIZE            VALUE 64.
       78  KEYNUB-ERROR-SIZE            VALUE 256.

      *>--- working storage for the common calls -----------------------
      *> Include this once; the names are prefixed KN- to keep them out
      *> of the way of your own data division.
       01  KN-HANDLE                    PIC S9(9) COMP-5 VALUE 0.
       01  KN-STATUS                    PIC S9(9) COMP-5 VALUE 0.
       01  KN-GENUINE                   PIC S9(9) COMP-5 VALUE 0.
       01  KN-COUNT                     PIC S9(9) COMP-5 VALUE 0.
       01  KN-LENGTH                    PIC S9(9) COMP-5 VALUE 0.
       01  KN-NEEDED                    PIC S9(9) COMP-5 VALUE 0.
       01  KN-VALUE                     PIC S9(9) COMP-5 VALUE 0.
       01  KN-SERIAL                    PIC X(19) VALUE SPACES.
       01  KN-BATCH                     PIC X(64) VALUE SPACES.
       01  KN-ERROR-TEXT                PIC X(256) VALUE SPACES.

      *> licdf-get-info out-parameters, in call order.
       01  KN-INFO.
           05  KN-PROTO-MAJOR           PIC S9(9) COMP-5 VALUE 0.
           05  KN-PROTO-MINOR           PIC S9(9) COMP-5 VALUE 0.
           05  KN-FW-MAJOR              PIC S9(9) COMP-5 VALUE 0.
           05  KN-FW-MINOR              PIC S9(9) COMP-5 VALUE 0.
           05  KN-FW-PATCH              PIC S9(9) COMP-5 VALUE 0.
           05  KN-FLAGS                 PIC S9(9) COMP-5 VALUE 0.
           05  KN-CAPACITY              PIC S9(9) COMP-5 VALUE 0.
           05  KN-FREE-BYTES            PIC S9(9) COMP-5 VALUE 0.
