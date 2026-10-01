;;;; run-unit-tests.lisp -- runs the unit tests from a shell, exit code 0 when
;;;; every check passed. ASDF must find cffi (Quicklisp, for one, sees to that).
;;;;
;;;;     sbcl --non-interactive --load bindings/common-lisp/test/run-unit-tests.lisp

(require "asdf")

(push (uiop:pathname-parent-directory-pathname
       (uiop:pathname-directory-pathname *load-truename*))
      asdf:*central-registry*)

(asdf:load-system "keynub-licdongle/tests")

(uiop:quit (if (uiop:symbol-call '#:keynub-licdongle/tests '#:run-tests) 0 1))
