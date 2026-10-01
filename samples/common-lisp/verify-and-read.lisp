;;;; KeyNub SDK - Common Lisp sample: verify a dongle and read what it holds.
;;;;
;;;;     sbcl --non-interactive --load samples/common-lisp/verify-and-read.lisp      (from the repository root)
;;;;
;;;; Targets real hardware: with no dongle attached it prints guidance and exits 0.
;;;; ASDF must find cffi (Quicklisp, for one, sees to that). In your own project,
;;;; after (ql:quickload "keynub-licdongle"), the two EVAL-WHEN forms below are
;;;; not needed.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "asdf"))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((samples (uiop:pathname-parent-directory-pathname
                  (uiop:pathname-directory-pathname (or *compile-file-truename* *load-truename*)))))
    (push (uiop:subpathname (uiop:pathname-parent-directory-pathname samples) "bindings/common-lisp/")
          asdf:*central-registry*))
  (asdf:load-system "keynub-licdongle"))

(defpackage #:keynub-sample/verify-and-read
  (:use #:common-lisp #:keynub-licdongle))

(in-package #:keynub-sample/verify-and-read)

(defun report (d)
  (let ((i (dongle-info d)))
    (format t "Protocol v~d.~d, firmware v~d.~d.~d, ~d of ~d bytes free.~%"
            (device-info-protocol-major i) (device-info-protocol-minor i)
            (device-info-firmware-major i) (device-info-firmware-minor i)
            (device-info-firmware-patch i)
            (device-info-data-free i) (device-info-data-capacity i))
    ;; The only trace a firmware hang leaves behind. Report it to support.
    (when (device-info-watchdog-reboot-p i)
      (format t "WARNING: this dongle's previous boot ended in a watchdog reset.~%")))
  (let ((g (dongle-verify-genuine d)))
    (format t "Genuine: yes (serial ~a, provisioned ~a)~%"
            (verification-serial g) (verification-provisioned-date g))))

(defun read-records (d)
  (let ((records (dongle-records d)))
    (format t "~d record(s) on the dongle:~%" (length records))
    (dolist (r records)
      (format t "  ~16a ~d bytes~%" (record-name r) (record-size r)))
    ;; A missing record is a normal state, not an error.
    (when (find "license" records :key #'record-name :test #'string=)
      (format t "Read ~d bytes from the license record.~%"
              (length (read-record d "license"))))))

;;; The part that protects something. At licence-issue time you would call
;;; APP-ENCRYPT once, with a developer dongle, and ship only the sealed data;
;;; the program then cannot proceed without a dongle, because it holds no other
;;; copy. :DEVELOPER lets any dongle you have issued decrypt it, so one file
;;; serves every customer; :DEVICE locks it to one dongle.
(defun protect-something (d)
  (let* ((needed (babel:string-to-octets "the data this program cannot run without" :encoding :utf-8))
         (sealed (app-encrypt d :developer needed))
         (recovered (app-decrypt d sealed)))
    (format t "App-crypto round trip: ~d bytes -> ~d sealed -> ~a~%"
            (length needed) (length sealed)
            (if (equalp recovered needed) "recovered intact" "MISMATCH"))))

(defun main ()
  (handler-case
      (multiple-value-bind (major minor patch) (library-version)
        (format t "KeyNub library v~d.~d.~d~%" major minor patch)
        (cond
          ((null (devices))
           (format t "Connect a KeyNub dongle and re-run.~%")
           (uiop:quit 0))
          (t
           (with-dongle (d)              ; first dongle, or (with-dongle (d :serial "...") ...)
             (report d)
             (with-session (d)           ; closed on every exit path
               (read-records d)
               (protect-something d)))
           (uiop:quit 0))))
    (licdongle-error (e)
      (format t "KeyNub error: ~a~%" e)
      (uiop:quit 1))))

(main)
