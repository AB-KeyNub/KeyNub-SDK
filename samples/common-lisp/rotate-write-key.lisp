;;;; KeyNub SDK - Common Lisp sample: take ownership of a new dongle.
;;;;
;;;; A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
;;;; so that from the next session onward only your key can write records, erase
;;;; them or increment counters. Run it once per dongle, when it arrives.
;;;;
;;;; Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
;;;;
;;;;     openssl ecparam -name prime256v1 -genkey -noout |
;;;;       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
;;;;
;;;;     sbcl --non-interactive --load samples/common-lisp/rotate-write-key.lisp keys/keynub-shipping-writeauth.key.der my-key.der
;;;;
;;;; Targets real hardware: with no dongle attached it prints guidance and exits 0.
;;;; ASDF must find cffi (Quicklisp, for one, sees to that). In your own project,
;;;; after (ql:quickload "keynub-licdongle"), the two EVAL-WHEN forms below are
;;;; not needed.
;;;;
;;;; Guard the replacement key as you guard your licence-signing key. It cannot
;;;; be recovered from the dongle, and a unit rotated to a key you have lost has
;;;; to come back to be re-provisioned.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "asdf"))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((samples (uiop:pathname-parent-directory-pathname
                  (uiop:pathname-directory-pathname (or *compile-file-truename* *load-truename*)))))
    (push (uiop:subpathname (uiop:pathname-parent-directory-pathname samples) "bindings/common-lisp/")
          asdf:*central-registry*))
  (asdf:load-system "keynub-licdongle"))

(defpackage #:keynub-sample/rotate-write-key
  (:use #:common-lisp #:keynub-licdongle))

(in-package #:keynub-sample/rotate-write-key)

(defun file-octets (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (let ((data (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence data in)
      data)))

(defun main (arguments)
  (unless (= (length arguments) 2)
    (format t "usage: rotate-write-key <current-key.der> <new-key.der>~%")
    (uiop:quit 2))
  (handler-case
      (let ((current (file-octets (first arguments)))
            (replacement (file-octets (second arguments))))
        (cond
          ((null (devices))
           (format t "Connect a KeyNub dongle and re-run.~%")
           (uiop:quit 0))
          (t
           (with-dongle (d)
             (format t "Dongle ~a~%" (dongle-serial d))
             (when (device-info-write-auth-rotated-p (dongle-info d))
               (format t "This dongle's write key has already been rotated away from the factory one.~%"))
             (with-session (d)
               (authorize-write d current)          ; the key the dongle accepts today
               (rotate-write-key d replacement))    ; from the next session: only the new one
             (format t "Write key rotated: ~:[no~;yes~]~%"
                     (device-info-write-auth-rotated-p (dongle-info d))))
           (uiop:quit 0))))
    ((or licdongle-error file-error) (e)
      (format t "KeyNub error: ~a~%" e)
      (uiop:quit 1))))

(main (uiop:command-line-arguments))
