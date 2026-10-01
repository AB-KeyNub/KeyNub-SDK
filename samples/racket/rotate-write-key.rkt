#lang racket/base
;; KeyNub SDK - Racket sample: take ownership of a new dongle.
;;
;; A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
;; so that from the next session onward only your key can write records, erase
;; them or increment counters. Run it once per dongle, when it arrives.
;;
;; Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
;;
;;     openssl ecparam -name prime256v1 -genkey -noout |
;;       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
;;
;;     racket samples/racket/rotate-write-key.rkt keys/keynub-shipping-writeauth.key.der my-key.der
;;
;; Targets real hardware: with no dongle attached it prints guidance and exits 0.
;;
;; Guard the replacement key as you guard your licence-signing key. It cannot
;; be recovered from the dongle, and a unit rotated to a key you have lost has
;; to come back to be re-provisioned.
(require racket/file
         "../../bindings/racket/licdongle.rkt")

(define (failure? e)
  (or (exn:fail:keynub? e) (exn:fail:keynub:library? e) (exn:fail:filesystem? e)))

(module+ main
  (define args (current-command-line-arguments))
  (unless (= (vector-length args) 2)
    (displayln "usage: rotate-write-key <current-key.der> <new-key.der>")
    (exit 2))
  (with-handlers ([failure?
                   (lambda (e)
                     (printf "KeyNub error: ~a\n" (exn-message e))
                     (exit 1))])
    (define current (file->bytes (vector-ref args 0)))
    (define replacement (file->bytes (vector-ref args 1)))
    (cond
      [(null? (devices))
       (displayln "Connect a KeyNub dongle and re-run.")
       (exit 0)]
      [else
       (with-dongle (d)
         (printf "Dongle ~a\n" (dongle-serial d))
         (when (device-info-write-auth-rotated? (dongle-info d))
           (displayln "This dongle's write key has already been rotated away from the factory one."))
         (with-session d
           (authorize-write d current)        ; the key the dongle accepts today
           (rotate-write-key d replacement))  ; from the next session: only the new one
         (printf "Write key rotated: ~a\n"
                 (if (device-info-write-auth-rotated? (dongle-info d)) "yes" "no")))])))
