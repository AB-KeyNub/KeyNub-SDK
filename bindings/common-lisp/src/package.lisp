;;;; package.lisp

(defpackage #:keynub-licdongle
  (:use #:common-lisp)
  (:nicknames #:licdongle)
  (:documentation "KeyNub License Dongle: verify that a dongle is genuine, read and
write the license records it holds, use its hardware counters and encrypt data so
that only a dongle can decrypt it. Calls the SDK's flat C API through a library
loaded at run time; nothing is linked.")
  (:export
   ;; the library
   #:library-environment-variable
   #:library-basename
   #:library-candidates
   #:set-library-path
   #:library-path
   #:loaded-library-path
   #:library-version
   ;; status codes and conditions
   #:status-keyword
   #:status-code
   #:status-text
   #:licdongle-error
   #:licdongle-error-status
   #:licdongle-error-code
   #:licdongle-error-operation
   #:licdongle-error-detail
   #:licdongle-library-error
   ;; discovery and opening
   #:device
   #:device-p
   #:device-serial
   #:device-path
   #:devices
   #:dongle
   #:dongle-p
   #:open-dongle
   #:open-dongle-path
   #:close-dongle
   #:dongle-open-p
   #:call-with-dongle
   #:with-dongle
   ;; plaintext information and authenticity
   #:dongle-serial
   #:device-info
   #:device-info-p
   #:device-info-protocol-major
   #:device-info-protocol-minor
   #:device-info-firmware-major
   #:device-info-firmware-minor
   #:device-info-firmware-patch
   #:device-info-secure-element-ready-p
   #:device-info-provisioned-p
   #:device-info-watchdog-reboot-p
   #:device-info-isolated-p
   #:device-info-write-auth-rotated-p
   #:device-info-data-capacity
   #:device-info-data-free
   #:dongle-info
   #:verification
   #:verification-p
   #:verification-serial
   #:verification-provisioned-date
   #:dongle-verify-genuine
   #:dongle-genuine-p
   #:set-trust-root
   #:dongle-last-error
   ;; sessions and the write role
   #:open-session
   #:close-session
   #:call-with-session
   #:with-session
   #:authorize-write
   #:rotate-write-key
   ;; records
   #:record
   #:record-p
   #:record-name
   #:record-size
   #:dongle-records
   #:read-record
   #:write-record
   #:erase-record
   #:erase-all-records
   ;; counters
   #:read-counter
   #:increment-counter
   ;; app-data encryption
   #:app-encrypt
   #:app-decrypt))
