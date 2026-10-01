#lang racket/base
;; KeyNub SDK - Racket sample: verify a dongle and read what it holds.
;;
;;     racket samples/racket/verify-and-read.rkt      (from the repository root)
;;
;; Targets real hardware: with no dongle attached it prints guidance and exits 0.
;; In your own project, after `raco pkg install keynub-licdongle`:
;; (require keynub/licdongle)
(require racket/format
         "../../bindings/racket/licdongle.rkt")

(define (report d)
  (define i (dongle-info d))
  (printf "Protocol v~a.~a, firmware v~a.~a.~a, ~a of ~a bytes free.\n"
          (device-info-protocol-major i) (device-info-protocol-minor i)
          (device-info-firmware-major i) (device-info-firmware-minor i)
          (device-info-firmware-patch i)
          (device-info-data-free i) (device-info-data-capacity i))
  ;; The only trace a firmware hang leaves behind. Report it to support.
  (when (device-info-watchdog-reboot? i)
    (displayln "WARNING: this dongle's previous boot ended in a watchdog reset."))
  (define g (dongle-verify-genuine d))
  (printf "Genuine: yes (serial ~a, provisioned ~a)\n"
          (verification-serial g) (verification-provisioned-date g)))

(define (read-records d)
  (define recs (dongle-records d))
  (printf "~a record(s) on the dongle:\n" (length recs))
  (for ([r (in-list recs)])
    (printf "  ~a ~a bytes\n" (~a (record-name r) #:min-width 16) (record-size r)))
  ;; A missing record is a normal state, not an error.
  (when (for/or ([r (in-list recs)]) (equal? (record-name r) "license"))
    (printf "Read ~a bytes from the license record.\n"
            (bytes-length (read-record d "license")))))

;; The part that protects something. At licence-issue time you would call
;; app-encrypt once, with a developer dongle, and ship only the sealed data;
;; the program then cannot proceed without a dongle, because it holds no other
;; copy. 'developer lets any dongle you have issued decrypt it, so one file
;; serves every customer; 'device locks it to one dongle.
(define (protect-something d)
  (define needed (string->bytes/utf-8 "the data this program cannot run without"))
  (define sealed (app-encrypt d 'developer needed))
  (define recovered (app-decrypt d sealed))
  (printf "App-crypto round trip: ~a bytes -> ~a sealed -> ~a\n"
          (bytes-length needed) (bytes-length sealed)
          (if (equal? recovered needed) "recovered intact" "MISMATCH")))

(define (keynub-failure? e)
  (or (exn:fail:keynub? e) (exn:fail:keynub:library? e)))

(module+ main
  (with-handlers ([keynub-failure?
                   (lambda (e)
                     (printf "KeyNub error: ~a\n" (exn-message e))
                     (exit 1))])
    (define v (library-version))
    (printf "KeyNub library v~a.~a.~a\n" (lib-version-major v) (lib-version-minor v) (lib-version-patch v))
    (cond
      [(null? (devices))
       (displayln "Connect a KeyNub dongle and re-run.")
       (exit 0)]
      [else
       (with-dongle (d) ; first dongle, or (with-dongle (d #:serial "...") ...)
         (report d)
         (with-session d ; closed on every exit path
           (read-records d)
           (protect-something d)))])))
