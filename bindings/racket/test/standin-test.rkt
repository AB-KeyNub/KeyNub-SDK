#lang racket/base
;; Every call of the binding against a stand-in for the flat C API: the SDK's
;; flat layer compiled together with the C ABI stand-in
;; (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
;; into one shared library, with a C compiler from the path (cc, gcc, clang,
;; zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
;; stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the
;; test does not run inside a clone. Exit code 0 when every check passed.
;;
;;     racket bindings/racket/test/standin-test.rkt      (from the repository root)
(require racket/port
         racket/system
         "../licdongle.rkt")

(module+ main
  (define SERIAL "04A1B2C3D4E5F6")
  (define FACTORY-KEY (bytes #x30 #x10 #x01 #x02 #x03))
  (define REPLACEMENT-KEY (bytes #x30 #x11 #x09 #x08 #x07 #x06))

  (define failures 0)

  (define (check condition what)
    (unless condition
      (set! failures (add1 failures))
      (printf "  FAIL  ~a\n" what)))

  (define (fails* status what thunk)
    (with-handlers ([exn:fail:keynub?
                     (lambda (e)
                       (check (eq? (exn:fail:keynub-status e) status)
                              (format "~a: ~a" what (or (exn:fail:keynub-status e) 'unknown))))])
      (thunk)
      (check #f (format "~a: no failure" what))))

  (define-syntax-rule (fails status what body ...)
    (fails* status what (lambda () body ...)))

  (define (text->bytes text)
    (string->bytes/utf-8 text))

  ;; ---- the stand-in -------------------------------------------------------

  (define windows? (eq? (system-type 'os) 'windows))

  (define (has-flat-sources? dir)
    (file-exists? (build-path dir "bindings" "flat" "licd_flat.c")))

  (define (search-upwards start)
    (let loop ([dir (simplify-path (path->complete-path start))])
      (cond
        [(has-flat-sources? dir) dir]
        [else
         (define-values (parent name dir?) (split-path dir))
         (and (path? parent) (loop parent))])))

  (define (this-folder)
    (define source (variable-reference->module-source (#%variable-reference)))
    (and (path? source)
         (let-values ([(base name dir?) (split-path source)])
           (and (path? base) base))))

  (define (sdk-root)
    (define given (getenv "KEYNUB_SDK_ROOT"))
    (cond
      [(and given (not (string=? given ""))) (string->path given)]
      [(search-upwards (current-directory)) => values]
      [(and (this-folder) (search-upwards (this-folder))) => values]
      [else
       (displayln "the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT")
       (exit 1)]))

  ;; Runs `command` with `args` in `dir`, output discarded; #t when it exited 0.
  (define (run-quietly command args dir)
    (define program (find-executable-path command))
    (and program
         (with-handlers ([exn:fail? (lambda (e) #f)])
           (parameterize ([current-directory dir]
                          [current-output-port (open-output-nowhere)]
                          [current-error-port (open-output-nowhere)]
                          [current-input-port (open-input-bytes #"")])
             (apply system* program args)))))

  (define (build-stand-in)
    (define root (sdk-root))
    (define tmp (find-system-path 'temp-dir))
    ;; A file name other than the library's own (keynub_licdongle_flat).
    (define output
      (path->string (build-path tmp (if windows? "keynub_flat_standin.dll" "libkeynub_flat_standin.so"))))
    (define include-dir
      (path->string
       (if (file-exists? (build-path root "core" "include" "licdongle.h"))
           (build-path root "core" "include")
           (build-path root "include"))))
    (define flat-dir (path->string (build-path root "bindings" "flat")))
    (define sources
      (list (path->string (build-path flat-dir "licd_flat.c"))
            (path->string (build-path root "bindings" "julia" "test" "stub" "licd_stub.c"))))
    (define gcc-args
      (append (list "-shared" "-O1" "-DLICD_BUILD_SHARED" "-DLICDF_BUILD_SHARED"
                    (string-append "-I" include-dir) (string-append "-I" flat-dir)
                    "-o" output)
              sources
              (if windows? '() '("-fPIC"))))
    (define cl-args
      (append (list "/nologo" "/LD" "/O1" "/DLICD_BUILD_SHARED" "/DLICDF_BUILD_SHARED"
                    (string-append "/I" include-dir) (string-append "/I" flat-dir)
                    (string-append "/Fe:" output))
              sources))
    (define commands
      (list (cons "cc" gcc-args)
            (cons "gcc" gcc-args)
            (cons "clang" gcc-args)
            (cons "zig" (cons "cc" gcc-args))
            (cons "cl" cl-args)))
    (or (for/first ([command (in-list commands)]
                    #:when (run-quietly (car command) (cdr command) tmp))
          output)
        (begin
          (displayln "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path")
          (exit 1))))

  (define (stand-in)
    (define given (getenv library-environment-variable))
    (if (and given (not (string=? given "")))
        given
        (build-stand-in)))

  ;; ---- the checks ---------------------------------------------------------

  (set-library-path! (stand-in))

  (check (equal? (library-version) (lib-version 9 8 7)) "library version")
  (check (equal? (status-text -2) "no device") "status text")

  (check (equal? (devices) (list (device SERIAL "stub:0"))) "devices")
  (fails 'no-device "open by unknown serial" (dongle-open "nope"))
  (fails 'no-device "open by unknown path" (dongle-open-path "stub:9"))

  (define d (dongle-open))
  (check (dongle-open? d) "open")
  (check (equal? (dongle-serial d) SERIAL) "serial")
  (define i (dongle-info d))
  (check (and (= (device-info-protocol-major i) 1) (= (device-info-protocol-minor i) 0))
         "protocol version")
  (check (and (= (device-info-firmware-major i) 2)
              (= (device-info-firmware-minor i) 3)
              (= (device-info-firmware-patch i) 4))
         "firmware version")
  (check (and (device-info-secure-element-ready? i)
              (device-info-provisioned? i)
              (device-info-isolated? i))
         "flags set")
  (check (and (not (device-info-watchdog-reboot? i)) (not (device-info-write-auth-rotated? i)))
         "flags clear")
  (check (and (= (device-info-data-capacity i) (* 1024 1024)) (= (device-info-data-free i) 1000000))
         "capacity")
  (define g (dongle-verify-genuine d))
  (check (and (equal? (verification-serial g) SERIAL)
              (equal? (verification-provisioned-date g) "2026-08-15"))
         "genuine")
  (check (dongle-genuine? d) "genuine?")

  (fails 'cert-invalid "malformed trust root" (set-dongle-trust-root! d (bytes #x02 #x01 #x00)))
  (define root (make-bytes 132 #xAB))
  (bytes-set! root 0 #x30)
  (bytes-set! root 1 #x82)
  (bytes-set! root 2 #x01)
  (bytes-set! root 3 #x00)
  (set-dongle-trust-root! d root)
  (fails 'cert-invalid "verify against a foreign root" (dongle-verify-genuine d))
  (check (not (dongle-genuine? d)) "genuine? fails closed")
  (for ([k (in-range 4 (bytes-length root))])
    (bytes-set! root k #x01))
  (set-dongle-trust-root! d root)
  (check (dongle-genuine? d) "genuine? after the right root")

  (fails 'session-expired "records without a session" (dongle-records d))
  (session-open d)
  (define payload (text->bytes "license-blob-0123456789"))
  (fails 'auth-required "write before the write role" (write-record! d "lic" payload))
  (fails 'not-genuine "write role with a bad key" (authorize-write d (bytes #x30 #x00)))
  (authorize-write d FACTORY-KEY)
  (write-record! d "lic" payload)
  (check (equal? (read-record d "lic") payload) "read back")
  (write-record! d "cfg" (text->bytes "cfgdata"))
  (define recs (dongle-records d))
  (check (equal? (sort (map record-name recs) string<?) '("cfg" "lic")) "record names")
  (check (for/or ([r (in-list recs)])
           (and (equal? (record-name r) "lic") (= (record-size r) (bytes-length payload))))
         "record size")
  (check (equal? (read-record d "cfg") (text->bytes "cfgdata")) "second record")
  (fails 'not-found "read a missing record" (read-record d "nope"))
  (fails 'invalid-arg "erase with an empty name" (erase-record! d ""))
  (check (= (length (dongle-records d)) 2) "two records")
  (erase-record! d "cfg")
  (check (equal? (map record-name (dongle-records d)) '("lic")) "one record left")
  (write-record! d "empty" (bytes))
  (check (zero? (bytes-length (read-record d "empty"))) "empty record")

  (define before (read-counter d 0))
  (check (= (increment-counter! d 0) (add1 before)) "increment")
  (check (and (= (read-counter d 0) (add1 before)) (= (read-counter d 1) 0)) "counters")
  (fails 'range "counter out of range" (read-counter d 7))

  (define secret
    (apply bytes (for/list ([k (in-range 100)]) (modulo (+ (* 3 k) 7) 256))))
  (for ([scope (in-list '(device developer))]
        [scope-value (in-list '(0 1))])
    (define blob (app-encrypt d scope secret))
    (check (> (bytes-length blob) (bytes-length secret)) (format "sealed data is longer, ~a" scope))
    (check (= (bytes-ref blob 0) scope-value) (format "scope byte, ~a" scope))
    (check (equal? (app-decrypt d blob) secret) (format "round trip, ~a" scope))
    (define tampered (bytes-copy blob))
    (define last-index (sub1 (bytes-length tampered)))
    (bytes-set! tampered last-index (bitwise-xor (bytes-ref tampered last-index) 1))
    (fails 'tag-mismatch (format "tampered blob, ~a" scope) (app-decrypt d tampered)))

  (erase-all-records! d)
  (check (null? (dongle-records d)) "erase all")

  (rotate-write-key d REPLACEMENT-KEY)
  (write-record! d "lic" (text->bytes "still-writable"))
  (session-close d)
  (check (device-info-write-auth-rotated? (dongle-info d)) "rotated flag")
  (session-open d)
  (fails 'not-genuine "factory key after rotation" (authorize-write d FACTORY-KEY))
  (authorize-write d REPLACEMENT-KEY)
  (write-record! d "lic" (text->bytes "new-key-writes"))
  (check (equal? (read-record d "lic") (text->bytes "new-key-writes")) "write with the new key")
  (session-close d)
  (dongle-close d)
  (check (not (dongle-open? d)) "closed")
  (fails 'invalid-arg "serial after close" (dongle-serial d))

  (define via-block (with-dongle (dd) (dongle-serial dd)))
  (check (equal? via-block SERIAL) "open with a block")
  ;; dongle-records needs a session, so a value back proves with-session
  ;; opened one.
  (define count
    (with-dongle (dd #:serial SERIAL)
      (with-session dd (length (dongle-records dd)))))
  (check (>= count 0) "session with a block")
  (define closed (call-with-dongle (lambda (dd) dd)))
  (check (not (dongle-open? closed)) "closed after the block")
  (check (equal? (loaded-library-path) (library-path)) "loaded path")

  (cond
    [(> failures 0)
     (printf "~a check(s) failed\n" failures)
     (exit 1)]
    [else
     (displayln "keynub_licdongle: every call passed against the ABI stand-in")]))
