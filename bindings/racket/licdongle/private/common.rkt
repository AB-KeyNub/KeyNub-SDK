#lang racket/base
;; The SDK's status codes, the exceptions the binding raises and the helpers
;; that turn C buffers into Racket values.
(provide status-codes
         status-symbol
         status-code
         (struct-out exn:fail:keynub)
         (struct-out exn:fail:keynub:library)
         make-keynub-error
         raise-library-error
         c-string)

;; The names of `licd_status` (core/include/licdongle.h) and their values.
(define status-codes
  '((ok . 0)
    (invalid-arg . -1)
    (no-device . -2)
    (access-denied . -3)
    (io . -4)
    (timeout . -5)
    (protocol . -6)
    (not-genuine . -7)
    (cert-invalid . -8)
    (session-expired . -9)
    (tag-mismatch . -10)
    (range . -11)
    (storage-full . -12)
    (busy . -13)
    (not-found . -14)
    (auth-required . -15)
    (fw-incompatible . -16)
    (sdk-too-old . -17)
    (cancelled . -18)
    (not-implemented . -19)
    (internal . -20)))

;; The name of a status code; #f for a code this binding does not know.
(define (status-symbol code)
  (for/first ([entry (in-list status-codes)]
              #:when (eqv? (cdr entry) code))
    (car entry)))

;; The value of a status name; #f for a name this binding does not know.
(define (status-code name)
  (cond
    [(assq name status-codes) => cdr]
    [else #f]))

;; A failed dongle call: the status name (#f for a code this binding does not
;; know), the raw code, the operation (the flat API function) and the
;; library's detail text, which may be empty.
(struct exn:fail:keynub exn:fail (status code operation detail))

;; The native library could not be loaded, or does not fit.
(struct exn:fail:keynub:library exn:fail ())

;; "operation: status (code)", followed by ": detail" when there is one.
(define (make-keynub-error operation code [detail ""])
  (define name (or (status-symbol code) 'unknown))
  (define text
    (string-append operation ": " (symbol->string name) " (" (number->string code) ")"
                   (if (string=? detail "") "" (string-append ": " detail))))
  (exn:fail:keynub text (current-continuation-marks) (status-symbol code) code operation detail))

(define (raise-library-error text)
  (raise (exn:fail:keynub:library text (current-continuation-marks))))

;; The text before the first NUL byte (all of it when there is none), decoded
;; as UTF-8.
(define (c-string buffer)
  (define end
    (or (for/first ([b (in-bytes buffer)]
                    [i (in-naturals)]
                    #:when (zero? b))
          i)
        (bytes-length buffer)))
  (bytes->string/utf-8 (subbytes buffer 0 end) (integer->char #xFFFD)))
