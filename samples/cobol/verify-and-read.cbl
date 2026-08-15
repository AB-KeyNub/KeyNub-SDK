      *>****************************************************************
      *> KeyNub dongle check from COBOL: enumerate -> open -> verify ->
      *> session -> read a record -> app-crypto round trip.
      *>
      *>   cobc -x -I ../../bindings/cobol verify-and-read.cbl
      *>   COB_PRE_LOAD=libkeynub_licdongle_flat \
      *>     COB_LIBRARY_PATH=<native dir> ./verify-and-read
      *>
      *> GnuCOBOL resolves CALL targets at run time through libcob rather
      *> than at link time, so the library is named in COB_PRE_LOAD - the
      *> file name without its prefix or extension - and found through
      *> COB_LIBRARY_PATH. Linking it into the executable is not enough;
      *> the failure is "module 'licdf_version' not found" at run time.
      *>
      *> Verified with GnuCOBOL. The CALL conventions are the ones IBM
      *> Enterprise COBOL and Micro Focus use for C interop.
      *>
      *> Targets real hardware: with no dongle attached it prints guidance
      *> and stops with RETURN-CODE 0.
      *>
      *> READ FIRST: docs/integration-security.md. This program DISPLAYs
      *> whether the dongle is genuine, which is the one thing a real
      *> licence check must not do - a displayed flag is one paragraph for
      *> someone to remove. PROTECT-SOMETHING shows the shape that
      *> actually protects something.
      *>****************************************************************
       IDENTIFICATION DIVISION.
       PROGRAM-ID. VERIFY-AND-READ.

       DATA DIVISION.
       WORKING-STORAGE SECTION.
       COPY KEYNUB.

      *> Ours, not the copybook's.
      *> DISPLAY of a COMP-5 item prints its full signed form
      *> (+0000000002), so numbers are moved into edited fields first and
      *> trimmed. This is the only reason these exist.
       01  WS-N1                 PIC Z(9)9.
       01  WS-N2                 PIC Z(9)9.
       01  WS-N3                 PIC Z(9)9.
       01  WS-SERIAL-IN          PIC X(20) VALUE Z" ".
       01  WS-INDEX              PIC S9(9) COMP-5 VALUE 0.
       01  WS-LIMIT              PIC S9(9) COMP-5 VALUE 0.
       01  WS-VMAJOR             PIC S9(9) COMP-5 VALUE 0.
       01  WS-VMINOR             PIC S9(9) COMP-5 VALUE 0.
       01  WS-VPATCH             PIC S9(9) COMP-5 VALUE 0.
       01  WS-REC-NAME           PIC X(64) VALUE SPACES.
       01  WS-REC-SIZE           PIC S9(9) COMP-5 VALUE 0.
       01  WS-LICENSE-NAME       PIC X(8)  VALUE Z"license".
       01  WS-RECORD-DATA        PIC X(512) VALUE SPACES.
       01  WS-DATA-LEN           PIC S9(9) COMP-5 VALUE 0.

      *> App-crypto buffers. The sealed blob is larger than the plaintext:
      *> it carries a nonce and an authentication tag.
       01  WS-NEEDED             PIC X(40)
           VALUE "the data this program cannot run without".
       01  WS-NEEDED-LEN         PIC S9(9) COMP-5 VALUE 39.
       01  WS-SEALED             PIC X(256) VALUE SPACES.
       01  WS-SEALED-LEN         PIC S9(9) COMP-5 VALUE 0.
       01  WS-RECOVERED          PIC X(256) VALUE SPACES.
       01  WS-RECOVERED-LEN      PIC S9(9) COMP-5 VALUE 0.

       PROCEDURE DIVISION.
       MAIN-PARAGRAPH.
           CALL "licdf_version" USING BY REFERENCE WS-VMAJOR
                                     BY REFERENCE WS-VMINOR
                                     BY REFERENCE WS-VPATCH
                RETURNING KN-STATUS
           MOVE WS-VMAJOR TO WS-N1
           MOVE WS-VMINOR TO WS-N2
           MOVE WS-VPATCH TO WS-N3
           DISPLAY "KeyNub SDK " FUNCTION TRIM(WS-N1) "."
                   FUNCTION TRIM(WS-N2) "." FUNCTION TRIM(WS-N3)

           CALL "licdf_device_count" USING BY REFERENCE KN-COUNT
                RETURNING KN-STATUS
           MOVE KN-COUNT TO WS-N1
           DISPLAY "Found " FUNCTION TRIM(WS-N1) " KeyNub dongle(s)."

           IF KN-COUNT > 0
               COMPUTE WS-LIMIT = KN-COUNT - 1
               PERFORM VARYING WS-INDEX FROM 0 BY 1
                       UNTIL WS-INDEX > WS-LIMIT
                   MOVE SPACES TO KN-SERIAL
                   CALL "licdf_device_serial"
                        USING BY VALUE WS-INDEX
                              BY REFERENCE KN-SERIAL
                              BY VALUE KEYNUB-SERIAL-SIZE
                        RETURNING KN-STATUS
                   IF KN-STATUS = LICD-OK
                       MOVE WS-INDEX TO WS-N1
                       DISPLAY "  [" FUNCTION TRIM(WS-N1) "] serial "
                               FUNCTION TRIM(KN-SERIAL)
                   END-IF
               END-PERFORM
           ELSE
               DISPLAY "No dongle attached; nothing to do."
               MOVE 0 TO RETURN-CODE
               STOP RUN
           END-IF

      *>     Zero-length serial = first dongle found.
           CALL "licdf_open" USING BY REFERENCE WS-SERIAL-IN
                RETURNING KN-HANDLE
           IF KN-HANDLE NOT > 0
               DISPLAY "Could not open a dongle."
               MOVE 1 TO RETURN-CODE
               STOP RUN
           END-IF

           PERFORM REPORT-DONGLE

           CALL "licdf_session_open" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-OK
               MOVE "session_open" TO WS-REC-NAME
               PERFORM SHOW-FAILURE
           ELSE
               PERFORM READ-RECORDS
               PERFORM PROTECT-SOMETHING
               CALL "licdf_session_close" USING BY VALUE KN-HANDLE
                    RETURNING KN-STATUS
           END-IF

           CALL "licdf_close" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           MOVE 0 TO RETURN-CODE
           STOP RUN.

       REPORT-DONGLE.
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
           IF KN-STATUS = LICD-OK
               MOVE KN-PROTO-MAJOR TO WS-N1
               MOVE KN-PROTO-MINOR TO WS-N2
               DISPLAY "Protocol v" FUNCTION TRIM(WS-N1) "."
                       FUNCTION TRIM(WS-N2)
               MOVE KN-FW-MAJOR TO WS-N1
               MOVE KN-FW-MINOR TO WS-N2
               MOVE KN-FW-PATCH TO WS-N3
               DISPLAY "Firmware v" FUNCTION TRIM(WS-N1) "."
                       FUNCTION TRIM(WS-N2) "." FUNCTION TRIM(WS-N3)
               MOVE KN-FREE-BYTES TO WS-N1
               MOVE KN-CAPACITY TO WS-N2
               DISPLAY FUNCTION TRIM(WS-N1) " of " FUNCTION TRIM(WS-N2)
                       " bytes free."
      *>         The only trace a firmware hang leaves behind.
               IF FUNCTION MOD(KN-FLAGS / LICDF-FLAG-WATCHDOG-REBOOT, 2)
                       = 1
                   DISPLAY "WARNING: previous boot ended in a watchdog "
                           "reset."
               END-IF
           END-IF

           MOVE SPACES TO KN-SERIAL
           CALL "licdf_verify_genuine" USING BY VALUE KN-HANDLE
                                            BY REFERENCE KN-GENUINE
                                            BY REFERENCE KN-SERIAL
                                            BY VALUE KEYNUB-SERIAL-SIZE
                                            BY REFERENCE KN-PROV-DATE
                                            BY VALUE KEYNUB-DATE-SIZE
                RETURNING KN-STATUS
           IF KN-STATUS = LICD-OK
               MOVE KN-GENUINE TO WS-N1
               DISPLAY "Genuine: " FUNCTION TRIM(WS-N1) " (serial "
                       FUNCTION TRIM(KN-SERIAL) ")"
           ELSE
               MOVE "verify_genuine" TO WS-REC-NAME
               PERFORM SHOW-FAILURE
           END-IF.

       READ-RECORDS.
           CALL "licdf_record_count" USING BY VALUE KN-HANDLE
                                          BY REFERENCE KN-COUNT
                RETURNING KN-STATUS
           MOVE KN-COUNT TO WS-N1
           DISPLAY FUNCTION TRIM(WS-N1) " record(s) on the dongle:"
           IF KN-COUNT > 0
               COMPUTE WS-LIMIT = KN-COUNT - 1
               PERFORM VARYING WS-INDEX FROM 0 BY 1
                       UNTIL WS-INDEX > WS-LIMIT
                   MOVE SPACES TO WS-REC-NAME
                   CALL "licdf_record_name"
                        USING BY VALUE KN-HANDLE
                              BY VALUE WS-INDEX
                              BY REFERENCE WS-REC-NAME
                              BY VALUE 64
                              BY REFERENCE WS-REC-SIZE
                        RETURNING KN-STATUS
                   IF KN-STATUS = LICD-OK
                       MOVE WS-REC-SIZE TO WS-N1
                       DISPLAY "  " FUNCTION TRIM(WS-REC-NAME)
                               " " FUNCTION TRIM(WS-N1) " bytes"
                   END-IF
               END-PERFORM
           END-IF

      *>     A missing record is a normal state, not an error.
           CALL "licdf_record_read" USING BY VALUE KN-HANDLE
                                         BY REFERENCE WS-LICENSE-NAME
                                         BY REFERENCE WS-RECORD-DATA
                                         BY VALUE 512
                                         BY REFERENCE WS-DATA-LEN
                RETURNING KN-STATUS
           IF KN-STATUS = LICD-OK
               MOVE WS-DATA-LEN TO WS-N1
               DISPLAY "Read " FUNCTION TRIM(WS-N1)
                       " bytes from the license record."
           END-IF.

      *> The part that actually protects something. At licence-issue time
      *> you would call licdf_app_encrypt once, with a developer dongle,
      *> and ship only the sealed blob; the program then cannot proceed
      *> without a dongle, because it holds no other copy of the data. For
      *> a COBOL business application that is usually the rate table, the
      *> fee schedule or the parameters of a calculation.
       PROTECT-SOMETHING.
           CALL "licdf_app_encrypt" USING BY VALUE KN-HANDLE
                                         BY VALUE KEYNUB-SCOPE-DEVELOPER
                                         BY REFERENCE WS-NEEDED
                                         BY VALUE WS-NEEDED-LEN
                                         BY REFERENCE WS-SEALED
                                         BY VALUE 256
                                         BY REFERENCE WS-SEALED-LEN
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-OK
               MOVE "app_encrypt" TO WS-REC-NAME
               PERFORM SHOW-FAILURE
               EXIT PARAGRAPH
           END-IF

           CALL "licdf_app_decrypt" USING BY VALUE KN-HANDLE
                                         BY REFERENCE WS-SEALED
                                         BY VALUE WS-SEALED-LEN
                                         BY REFERENCE WS-RECOVERED
                                         BY VALUE 256
                                         BY REFERENCE WS-RECOVERED-LEN
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-OK
               MOVE "app_decrypt" TO WS-REC-NAME
               PERFORM SHOW-FAILURE
               EXIT PARAGRAPH
           END-IF

           IF WS-RECOVERED-LEN = WS-NEEDED-LEN AND
              WS-RECOVERED(1:WS-NEEDED-LEN) =
              WS-NEEDED(1:WS-NEEDED-LEN)
               MOVE WS-NEEDED-LEN TO WS-N1
               MOVE WS-SEALED-LEN TO WS-N2
               DISPLAY "App-crypto round trip: " FUNCTION TRIM(WS-N1)
                       " bytes -> " FUNCTION TRIM(WS-N2)
                       " sealed -> recovered intact"
           ELSE
               DISPLAY "App-crypto round trip: MISMATCH"
           END-IF.

      *> licdf_last_error carries the SDK's diagnostic text, which is what
      *> tells "no dongle" from "certificate rejected".
       SHOW-FAILURE.
           MOVE SPACES TO KN-ERROR-TEXT
           CALL "licdf_last_error" USING BY VALUE KN-HANDLE
                                        BY REFERENCE KN-ERROR-TEXT
                                        BY VALUE KEYNUB-ERROR-SIZE
                RETURNING KN-VALUE
           MOVE KN-STATUS TO WS-N1
           DISPLAY "KeyNub error in " FUNCTION TRIM(WS-REC-NAME)
                   ": status " FUNCTION TRIM(WS-N1)
           DISPLAY "  detail: " FUNCTION TRIM(KN-ERROR-TEXT).
