#lang racket/base
;; KeyNub License Dongle: verify that a dongle is genuine, read and write the
;; license records it holds, use its hardware counters and encrypt data so
;; that only a dongle can decrypt it. Calls the SDK's flat C API through a
;; library loaded at run time (see private/library.rkt); nothing is linked.
(require racket/contract/base
         (only-in ffi/unsafe register-finalizer)
         "licdongle/private/common.rkt"
         "licdongle/private/library.rkt")

(define int32/c (integer-in -2147483648 2147483647))
(define scope/c (or/c 'device 'developer))

(provide
 with-dongle
 with-session
 (struct-out exn:fail:keynub)
 (struct-out exn:fail:keynub:library)
 (contract-out
  ;; the library
  [library-environment-variable string?]
  [library-basename (-> string?)]
  [library-candidates (-> (listof string?))]
  [set-library-path! (-> path-string? void?)]
  [library-path (-> string?)]
  [loaded-library-path (-> (or/c string? #f))]
  [struct lib-version ([major exact-integer?] [minor exact-integer?] [patch exact-integer?])]
  [library-version (-> lib-version?)]
  ;; status codes
  [status-symbol (-> exact-integer? (or/c symbol? #f))]
  [status-code (-> symbol? (or/c exact-integer? #f))]
  [status-text (-> int32/c string?)]
  ;; discovery and opening
  [struct device ([serial string?] [path string?])]
  [devices (-> (listof device?))]
  [dongle? (-> any/c boolean?)]
  [dongle-open (->* () ((or/c string? #f)) dongle?)]
  [dongle-open-path (-> string? dongle?)]
  [dongle-close (-> dongle? void?)]
  [dongle-open? (-> dongle? boolean?)]
  [call-with-dongle (->* ((-> dongle? any))
                         (#:serial (or/c string? #f) #:path (or/c string? #f))
                         any)]
  ;; plaintext information and authenticity
  [dongle-serial (-> dongle? string?)]
  [struct device-info ([protocol-major exact-integer?]
                       [protocol-minor exact-integer?]
                       [firmware-major exact-integer?]
                       [firmware-minor exact-integer?]
                       [firmware-patch exact-integer?]
                       [secure-element-ready? boolean?]
                       [provisioned? boolean?]
                       [watchdog-reboot? boolean?]
                       [isolated? boolean?]
                       [write-auth-rotated? boolean?]
                       [data-capacity exact-integer?]
                       [data-free exact-integer?])]
  [dongle-info (-> dongle? device-info?)]
  [struct verification ([serial string?] [provisioned-date string?])]
  [dongle-verify-genuine (-> dongle? verification?)]
  [dongle-genuine? (-> dongle? boolean?)]
  [set-dongle-trust-root! (-> dongle? bytes? void?)]
  [dongle-last-error (-> dongle? string?)]
  ;; sessions and the write role
  [session-open (-> dongle? void?)]
  [session-close (-> dongle? void?)]
  [call-with-session (-> dongle? (-> any) any)]
  [authorize-write (-> dongle? bytes? void?)]
  [rotate-write-key (-> dongle? bytes? void?)]
  ;; records
  [struct record ([name string?] [size exact-integer?])]
  [dongle-records (-> dongle? (listof record?))]
  [read-record (-> dongle? string? bytes?)]
  [write-record! (-> dongle? string? bytes? void?)]
  [erase-record! (-> dongle? string? void?)]
  [erase-all-records! (-> dongle? void?)]
  ;; counters
  [read-counter (-> dongle? int32/c exact-integer?)]
  [increment-counter! (-> dongle? int32/c exact-integer?)]
  ;; app-data encryption
  [app-encrypt (-> dongle? scope/c bytes? bytes?)]
  [app-decrypt (-> dongle? bytes? bytes?)]))

;; Buffer sizes (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE, LICDF_PATH_SIZE,
;; LICDF_ERROR_SIZE), and one for a record name.
(define serial-size 15)
(define date-size 11)
(define path-size 512)
(define error-size 256)
(define name-size 256)

;; Bits in the flags value of licdf_get_info.
(define flag-secure-element-ready #x01)
(define flag-provisioned #x02)
(define flag-watchdog-reboot #x04)
(define flag-isolated #x08)
(define flag-write-auth-rotated #x10)

;; The native library's version.
(struct lib-version (major minor patch) #:transparent)

;; An attached dongle.
(struct device (serial path) #:transparent)

;; Plaintext device information.
(struct device-info
  (protocol-major protocol-minor
   firmware-major firmware-minor firmware-patch
   secure-element-ready? provisioned? watchdog-reboot? isolated? write-auth-rotated?
   data-capacity data-free)
  #:transparent)

;; The result of a successful dongle-verify-genuine.
(struct verification (serial provisioned-date) #:transparent)

;; A record on the dongle.
(struct record (name size) #:transparent)

;; An open dongle: the flat API's handle, 0 once closed.
(struct dongle ([handle #:mutable])
  #:property prop:custom-write
  (lambda (d port mode)
    (write-string (if (> (dongle-handle d) 0) "#<dongle>" "#<dongle:closed>") port)))

;; ---- helpers ------------------------------------------------------------

(define (check operation handle rc)
  (unless (zero? rc)
    (raise (make-keynub-error operation rc (if (> handle 0) (detail-of handle) "")))))

(define (detail-of handle)
  (with-handlers ([exn:fail? (lambda (e) "")])
    (define text (make-bytes error-size 0))
    (if (zero? ((flat 'licdf_last_error) handle text error-size))
        (c-string text)
        "")))

;; A buffer the library can read even for empty data.
(define (pointer-of data)
  (if (zero? (bytes-length data)) (make-bytes 1 0) data))

(define (length-of data)
  (define n (bytes-length data))
  (when (> n 2147483647)
    (raise (make-keynub-error "argument" (status-code 'invalid-arg) "more than 2 GiB of data")))
  n)

;; The two-call convention: ask for the size with a capacity of 0, then read
;; into a buffer of that size. `call` takes the buffer and its capacity and
;; returns the status and the length.
(define (read-sized d operation call)
  (define-values (rc needed) (call (make-bytes 1 0) 0))
  (cond
    [(zero? rc) (make-bytes 0)]
    [(not (= rc (status-code 'range)))
     (raise (make-keynub-error operation rc (dongle-last-error d)))]
    [else
     (define data (make-bytes (max needed 1) 0))
     (define-values (rc2 written) (call data needed))
     (unless (zero? rc2)
       (raise (make-keynub-error operation rc2 (dongle-last-error d))))
     (subbytes data 0 written)]))

;; ---- the library and status codes ---------------------------------------

;; The native library's version.
(define (library-version)
  (define-values (rc major minor patch) ((flat 'licdf_version)))
  (check "licdf_version" 0 rc)
  (lib-version major minor patch))

;; Human-readable text for a status code; needs no dongle.
(define (status-text code)
  (define text (make-bytes error-size 0))
  (if (zero? ((flat 'licdf_strerror) code text error-size))
      (c-string text)
      (symbol->string (or (status-symbol code) 'unknown))))

;; ---- discovery and opening ----------------------------------------------

;; The attached dongles.
(define (devices)
  (define-values (rc count) ((flat 'licdf_device_count)))
  (check "licdf_device_count" 0 rc)
  (for/list ([i (in-range count)])
    (define text (make-bytes path-size 0))
    (check "licdf_device_serial" 0 ((flat 'licdf_device_serial) i text path-size))
    (define serial (c-string text))
    (check "licdf_device_path" 0 ((flat 'licdf_device_path) i text path-size))
    (device serial (c-string text))))

(define (make-dongle handle)
  (define d (dongle handle))
  (register-finalizer d close-quietly)
  d)

;; Opens the dongle with this serial, or the first one found when `serial` is
;; #f or empty.
(define (dongle-open [serial #f])
  (define handle ((flat 'licdf_open) (or serial "")))
  (when (< handle 0)
    (raise (make-keynub-error "licdf_open" handle)))
  (make-dongle handle))

;; Opens the dongle at this device path (from `devices`).
(define (dongle-open-path path)
  (define handle ((flat 'licdf_open_path) path))
  (when (< handle 0)
    (raise (make-keynub-error "licdf_open_path" handle)))
  (make-dongle handle))

;; Whether dongle-close has not been called yet.
(define (dongle-open? d)
  (> (dongle-handle d) 0))

;; Closes the dongle. Further calls fail with 'invalid-arg.
(define (dongle-close d)
  (define handle (dongle-handle d))
  (when (> handle 0)
    (set-dongle-handle! d 0)
    (check "licdf_close" handle ((flat 'licdf_close) handle))))

(define (close-quietly d)
  (with-handlers ([exn:fail? void])
    (dongle-close d)))

;; Opens the dongle (the first one, the one with #:serial or the one at
;; #:path), calls `proc` with it and closes it on every exit path. Returns
;; what `proc` returns.
(define (call-with-dongle proc #:serial [serial #f] #:path [path #f])
  (when (and serial path)
    (raise-arguments-error 'call-with-dongle "give #:serial or #:path, not both"
                           "serial" serial "path" path))
  (define d (if path (dongle-open-path path) (dongle-open serial)))
  (dynamic-wind
   void
   (lambda () (proc d))
   (lambda () (close-quietly d))))

;; (with-dongle (id) body ...), (with-dongle (id #:serial serial) body ...) or
;; (with-dongle (id #:path path) body ...): call-with-dongle with the body.
(define-syntax with-dongle
  (syntax-rules ()
    [(_ (id #:serial serial) body0 body ...)
     (call-with-dongle #:serial serial (lambda (id) body0 body ...))]
    [(_ (id #:path path) body0 body ...)
     (call-with-dongle #:path path (lambda (id) body0 body ...))]
    [(_ (id) body0 body ...)
     (call-with-dongle (lambda (id) body0 body ...))]))

;; ---- plaintext information and authenticity ----------------------------

;; The dongle's serial number (14 hex digits).
(define (dongle-serial d)
  (define text (make-bytes serial-size 0))
  (check "licdf_get_serial" (dongle-handle d)
         ((flat 'licdf_get_serial) (dongle-handle d) text serial-size))
  (c-string text))

;; Plaintext device information.
(define (dongle-info d)
  (define-values (rc pa pb fa fb fc flags capacity free)
    ((flat 'licdf_get_info) (dongle-handle d)))
  (check "licdf_get_info" (dongle-handle d) rc)
  (define (flag? bit) (not (zero? (bitwise-and flags bit))))
  (device-info pa pb fa fb fc
               (flag? flag-secure-element-ready)
               (flag? flag-provisioned)
               (flag? flag-watchdog-reboot)
               (flag? flag-isolated)
               (flag? flag-write-auth-rotated)
               capacity free))

;; Proves the dongle is genuine: certificate chain to the trusted root plus a
;; live challenge-response. Returns only when it is; raises otherwise.
(define (dongle-verify-genuine d)
  (define serial-text (make-bytes serial-size 0))
  (define date-text (make-bytes date-size 0))
  (define-values (rc genuine)
    ((flat 'licdf_verify_genuine) (dongle-handle d) serial-text serial-size date-text date-size))
  (check "licdf_verify_genuine" (dongle-handle d) rc)
  (when (zero? genuine)
    (raise (make-keynub-error "licdf_verify_genuine" (status-code 'not-genuine))))
  (verification (c-string serial-text) (c-string date-text)))

;; The boolean form for a gate: #t only when dongle-verify-genuine succeeds.
;; Fails closed: every failure gives #f.
(define (dongle-genuine? d)
  (with-handlers ([(lambda (e) (not (exn:break? e))) (lambda (e) #f)])
    (dongle-verify-genuine d)
    #t))

;; Overrides the CA root that dongle-verify-genuine checks against (DER).
(define (set-dongle-trust-root! d der)
  (check "licdf_set_trust_root" (dongle-handle d)
         ((flat 'licdf_set_trust_root) (dongle-handle d) (pointer-of der) (length-of der))))

;; Diagnostic detail for the most recent failure on this dongle; may be empty.
(define (dongle-last-error d)
  (detail-of (dongle-handle d)))

;; ---- sessions and the write role ----------------------------------------

;; Opens an authenticated session; records, counters and app crypto need one.
(define (session-open d)
  (check "licdf_session_open" (dongle-handle d) ((flat 'licdf_session_open) (dongle-handle d))))

;; Closes the session.
(define (session-close d)
  (check "licdf_session_close" (dongle-handle d) ((flat 'licdf_session_close) (dongle-handle d))))

;; Opens a session, calls `thunk` and closes the session on every exit path.
;; Returns what `thunk` returns.
(define (call-with-session d thunk)
  (session-open d)
  (dynamic-wind
   void
   thunk
   (lambda ()
     (with-handlers ([exn:fail? void])
       (session-close d)))))

;; (with-session d body ...): call-with-session with the body.
(define-syntax-rule (with-session d body0 body ...)
  (call-with-session d (lambda () body0 body ...)))

;; Elevates the session to the write role with a write-auth key (P-256 PKCS#8
;; DER).
(define (authorize-write d key)
  (check "licdf_write_auth" (dongle-handle d)
         ((flat 'licdf_write_auth) (dongle-handle d) (pointer-of key) (length-of key))))

;; Replaces the dongle's write-auth key with `key` (P-256 PKCS#8 DER). Call
;; authorize-write first. From the next session on, only the new key
;; elevates.
(define (rotate-write-key d key)
  (check "licdf_write_auth_rotate" (dongle-handle d)
         ((flat 'licdf_write_auth_rotate) (dongle-handle d) (pointer-of key) (length-of key))))

;; ---- records ------------------------------------------------------------

;; The records on the dongle.
(define (dongle-records d)
  (define handle (dongle-handle d))
  (define-values (rc count) ((flat 'licdf_record_count) handle))
  (check "licdf_record_count" handle rc)
  (for/list ([i (in-range count)])
    (define text (make-bytes name-size 0))
    (define-values (rc2 size) ((flat 'licdf_record_name) handle i text name-size))
    (check "licdf_record_name" handle rc2)
    (record (c-string text) size)))

;; The content of a record.
(define (read-record d name)
  (define handle (dongle-handle d))
  (read-sized d "licdf_record_read"
              (lambda (data capacity)
                ((flat 'licdf_record_read) handle name data capacity))))

;; Writes a record, replacing one of the same name. Needs the write role.
(define (write-record! d name data)
  (check "licdf_record_write" (dongle-handle d)
         ((flat 'licdf_record_write) (dongle-handle d) name (pointer-of data) (length-of data))))

;; Erases one record. Needs the write role.
(define (erase-record! d name)
  (check "licdf_record_erase" (dongle-handle d)
         ((flat 'licdf_record_erase) (dongle-handle d) name)))

;; Erases every record. Needs the write role.
(define (erase-all-records! d)
  (check "licdf_record_erase_all" (dongle-handle d)
         ((flat 'licdf_record_erase_all) (dongle-handle d))))

;; ---- counters -----------------------------------------------------------

;; The value of a hardware monotonic counter.
(define (read-counter d counter-id)
  (define-values (rc value) ((flat 'licdf_counter_read) (dongle-handle d) counter-id))
  (check "licdf_counter_read" (dongle-handle d) rc)
  value)

;; Increments a counter and returns the new value. Needs the write role.
(define (increment-counter! d counter-id)
  (define-values (rc value) ((flat 'licdf_counter_increment) (dongle-handle d) counter-id))
  (check "licdf_counter_increment" (dongle-handle d) rc)
  value)

;; ---- app-data encryption ------------------------------------------------

;; Seals data so that only a dongle can open it: this one ('device) or any
;; dongle issued by the same developer ('developer).
(define (app-encrypt d scope plaintext)
  (define handle (dongle-handle d))
  (define input-length (length-of plaintext))
  (define input (pointer-of plaintext))
  (define scope-value (if (eq? scope 'device) 0 1))
  (read-sized d "licdf_app_encrypt"
              (lambda (data capacity)
                ((flat 'licdf_app_encrypt) handle scope-value input input-length data capacity))))

;; Opens data sealed with app-encrypt.
(define (app-decrypt d packed)
  (define handle (dongle-handle d))
  (define input-length (length-of packed))
  (define input (pointer-of packed))
  (read-sized d "licdf_app_decrypt"
              (lambda (data capacity)
                ((flat 'licdf_app_decrypt) handle input input-length data capacity))))
