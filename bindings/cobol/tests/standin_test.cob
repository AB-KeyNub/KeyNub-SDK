      *>****************************************************************
      *> Every call of the COBOL binding (bindings/cobol/KEYNUB.cpy)
      *> against a stand-in for the C ABI: bindings/flat/licd_flat.c over
      *> bindings/julia/test/stub/licd_stub.c, one imaginary dongle held
      *> in memory, compiled into one shared library. Nothing is linked
      *> at compile time: GnuCOBOL resolves CALL by name at run time out
      *> of the library named in COB_PRE_LOAD. Return code 0 when every
      *> check passed.
      *>
      *>   cc -shared -fPIC -DLICD_BUILD_SHARED -DLICDF_BUILD_SHARED
      *>      -Iinclude -Ibindings/flat bindings/flat/licd_flat.c
      *>      bindings/julia/test/stub/licd_stub.c -o libkeynub_flat_standin.so
      *>   cobc -x -free -Ibindings/cobol bindings/cobol/tests/standin_test.cob
      *>   COB_PRE_LOAD=libkeynub_flat_standin COB_LIBRARY_PATH=. ./standin_test
      *>****************************************************************
       IDENTIFICATION DIVISION.
       PROGRAM-ID. STANDIN-TEST.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY KEYNUB.

       78  FIXTURE-SERIAL-TEXT          VALUE "04A1B2C3D4E5F6".
      *> The date PROV_FINALIZE recorded, not the certificate notBefore.
       78  FIXTURE-PROV-TEXT            VALUE "2026-08-15".

       01  WS-FAILURES                  PIC S9(9) COMP-5 VALUE 0.
       01  WS-RECORD-NAME               PIC X(16) VALUE Z"lic".
      *> A NUL in the first byte: an empty string as far as C is concerned.
      *> Z"" is not a legal literal, and this is the case that matters — an
      *> uninitialised name must not reach licdf_record_erase.
       01  WS-EMPTY-NAME                PIC X(4)  VALUE X"00".
       01  WS-MISSING-NAME              PIC X(16) VALUE Z"nope".
       01  WS-PAYLOAD                   PIC X(23) VALUE
           "license-blob-0123456789".
       01  WS-READBACK                  PIC X(64) VALUE SPACES.
       01  WS-RECORD-SIZE               PIC S9(9) COMP-5 VALUE 0.
       01  WS-NAME-OUT                  PIC X(64) VALUE SPACES.
       01  WS-BEFORE                    PIC S9(9) COMP-5 VALUE 0.
       01  WS-AFTER                     PIC S9(9) COMP-5 VALUE 0.
       01  WS-SECRET                    PIC X(100) VALUE ALL "K".
       01  WS-BLOB                      PIC X(512) VALUE SPACES.
       01  WS-BLOB-LEN                  PIC S9(9) COMP-5 VALUE 0.
       01  WS-PLAIN                     PIC X(256) VALUE SPACES.
       01  WS-PLAIN-LEN                 PIC S9(9) COMP-5 VALUE 0.
      *> The stand-in's factory write key and a replacement for it.
       01  WS-KEY                       PIC X(5) VALUE X"3010010203".
       01  WS-KEY-LEN                   PIC S9(9) COMP-5 VALUE 5.
       01  WS-KEY2                      PIC X(6) VALUE X"301109080706".
       01  WS-KEY2-LEN                  PIC S9(9) COMP-5 VALUE 6.
       01  WS-POST-NAME                 PIC X(16) VALUE Z"post".
       01  WS-ZERO-CAP                  PIC S9(9) COMP-5 VALUE 0.
       01  WS-PROBE                     PIC X(1) VALUE SPACE.
       01  WS-MAJOR                     PIC S9(9) COMP-5 VALUE 0.
       01  WS-MINOR                     PIC S9(9) COMP-5 VALUE 0.
       01  WS-PATCH                     PIC S9(9) COMP-5 VALUE 0.
       01  WS-WHAT                      PIC X(60) VALUE SPACES.
       01  WS-OK                        PIC X VALUE "N".

       PROCEDURE DIVISION.
       MAIN-SECTION.
           CALL "licdf_version" USING BY REFERENCE WS-MAJOR
                                      BY REFERENCE WS-MINOR
                                      BY REFERENCE WS-PATCH
                RETURNING KN-STATUS
           MOVE "licdf_version" TO WS-WHAT
           PERFORM CHECK-OK
           IF WS-MAJOR NOT = 9 OR WS-MINOR NOT = 8 OR WS-PATCH NOT = 7
               MOVE "library version" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_device_count" USING BY REFERENCE KN-COUNT
                RETURNING KN-STATUS
           MOVE "licdf_device_count" TO WS-WHAT
           PERFORM CHECK-OK
           IF KN-COUNT NOT = 1
               MOVE "one device" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

      *> An empty serial opens the first dongle found.
           CALL "licdf_open" USING BY REFERENCE WS-EMPTY-NAME
                RETURNING KN-HANDLE
           IF KN-HANDLE NOT > 0
               DISPLAY "cannot open the stand-in dongle: " KN-HANDLE
               MOVE 8 TO RETURN-CODE
               STOP RUN
           END-IF

           PERFORM TEST-INFO
           PERFORM TEST-SESSION-AND-RECORDS
           PERFORM TEST-COUNTERS
           PERFORM TEST-APP-CRYPTO
           PERFORM TEST-ROTATION
           PERFORM TEST-CLEANUP

           IF WS-FAILURES = 0
               DISPLAY "keynub_licdongle: every call passed against the ABI stand-in"
               MOVE 0 TO RETURN-CODE
           ELSE
               DISPLAY WS-FAILURES " assertion(s) FAILED."
               MOVE 1 TO RETURN-CODE
           END-IF
           STOP RUN.

      *>--------------------------------------------------------------
       TEST-INFO SECTION.
           CALL "licdf_get_serial" USING BY VALUE KN-HANDLE
                                         BY REFERENCE KN-SERIAL
                                         BY VALUE KEYNUB-SERIAL-SIZE
                RETURNING KN-STATUS
           MOVE "licdf_get_serial" TO WS-WHAT
           PERFORM CHECK-OK
           IF KN-SERIAL (1:14) NOT = FIXTURE-SERIAL-TEXT
               MOVE "serial matches the fixture" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_get_info" USING BY VALUE KN-HANDLE
                                       BY REFERENCE KN-PROTO-MAJOR
                                       BY REFERENCE KN-PROTO-MINOR
                                       BY REFERENCE KN-FW-MAJOR
                                       BY REFERENCE KN-FW-MINOR
                                       BY REFERENCE KN-FW-PATCH
                                       BY REFERENCE KN-FLAGS
                                       BY REFERENCE KN-CAPACITY
                                       BY REFERENCE KN-FREE-BYTES
                RETURNING KN-STATUS
           MOVE "licdf_get_info" TO WS-WHAT
           PERFORM CHECK-OK
           IF KN-PROTO-MAJOR NOT = 1
               MOVE "protocol v1" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           IF KN-CAPACITY NOT = 1048576
               MOVE "capacity is 1 MiB" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           IF FUNCTION MOD (KN-FLAGS, 2) NOT = 1
               MOVE "secure element ready" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
      *> A healthy boot: the watchdog bit is clear rather than absent.
           IF FUNCTION MOD (FUNCTION INTEGER (KN-FLAGS / 4), 2) NOT = 0
               MOVE "no watchdog reboot" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_verify_genuine" USING BY VALUE KN-HANDLE
                                             BY REFERENCE KN-GENUINE
                                             BY REFERENCE KN-SERIAL
                                             BY VALUE KEYNUB-SERIAL-SIZE
                                             BY REFERENCE KN-PROV-DATE
                                             BY VALUE KEYNUB-DATE-SIZE
                RETURNING KN-STATUS
           MOVE "licdf_verify_genuine" TO WS-WHAT
           PERFORM CHECK-OK
           IF KN-GENUINE NOT = 1
               MOVE "the fixture dongle is genuine" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           IF KN-PROV-DATE (1:10) NOT = FIXTURE-PROV-TEXT
               MOVE "personalisation date" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           EXIT SECTION.

      *>--------------------------------------------------------------
       TEST-SESSION-AND-RECORDS SECTION.
           CALL "licdf_session_open" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           MOVE "licdf_session_open" TO WS-WHAT
           PERFORM CHECK-OK

      *> Writes need the write role first.
           CALL "licdf_record_write" USING BY VALUE KN-HANDLE
                                           BY REFERENCE WS-RECORD-NAME
                                           BY REFERENCE WS-PAYLOAD
                                           BY VALUE LENGTH OF WS-PAYLOAD
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-E-AUTH-REQUIRED
               MOVE "a write without the role is refused" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_write_auth" USING BY VALUE KN-HANDLE
                                         BY REFERENCE WS-KEY
                                         BY VALUE WS-KEY-LEN
                RETURNING KN-STATUS
           MOVE "licdf_write_auth" TO WS-WHAT
           PERFORM CHECK-OK

           CALL "licdf_record_write" USING BY VALUE KN-HANDLE
                                           BY REFERENCE WS-RECORD-NAME
                                           BY REFERENCE WS-PAYLOAD
                                           BY VALUE LENGTH OF WS-PAYLOAD
                RETURNING KN-STATUS
           MOVE "licdf_record_write" TO WS-WHAT
           PERFORM CHECK-OK

      *> The two-call size protocol: ask with no buffer, get the size.
           CALL "licdf_record_read" USING BY VALUE KN-HANDLE
                                          BY REFERENCE WS-RECORD-NAME
                                          BY REFERENCE WS-PROBE
                                          BY VALUE WS-ZERO-CAP
                                          BY REFERENCE KN-NEEDED
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-E-RANGE
               MOVE "a zero-capacity read reports RANGE" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           IF KN-NEEDED NOT = LENGTH OF WS-PAYLOAD
               MOVE "the required size is reported" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_record_read" USING BY VALUE KN-HANDLE
                                          BY REFERENCE WS-RECORD-NAME
                                          BY REFERENCE WS-READBACK
                                          BY VALUE LENGTH OF WS-READBACK
                                          BY REFERENCE KN-LENGTH
                RETURNING KN-STATUS
           MOVE "licdf_record_read" TO WS-WHAT
           PERFORM CHECK-OK
           IF KN-LENGTH NOT = LENGTH OF WS-PAYLOAD
               MOVE "record length round-trips" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           IF WS-READBACK (1:23) NOT = WS-PAYLOAD
               MOVE "record bytes round-trip" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_record_count" USING BY VALUE KN-HANDLE
                                           BY REFERENCE KN-COUNT
                RETURNING KN-STATUS
           MOVE "licdf_record_count" TO WS-WHAT
           PERFORM CHECK-OK
           IF KN-COUNT NOT = 1
               MOVE "one record stored" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_record_name" USING BY VALUE KN-HANDLE
                                          BY VALUE WS-ZERO-CAP
                                          BY REFERENCE WS-NAME-OUT
                                          BY VALUE LENGTH OF WS-NAME-OUT
                                          BY REFERENCE WS-RECORD-SIZE
                RETURNING KN-STATUS
           MOVE "licdf_record_name" TO WS-WHAT
           PERFORM CHECK-OK
           IF WS-NAME-OUT (1:3) NOT = "lic"
               MOVE "record name by index" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

      *> A missing record keeps its own status so COBOL can branch on it.
           CALL "licdf_record_read" USING BY VALUE KN-HANDLE
                                          BY REFERENCE WS-MISSING-NAME
                                          BY REFERENCE WS-READBACK
                                          BY VALUE LENGTH OF WS-READBACK
                                          BY REFERENCE KN-LENGTH
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-E-NOT-FOUND
               MOVE "a missing record reports NOT-FOUND" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

      *> An empty name must not reach the C API, where it would mean
      *> "erase every record".
           CALL "licdf_record_erase" USING BY VALUE KN-HANDLE
                                           BY REFERENCE WS-EMPTY-NAME
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-E-INVALID-ARG
               MOVE "an empty erase name is refused" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           CALL "licdf_record_count" USING BY VALUE KN-HANDLE
                                           BY REFERENCE KN-COUNT
                RETURNING KN-STATUS
           IF KN-COUNT NOT = 1
               MOVE "nothing was erased" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           EXIT SECTION.

      *>--------------------------------------------------------------
       TEST-COUNTERS SECTION.
           CALL "licdf_counter_read" USING BY VALUE KN-HANDLE
                                           BY VALUE WS-ZERO-CAP
                                           BY REFERENCE WS-BEFORE
                RETURNING KN-STATUS
           MOVE "licdf_counter_read" TO WS-WHAT
           PERFORM CHECK-OK
           CALL "licdf_counter_increment" USING BY VALUE KN-HANDLE
                                                BY VALUE WS-ZERO-CAP
                                                BY REFERENCE WS-AFTER
                RETURNING KN-STATUS
           MOVE "licdf_counter_increment" TO WS-WHAT
           PERFORM CHECK-OK
           IF WS-AFTER NOT = WS-BEFORE + 1
               MOVE "the counter advanced by one" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           EXIT SECTION.

      *>--------------------------------------------------------------
      *> The operation a real licence check should be built on: encrypt
      *> once when the licence is issued, decrypt at run time. Without a
      *> dongle there is no data, so there is no check left to remove.
       TEST-APP-CRYPTO SECTION.
           CALL "licdf_app_encrypt" USING BY VALUE KN-HANDLE
                                          BY VALUE KEYNUB-SCOPE-DEVELOPER
                                          BY REFERENCE WS-SECRET
                                          BY VALUE LENGTH OF WS-SECRET
                                          BY REFERENCE WS-BLOB
                                          BY VALUE LENGTH OF WS-BLOB
                                          BY REFERENCE WS-BLOB-LEN
                RETURNING KN-STATUS
           MOVE "licdf_app_encrypt" TO WS-WHAT
           PERFORM CHECK-OK
           IF WS-BLOB-LEN NOT > LENGTH OF WS-SECRET
               MOVE "the envelope is larger than the plaintext" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_app_decrypt" USING BY VALUE KN-HANDLE
                                          BY REFERENCE WS-BLOB
                                          BY VALUE WS-BLOB-LEN
                                          BY REFERENCE WS-PLAIN
                                          BY VALUE LENGTH OF WS-PLAIN
                                          BY REFERENCE WS-PLAIN-LEN
                RETURNING KN-STATUS
           MOVE "licdf_app_decrypt" TO WS-WHAT
           PERFORM CHECK-OK
           IF WS-PLAIN-LEN NOT = LENGTH OF WS-SECRET
               MOVE "plaintext length round-trips" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           IF WS-PLAIN (1:100) NOT = WS-SECRET
               MOVE "plaintext bytes round-trip" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

      *> Tampering is rejected rather than yielding different data.
           MOVE "Z" TO WS-BLOB (WS-BLOB-LEN:1)
           CALL "licdf_app_decrypt" USING BY VALUE KN-HANDLE
                                          BY REFERENCE WS-BLOB
                                          BY VALUE WS-BLOB-LEN
                                          BY REFERENCE WS-PLAIN
                                          BY VALUE LENGTH OF WS-PLAIN
                                          BY REFERENCE WS-PLAIN-LEN
                RETURNING KN-STATUS
           IF KN-STATUS = LICD-OK
               MOVE "a tampered envelope is rejected" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           EXIT SECTION.

      *>--------------------------------------------------------------
      *> How a dongle stops being the factory's and becomes the
      *> customer's. A fresh session first, so the refusal below is the
      *> missing role and not a leftover one.
       TEST-ROTATION SECTION.
           CALL "licdf_session_close" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           CALL "licdf_session_open" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           MOVE "session for the rotation" TO WS-WHAT
           PERFORM CHECK-OK

           CALL "licdf_write_auth_rotate" USING BY VALUE KN-HANDLE
                                                BY REFERENCE WS-KEY2
                                                BY VALUE WS-KEY2-LEN
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-E-AUTH-REQUIRED
               MOVE "rotation without the write role is refused"
                    TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_write_auth" USING BY VALUE KN-HANDLE
                                         BY REFERENCE WS-KEY
                                         BY VALUE WS-KEY-LEN
                RETURNING KN-STATUS
           MOVE "the current key elevates" TO WS-WHAT
           PERFORM CHECK-OK

           CALL "licdf_write_auth_rotate" USING BY VALUE KN-HANDLE
                                                BY REFERENCE WS-KEY2
                                                BY VALUE WS-KEY2-LEN
                RETURNING KN-STATUS
           MOVE "licdf_write_auth_rotate" TO WS-WHAT
           PERFORM CHECK-OK

      *> The role already held survives the rotation.
           CALL "licdf_record_write" USING BY VALUE KN-HANDLE
                                           BY REFERENCE WS-POST-NAME
                                           BY REFERENCE WS-PAYLOAD
                                           BY VALUE LENGTH OF WS-PAYLOAD
                RETURNING KN-STATUS
           MOVE "the session keeps the role it holds" TO WS-WHAT
           PERFORM CHECK-OK

      *> On a fresh session the old key is refused and the new one works.
      *> Without this the test would pass on a device that accepted the
      *> command and changed nothing.
           CALL "licdf_session_close" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           CALL "licdf_session_open" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           MOVE "fresh session after the rotation" TO WS-WHAT
           PERFORM CHECK-OK

           CALL "licdf_write_auth" USING BY VALUE KN-HANDLE
                                         BY REFERENCE WS-KEY
                                         BY VALUE WS-KEY-LEN
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-E-NOT-GENUINE
               MOVE "the old key no longer elevates" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_write_auth" USING BY VALUE KN-HANDLE
                                         BY REFERENCE WS-KEY2
                                         BY VALUE WS-KEY2-LEN
                RETURNING KN-STATUS
           MOVE "the new key elevates" TO WS-WHAT
           PERFORM CHECK-OK

           CALL "licdf_record_write" USING BY VALUE KN-HANDLE
                                           BY REFERENCE WS-POST-NAME
                                           BY REFERENCE WS-PAYLOAD
                                           BY VALUE LENGTH OF WS-PAYLOAD
                RETURNING KN-STATUS
           MOVE "the new key writes" TO WS-WHAT
           PERFORM CHECK-OK
           EXIT SECTION.

      *>--------------------------------------------------------------
       TEST-CLEANUP SECTION.
           CALL "licdf_record_erase_all" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           MOVE "licdf_record_erase_all" TO WS-WHAT
           PERFORM CHECK-OK
           CALL "licdf_record_count" USING BY VALUE KN-HANDLE
                                           BY REFERENCE KN-COUNT
                RETURNING KN-STATUS
           IF KN-COUNT NOT = 0
               MOVE "all records erased" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF

           CALL "licdf_session_close" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           MOVE "licdf_session_close" TO WS-WHAT
           PERFORM CHECK-OK
           CALL "licdf_close" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           MOVE "licdf_close" TO WS-WHAT
           PERFORM CHECK-OK
      *> Closing twice must be refused rather than freeing twice.
           CALL "licdf_close" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-E-INVALID-ARG
               MOVE "closing twice is refused" TO WS-WHAT
               PERFORM REPORT-FAILURE
           END-IF
           EXIT SECTION.

      *>--------------------------------------------------------------
       CHECK-OK SECTION.
           IF KN-STATUS NOT = LICD-OK
               MOVE SPACES TO KN-ERROR-TEXT
               CALL "licdf_strerror" USING BY VALUE KN-STATUS
                                           BY REFERENCE KN-ERROR-TEXT
                                           BY VALUE KEYNUB-ERROR-SIZE
               DISPLAY "FAIL: " FUNCTION TRIM (WS-WHAT) " -> "
                       KN-STATUS " " FUNCTION TRIM (KN-ERROR-TEXT)
               ADD 1 TO WS-FAILURES
           END-IF
           EXIT SECTION.

       REPORT-FAILURE SECTION.
           DISPLAY "FAIL: " FUNCTION TRIM (WS-WHAT)
           ADD 1 TO WS-FAILURES
           EXIT SECTION.

       END PROGRAM STANDIN-TEST.
