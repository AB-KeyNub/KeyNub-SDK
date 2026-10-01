#lang racket/base
;; Unit tests that need neither the native library nor a dongle.
;;
;;     raco test test/unit-test.rkt      (from bindings/racket)
(module+ test
  (require rackunit
           racket/file
           "../licdongle.rkt"
           (only-in "../licdongle/private/common.rkt" make-keynub-error c-string))

  (test-case "names status codes"
    (check-equal? (status-symbol -2) 'no-device)
    (check-equal? (status-symbol 0) 'ok)
    (check-false (status-symbol -99))
    (check-equal? (status-code 'not-found) -14)
    (check-false (status-code 'no-such-status)))

  (test-case "builds the error text from operation, status and detail"
    (define e (make-keynub-error "licdf_open" -2))
    (check-equal? (exn:fail:keynub-status e) 'no-device)
    (check-equal? (exn:fail:keynub-code e) -2)
    (check-equal? (exn:fail:keynub-operation e) "licdf_open")
    (check-equal? (exn:fail:keynub-detail e) "")
    (check-equal? (exn-message e) "licdf_open: no-device (-2)")
    (define f (make-keynub-error "licdf_record_read" -14 "no such record"))
    (check-equal? (exn-message f) "licdf_record_read: not-found (-14): no such record")
    (define g (make-keynub-error "x" -99))
    (check-false (exn:fail:keynub-status g))
    (check-equal? (exn-message g) "x: unknown (-99)"))

  (test-case "places both exceptions under exn:fail"
    (define e (make-keynub-error "licdf_open" -2))
    (check-true (exn:fail? e))
    (define l (exn:fail:keynub:library "cannot load" (current-continuation-marks)))
    (check-true (exn:fail? l))
    (check-false (exn:fail:keynub? l)))

  (test-case "keeps the bare file name as the last resort"
    (define all (library-candidates))
    (check-false (null? all))
    (unless (getenv library-environment-variable)
      (check-equal? (car (reverse all)) (library-basename))))

  (test-case "names the library for this operating system"
    (check-equal? (library-basename)
                  (case (system-type 'os)
                    [(windows) "keynub_licdongle_flat.dll"]
                    [(macosx) "libkeynub_licdongle_flat.dylib"]
                    [else "libkeynub_licdongle_flat.so"])))

  (test-case "takes the library path from the environment"
    (define env (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! env
                                (string->bytes/utf-8 library-environment-variable)
                                #"/opt/keynub/stand-in.so")
    (parameterize ([current-environment-variables env])
      (check-equal? (library-candidates) '("/opt/keynub/stand-in.so"))))

  (test-case "finds natives/<platform>/ above the current directory"
    (define env (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! env (string->bytes/utf-8 library-environment-variable) #f)
    (define root (make-temporary-file "keynub-natives-~a" 'directory))
    (dynamic-wind
     void
     (lambda ()
       (define folder (build-path root "natives" "linux-arm64"))
       (make-directory* folder)
       (define library (build-path folder (library-basename)))
       (call-with-output-file library void)
       (define below (build-path root "app" "bin"))
       (make-directory* below)
       (parameterize ([current-environment-variables env]
                      [current-directory below])
         (define all (library-candidates))
         (check-not-false (member (path->string (simplify-path library)) all))
         (check-equal? (car (reverse all)) (library-basename))))
     (lambda () (delete-directory/files root #:must-exist? #f))))

  (test-case "reads a NUL-terminated buffer"
    (check-equal? (c-string (bytes #x61 #x62 0 #x63)) "ab")
    (check-equal? (c-string (bytes #x61 #x62)) "ab")
    (check-equal? (c-string (bytes 0)) ""))

  (test-case "checks arguments before loading the library"
    (check-exn exn:fail:contract? (lambda () (read-counter 'not-a-dongle 0)))
    (check-exn exn:fail:contract? (lambda () (status-text "no-device")))
    (check-exn exn:fail:contract? (lambda () (dongle-open 42)))
    (check-exn exn:fail:contract? (lambda () (set-library-path! 42)))
    (check-false (loaded-library-path))))
