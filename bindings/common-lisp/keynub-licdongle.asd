;;;; keynub-licdongle.asd
;;;;
;;;; KeyNub License Dongle for Common Lisp: CFFI over the SDK's flat C API,
;;;; loaded at run time on the first call that needs it. Loading the system
;;;; does not load the native library.

(defsystem "keynub-licdongle"
  :description "KeyNub License Dongle: verify that a dongle is genuine, read and write the license records it holds, use its hardware counters and seal data that only a dongle can open."
  :author "KeyNub"
  :license "Apache-2.0"
  :version "1.1.1"
  :homepage "https://www.keynub.com/developers/common-lisp/"
  :bug-tracker "https://github.com/AB-KeyNub/KeyNub-SDK/issues"
  :source-control (:git "https://github.com/AB-KeyNub/KeyNub-SDK.git")
  :depends-on ("cffi" "babel" "uiop")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "common")
               (:file "library")
               (:file "licdongle"))
  :in-order-to ((test-op (test-op "keynub-licdongle/tests"))))

;;; The unit tests need neither the native library nor a dongle.
;;;
;;;     (asdf:test-system "keynub-licdongle")
(defsystem "keynub-licdongle/tests"
  :description "Unit tests of keynub-licdongle."
  :author "KeyNub"
  :license "Apache-2.0"
  :depends-on ("keynub-licdongle")
  :pathname "test/"
  :components ((:file "unit-test"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call '#:keynub-licdongle/tests '#:run-tests)
               (error "keynub-licdongle: unit tests failed"))))
