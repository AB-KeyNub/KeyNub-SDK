      *>****************************************************************
      *> KeyNub SDK - COBOL sample: take ownership of a new dongle.
      *>
      *> A dongle ships holding KeyNub's write-auth key. This replaces it
      *> with yours, so that from the next session onward only your key
      *> can write records, erase them or increment counters. Run it once
      *> per dongle, when it arrives.
      *>
      *> Both keys are P-256 private keys in PKCS#8 DER. Generate yours:
      *>   openssl ecparam -name prime256v1 -genkey -noout |
      *>     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
      *>
      *>   cobc -x -I ../../bindings/cobol rotate-write-key.cbl
      *>   COB_PRE_LOAD=libkeynub_licdongle_flat \
      *>     COB_LIBRARY_PATH=<native dir> \
      *>     ./rotate-write-key ../../keys/keynub-shipping-writeauth.key.der my-key.der
      *>
      *> GnuCOBOL resolves CALL targets at run time through libcob rather
      *> than at link time, so the library is named in COB_PRE_LOAD - the
      *> file name without its prefix or extension - and found through
      *> COB_LIBRARY_PATH.
      *>
      *> The keys are read as byte streams: a DER file is binary, so it
      *> goes through LINE SEQUENTIAL's opposite, an ORGANIZATION IS
      *> SEQUENTIAL record of one byte read to the end of file.
      *>
      *> Targets real hardware: with no dongle attached it prints guidance
      *> and stops with RETURN-CODE 0.
      *>
      *> The replacement key is worth what your licence-signing key is
      *> worth. It cannot be recovered from the dongle, and a unit rotated
      *> to a key you have lost has to come back to be re-provisioned.
      *>****************************************************************
       IDENTIFICATION DIVISION.
       PROGRAM-ID. ROTATE-WRITE-KEY.

       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT KEY-FILE ASSIGN TO WS-KEY-PATH
               ORGANIZATION IS SEQUENTIAL
               RECORD DELIMITER IS BINARY-SEQUENTIAL
               FILE STATUS IS WS-FILE-STATUS.

       DATA DIVISION.
       FILE SECTION.
       FD  KEY-FILE.
       01  KEY-BYTE              PIC X.

       WORKING-STORAGE SECTION.
       COPY KEYNUB.

       01  WS-KEY-PATH           PIC X(256) VALUE SPACES.
       01  WS-FILE-STATUS        PIC XX     VALUE "00".
       01  WS-CURRENT            PIC X(4096) VALUE SPACES.
       01  WS-CURRENT-LEN        PIC S9(9) COMP-5 VALUE 0.
       01  WS-REPLACEMENT        PIC X(4096) VALUE SPACES.
       01  WS-REPLACEMENT-LEN    PIC S9(9) COMP-5 VALUE 0.
       01  WS-SCRATCH            PIC X(4096) VALUE SPACES.
       01  WS-SCRATCH-LEN        PIC S9(9) COMP-5 VALUE 0.
       01  WS-POST-NAME          PIC X(16)  VALUE Z"post".
       01  WS-ARG-COUNT          PIC S9(4) COMP-5 VALUE 0.

       PROCEDURE DIVISION.
       MAIN-SECTION.
           ACCEPT WS-ARG-COUNT FROM ARGUMENT-NUMBER
           IF WS-ARG-COUNT NOT = 2
               DISPLAY "usage: rotate-write-key <current-key.der> "
                       "<new-key.der>"
               MOVE 2 TO RETURN-CODE
               STOP RUN
           END-IF

           ACCEPT WS-KEY-PATH FROM ARGUMENT-VALUE
           PERFORM READ-KEY-FILE
           MOVE WS-SCRATCH TO WS-CURRENT
           MOVE WS-SCRATCH-LEN TO WS-CURRENT-LEN

           ACCEPT WS-KEY-PATH FROM ARGUMENT-VALUE
           PERFORM READ-KEY-FILE
           MOVE WS-SCRATCH TO WS-REPLACEMENT
           MOVE WS-SCRATCH-LEN TO WS-REPLACEMENT-LEN

           CALL "licdf_device_count" USING BY REFERENCE KN-COUNT
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-OK
               MOVE "licdf_device_count" TO KN-ERROR-TEXT
               PERFORM REPORT-AND-STOP
           END-IF
           IF KN-COUNT = 0
               DISPLAY "Connect a KeyNub dongle and re-run."
               MOVE 0 TO RETURN-CODE
               STOP RUN
           END-IF

      *> An empty serial opens the first dongle found.
           MOVE SPACES TO KN-SERIAL
           MOVE X"00" TO KN-SERIAL (1:1)
           CALL "licdf_open" USING BY REFERENCE KN-SERIAL
                RETURNING KN-HANDLE
           IF KN-HANDLE NOT > 0
               DISPLAY "cannot open a dongle: " KN-HANDLE
               MOVE 1 TO RETURN-CODE
               STOP RUN
           END-IF

           CALL "licdf_get_serial" USING BY VALUE KN-HANDLE
                                         BY REFERENCE KN-SERIAL
                                         BY VALUE KEYNUB-SERIAL-SIZE
                RETURNING KN-STATUS
           DISPLAY "dongle " KN-SERIAL (1:14)

           PERFORM ROTATE-THE-KEY
           PERFORM CONFIRM-ON-A-FRESH-SESSION

           CALL "licdf_close" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           DISPLAY " "
           DISPLAY "Keep the replacement key safe. Every future write "
                   "to this dongle needs it."
           MOVE 0 TO RETURN-CODE
           STOP RUN.

      *>--------------------------------------------------------------
       ROTATE-THE-KEY SECTION.
           CALL "licdf_session_open" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-OK
               MOVE "licdf_session_open" TO KN-ERROR-TEXT
               PERFORM REPORT-AND-STOP
           END-IF

           CALL "licdf_write_auth" USING BY VALUE KN-HANDLE
                                         BY REFERENCE WS-CURRENT
                                         BY VALUE WS-CURRENT-LEN
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-OK
               MOVE "licdf_write_auth" TO KN-ERROR-TEXT
               PERFORM REPORT-AND-STOP
           END-IF

           CALL "licdf_write_auth_rotate" USING BY VALUE KN-HANDLE
                                          BY REFERENCE WS-REPLACEMENT
                                          BY VALUE WS-REPLACEMENT-LEN
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-OK
               MOVE "licdf_write_auth_rotate" TO KN-ERROR-TEXT
               PERFORM REPORT-AND-STOP
           END-IF
           DISPLAY "rotated: this dongle now answers only to your key"

           CALL "licdf_session_close" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           EXIT SECTION.

      *>--------------------------------------------------------------
      *> A fresh session is the only place the change is observable: the
      *> session above keeps the role it was already granted.
       CONFIRM-ON-A-FRESH-SESSION SECTION.
           CALL "licdf_session_open" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-OK
               MOVE "licdf_session_open" TO KN-ERROR-TEXT
               PERFORM REPORT-AND-STOP
           END-IF

           CALL "licdf_write_auth" USING BY VALUE KN-HANDLE
                                         BY REFERENCE WS-CURRENT
                                         BY VALUE WS-CURRENT-LEN
                RETURNING KN-STATUS
           IF KN-STATUS = LICD-OK
               DISPLAY "WARNING: the old key still works - do not ship "
                       "this unit"
               MOVE 1 TO RETURN-CODE
               STOP RUN
           END-IF
           DISPLAY "confirmed: the old key no longer elevates"

           CALL "licdf_write_auth" USING BY VALUE KN-HANDLE
                                         BY REFERENCE WS-REPLACEMENT
                                         BY VALUE WS-REPLACEMENT-LEN
                RETURNING KN-STATUS
           IF KN-STATUS NOT = LICD-OK
               MOVE "licdf_write_auth" TO KN-ERROR-TEXT
               PERFORM REPORT-AND-STOP
           END-IF
           DISPLAY "confirmed: your key elevates"

           CALL "licdf_session_close" USING BY VALUE KN-HANDLE
                RETURNING KN-STATUS
           EXIT SECTION.

      *>--------------------------------------------------------------
      *> A DER file is binary: one byte per record, read to end of file.
       READ-KEY-FILE SECTION.
           MOVE SPACES TO WS-SCRATCH
           MOVE 0 TO WS-SCRATCH-LEN
           OPEN INPUT KEY-FILE
           IF WS-FILE-STATUS NOT = "00"
               DISPLAY "cannot open " FUNCTION TRIM (WS-KEY-PATH)
               MOVE 2 TO RETURN-CODE
               STOP RUN
           END-IF
           PERFORM UNTIL WS-FILE-STATUS NOT = "00"
               READ KEY-FILE
                   AT END EXIT PERFORM
               END-READ
               IF WS-FILE-STATUS = "00"
                   ADD 1 TO WS-SCRATCH-LEN
                   MOVE KEY-BYTE TO WS-SCRATCH (WS-SCRATCH-LEN:1)
               END-IF
           END-PERFORM
           CLOSE KEY-FILE
           IF WS-SCRATCH-LEN = 0
               DISPLAY FUNCTION TRIM (WS-KEY-PATH) " is empty"
               MOVE 2 TO RETURN-CODE
               STOP RUN
           END-IF
           EXIT SECTION.

      *>--------------------------------------------------------------
       REPORT-AND-STOP SECTION.
           DISPLAY "KeyNub error in " FUNCTION TRIM (KN-ERROR-TEXT)
                   ": " KN-STATUS
           MOVE SPACES TO KN-ERROR-TEXT
           CALL "licdf_strerror" USING BY VALUE KN-STATUS
                                       BY REFERENCE KN-ERROR-TEXT
                                       BY VALUE KEYNUB-ERROR-SIZE
           DISPLAY "  " FUNCTION TRIM (KN-ERROR-TEXT)
           MOVE 1 TO RETURN-CODE
           STOP RUN.

       END PROGRAM ROTATE-WRITE-KEY.
