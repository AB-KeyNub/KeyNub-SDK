;;;; unit-test.lisp -- unit tests that need neither the native library nor a
;;;; dongle.
;;;;
;;;;     (asdf:test-system "keynub-licdongle")

(defpackage #:keynub-licdongle/tests
  (:use #:common-lisp #:keynub-licdongle)
  (:export #:run-tests))

(in-package #:keynub-licdongle/tests)

(defvar *checks* 0)
(defvar *failures* 0)

(defmacro check (form &optional description)
  "Counts FORM as passed when it returns true."
  `(progn
     (incf *checks*)
     (unless (ignore-errors ,form)
       (incf *failures*)
       (format t "  FAIL  ~a~%" ,(or description (let ((*print-case* :downcase))
                                                    (prin1-to-string form)))))))

(defmacro check-signals (type form &optional description)
  "Counts FORM as passed when it signals a condition of TYPE."
  `(check (handler-case (progn ,form nil)
            (,type () t))
          ,(or description (let ((*print-case* :downcase))
                             (format nil "~s signals ~s" form type)))))

(defun env (name)
  (uiop:getenv name))

(defun (setf env) (value name)
  (setf (uiop:getenv name) value))

(defun test-status-codes ()
  (check (eq (status-keyword -2) :no-device))
  (check (eq (status-keyword 0) :ok))
  (check (null (status-keyword -99)))
  (check (eql (status-code :not-found) -14))
  (check (null (status-code :no-such-status))))

(defun test-error-text ()
  (let ((e (keynub-licdongle::make-licdongle-error "licdf_open" -2)))
    (check (eq (licdongle-error-status e) :no-device))
    (check (eql (licdongle-error-code e) -2))
    (check (equal (licdongle-error-operation e) "licdf_open"))
    (check (equal (licdongle-error-detail e) ""))
    (check (equal (princ-to-string e) "licdf_open: no-device (-2)")))
  (let ((f (keynub-licdongle::make-licdongle-error "licdf_record_read" -14 "no such record")))
    (check (equal (princ-to-string f) "licdf_record_read: not-found (-14): no such record")))
  (let ((g (keynub-licdongle::make-licdongle-error "x" -99)))
    (check (null (licdongle-error-status g)))
    (check (equal (princ-to-string g) "x: unknown (-99)"))))

(defun test-condition-types ()
  (let ((e (keynub-licdongle::make-licdongle-error "licdf_open" -2))
        (l (make-condition 'licdongle-library-error :detail "cannot load")))
    (check (typep e 'error))
    (check (typep l 'licdongle-error))
    (check (not (typep e 'licdongle-library-error)))
    (check (equal (princ-to-string l) "cannot load"))
    (check (null (licdongle-error-code l)))))

(defun test-candidates ()
  (let ((all (library-candidates)))
    (check (consp all))
    (when (member (env (library-environment-variable)) '(nil "") :test #'equal)
      (check (equal (car (last all)) (library-basename)) "bare file name last")))
  (check (equal (library-basename)
                (cond ((uiop:os-windows-p) "keynub_licdongle_flat.dll")
                      ((uiop:os-macosx-p) "libkeynub_licdongle_flat.dylib")
                      (t "libkeynub_licdongle_flat.so")))
         "library name for this operating system"))

(defun call-with-environment (value function)
  "Calls FUNCTION with the library variable set to VALUE (\"\" counts as unset)."
  (let* ((name (library-environment-variable))
         (saved (env name)))
    (setf (env name) value)
    (unwind-protect (funcall function)
      (setf (env name) (or saved "")))))

(defun test-environment ()
  (call-with-environment
   "/opt/keynub/stand-in.so"
   (lambda ()
     (check (equal (library-candidates) '("/opt/keynub/stand-in.so"))
            "library path from the environment"))))

(defun test-natives-folder ()
  (let ((root (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "keynub-natives-~36r" (random (expt 36 8) (make-random-state t)))
                                (uiop:temporary-directory)))))
    (unwind-protect
         (let* ((folder (merge-pathnames "natives/linux-arm64/" root))
                (library (merge-pathnames (library-basename) folder))
                (below (merge-pathnames "app/bin/" root)))
           (ensure-directories-exist library)
           (ensure-directories-exist below)
           (with-open-file (out library :direction :output :if-exists :supersede)
             (declare (ignorable out)))
           (call-with-environment
            ""
            (lambda ()
              (uiop:with-current-directory (below)
                (let ((all (library-candidates))
                      (expected (uiop:native-namestring (truename library))))
                  (check (member expected all :test #'string-equal)
                         "natives/<platform>/ above the current directory")
                  (check (equal (car (last all)) (library-basename))
                         "bare file name after the natives folder"))))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(defun octets (&rest values)
  (make-array (length values) :element-type '(unsigned-byte 8) :initial-contents values))

(defun test-c-string ()
  (check (equal (keynub-licdongle::c-string (octets #x61 #x62 0 #x63)) "ab"))
  (check (equal (keynub-licdongle::c-string (octets #x61 #x62)) "ab"))
  (check (equal (keynub-licdongle::c-string (octets 0)) ""))
  (check (equal (keynub-licdongle::c-string (octets #xC3 #xA4 0)) (string (code-char #xE4))))
  (check (= 1 (length (keynub-licdongle::c-string (octets #xFF 0)))) "a byte that is not UTF-8"))

(defun test-arguments-before-loading ()
  (check-signals type-error (read-counter 'not-a-dongle 0))
  (check-signals type-error (status-text "no-device"))
  (check-signals type-error (open-dongle 42))
  (check-signals type-error (set-library-path 42))
  (check-signals type-error (app-encrypt 'not-a-dongle :device (octets 1)))
  (check (null (loaded-library-path)) "nothing loaded"))

(defun run-tests ()
  "Runs every unit test; true when all of them passed."
  (let ((*checks* 0)
        (*failures* 0))
    (test-status-codes)
    (test-error-text)
    (test-condition-types)
    (test-candidates)
    (test-environment)
    (test-natives-folder)
    (test-c-string)
    (test-arguments-before-loading)
    (if (zerop *failures*)
        (format t "keynub-licdongle: ~d unit checks passed~%" *checks*)
        (format t "keynub-licdongle: ~d of ~d check(s) failed~%" *failures* *checks*))
    (zerop *failures*)))
