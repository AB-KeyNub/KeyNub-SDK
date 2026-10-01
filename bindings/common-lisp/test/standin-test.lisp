;;;; standin-test.lisp -- every call of the binding against a stand-in for the
;;;; flat C API: the SDK's flat layer compiled together with the C ABI stand-in
;;;; (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
;;;; into one shared library, with a C compiler from the path (cc, gcc, clang,
;;;; zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
;;;; stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the
;;;; test does not run inside a clone. Exit code 0 when every check passed.
;;;; ASDF must find cffi (Quicklisp, for one, sees to that).
;;;;
;;;;     sbcl --non-interactive --load bindings/common-lisp/test/standin-test.lisp

(require "asdf")

(push (uiop:pathname-parent-directory-pathname
       (uiop:pathname-directory-pathname *load-truename*))
      asdf:*central-registry*)

(asdf:load-system "keynub-licdongle")

(defpackage #:keynub-licdongle/standin-test
  (:use #:common-lisp #:keynub-licdongle))

(in-package #:keynub-licdongle/standin-test)

(defparameter *serial* "04A1B2C3D4E5F6")
(defvar *failures* 0)

(defun octets (&rest values)
  (make-array (length values) :element-type '(unsigned-byte 8) :initial-contents values))

(defun text-octets (text)
  (babel:string-to-octets text :encoding :utf-8))

(defparameter *factory-key* (octets #x30 #x10 #x01 #x02 #x03))
(defparameter *replacement-key* (octets #x30 #x11 #x09 #x08 #x07 #x06))

(defun check (condition what)
  (unless condition
    (incf *failures*)
    (format t "  FAIL  ~a~%" what)))

(defun fails* (status what thunk)
  (handler-case (progn (funcall thunk)
                       (check nil (format nil "~a: no failure" what)))
    (licdongle-error (e)
      (check (eq (licdongle-error-status e) status)
             (format nil "~a: ~(~a~)" what (or (licdongle-error-status e) :unknown))))))

(defmacro fails (status what &body body)
  `(fails* ,status ,what (lambda () ,@body)))

;;; ---- the stand-in ------------------------------------------------------

(defun has-flat-sources-p (dir)
  (uiop:file-exists-p (merge-pathnames "bindings/flat/licd_flat.c" dir)))

(defun search-upwards (start)
  (let ((components (pathname-directory (uiop:ensure-directory-pathname start))))
    (loop for n from (length components) downto 1
          for dir = (make-pathname :directory (subseq components 0 n) :name nil :type nil
                                   :version nil :defaults start)
          when (has-flat-sources-p dir) return dir)))

(defparameter *this-folder* (uiop:pathname-directory-pathname *load-truename*))

(defun sdk-root ()
  (let ((given (uiop:getenv "KEYNUB_SDK_ROOT")))
    (or (and given (string/= given "")
             (uiop:ensure-directory-pathname (uiop:parse-native-namestring given)))
        (search-upwards (uiop:getcwd))
        (search-upwards *this-folder*)
        (progn
          (format t "the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT~%")
          (uiop:quit 1)))))

(defun run-quietly (command arguments dir)
  "Runs COMMAND with ARGUMENTS in DIR, output discarded; true when it exited 0."
  (handler-case
      (multiple-value-bind (output error-output code)
          (uiop:run-program (cons command arguments) :directory dir :output nil
                                                     :error-output nil :input nil
                                                     :ignore-error-status t)
        (declare (ignore output error-output))
        (eql code 0))
    (error () nil)))

(defun build-stand-in ()
  (let* ((root (sdk-root))
         (windows (uiop:os-windows-p))
         (tmp (uiop:temporary-directory))
         ;; A file name other than the library's own (keynub_licdongle_flat).
         (output (uiop:native-namestring
                  (merge-pathnames (if windows "keynub_flat_standin.dll" "libkeynub_flat_standin.so")
                                   tmp)))
         (include-dir (uiop:native-namestring
                       (if (uiop:file-exists-p (merge-pathnames "core/include/licdongle.h" root))
                           (merge-pathnames "core/include/" root)
                           (merge-pathnames "include/" root))))
         (flat-dir (uiop:native-namestring (merge-pathnames "bindings/flat/" root)))
         (sources (list (uiop:native-namestring (merge-pathnames "bindings/flat/licd_flat.c" root))
                        (uiop:native-namestring
                         (merge-pathnames "bindings/julia/test/stub/licd_stub.c" root))))
         (gcc-arguments (append (list "-shared" "-O1" "-DLICD_BUILD_SHARED" "-DLICDF_BUILD_SHARED"
                                      (concatenate 'string "-I" include-dir)
                                      (concatenate 'string "-I" flat-dir)
                                      "-o" output)
                                sources
                                (if windows '() '("-fPIC"))))
         (cl-arguments (append (list "/nologo" "/LD" "/O1" "/DLICD_BUILD_SHARED" "/DLICDF_BUILD_SHARED"
                                     (concatenate 'string "/I" include-dir)
                                     (concatenate 'string "/I" flat-dir)
                                     (concatenate 'string "/Fe:" output))
                               sources))
         (commands (list (cons "cc" gcc-arguments)
                         (cons "gcc" gcc-arguments)
                         (cons "clang" gcc-arguments)
                         (list* "zig" "cc" gcc-arguments)
                         (cons "cl" cl-arguments))))
    (or (loop for (command . arguments) in commands
              when (run-quietly command arguments tmp) return output)
        (progn
          (format t "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path~%")
          (uiop:quit 1)))))

(defun stand-in ()
  (let ((given (uiop:getenv (library-environment-variable))))
    (if (and given (string/= given ""))
        given
        (build-stand-in))))

;;; ---- the checks --------------------------------------------------------

(defun run-checks ()
  (set-library-path (stand-in))

  (check (equal (multiple-value-list (library-version)) '(9 8 7)) "library version")
  (check (equal (status-text -2) "no device") "status text")

  (let ((all (devices)))
    (check (and (= (length all) 1)
                (equal (device-serial (first all)) *serial*)
                (equal (device-path (first all)) "stub:0"))
           "devices"))
  (fails :no-device "open by unknown serial" (open-dongle "nope"))
  (fails :no-device "open by unknown path" (open-dongle-path "stub:9"))

  (let ((d (open-dongle)))
    (check (dongle-open-p d) "open")
    (check (equal (dongle-serial d) *serial*) "serial")
    (let ((i (dongle-info d)))
      (check (and (= (device-info-protocol-major i) 1) (= (device-info-protocol-minor i) 0))
             "protocol version")
      (check (and (= (device-info-firmware-major i) 2)
                  (= (device-info-firmware-minor i) 3)
                  (= (device-info-firmware-patch i) 4))
             "firmware version")
      (check (and (device-info-secure-element-ready-p i)
                  (device-info-provisioned-p i)
                  (device-info-isolated-p i))
             "flags set")
      (check (and (not (device-info-watchdog-reboot-p i)) (not (device-info-write-auth-rotated-p i)))
             "flags clear")
      (check (and (= (device-info-data-capacity i) (* 1024 1024)) (= (device-info-data-free i) 1000000))
             "capacity"))
    (let ((g (dongle-verify-genuine d)))
      (check (and (equal (verification-serial g) *serial*)
                  (equal (verification-provisioned-date g) "2026-08-15"))
             "genuine"))
    (check (dongle-genuine-p d) "genuine-p")

    (fails :cert-invalid "malformed trust root" (set-trust-root d (octets #x02 #x01 #x00)))
    (let ((root (make-array 132 :element-type '(unsigned-byte 8) :initial-element #xAB)))
      (setf (aref root 0) #x30 (aref root 1) #x82 (aref root 2) #x01 (aref root 3) #x00)
      (set-trust-root d root)
      (fails :cert-invalid "verify against a foreign root" (dongle-verify-genuine d))
      (check (not (dongle-genuine-p d)) "genuine-p fails closed")
      (loop for k from 4 below (length root) do (setf (aref root k) #x01))
      (set-trust-root d root)
      (check (dongle-genuine-p d) "genuine-p after the right root"))

    (fails :session-expired "records without a session" (dongle-records d))
    (open-session d)
    (let ((payload (text-octets "license-blob-0123456789")))
      (fails :auth-required "write before the write role" (write-record d "lic" payload))
      (fails :not-genuine "write role with a bad key" (authorize-write d (octets #x30 #x00)))
      (authorize-write d *factory-key*)
      (write-record d "lic" payload)
      (check (equalp (read-record d "lic") payload) "read back")
      (write-record d "cfg" (text-octets "cfgdata"))
      (let ((records (dongle-records d)))
        (check (equal (sort (mapcar #'record-name records) #'string<) '("cfg" "lic")) "record names")
        (check (find-if (lambda (r) (and (equal (record-name r) "lic")
                                         (= (record-size r) (length payload))))
                        records)
               "record size"))
      (check (equalp (read-record d "cfg") (text-octets "cfgdata")) "second record")
      (fails :not-found "read a missing record" (read-record d "nope"))
      (fails :invalid-arg "erase with an empty name" (erase-record d ""))
      (check (= (length (dongle-records d)) 2) "two records")
      (erase-record d "cfg")
      (check (equal (mapcar #'record-name (dongle-records d)) '("lic")) "one record left")
      (write-record d "empty" (octets))
      (check (zerop (length (read-record d "empty"))) "empty record"))

    (let ((before (read-counter d 0)))
      (check (= (increment-counter d 0) (1+ before)) "increment")
      (check (and (= (read-counter d 0) (1+ before)) (= (read-counter d 1) 0)) "counters"))
    (fails :range "counter out of range" (read-counter d 7))

    (let ((secret (make-array 100 :element-type '(unsigned-byte 8))))
      (dotimes (k 100) (setf (aref secret k) (mod (+ (* 3 k) 7) 256)))
      (loop for scope in '(:device :developer)
            for scope-value in '(0 1)
            do (let ((blob (app-encrypt d scope secret)))
                 (check (> (length blob) (length secret)) (format nil "sealed data is longer, ~(~a~)" scope))
                 (check (= (aref blob 0) scope-value) (format nil "scope byte, ~(~a~)" scope))
                 (check (equalp (app-decrypt d blob) secret) (format nil "round trip, ~(~a~)" scope))
                 (let ((tampered (copy-seq blob))
                       (last-index (1- (length blob))))
                   (setf (aref tampered last-index) (logxor (aref tampered last-index) 1))
                   (fails :tag-mismatch (format nil "tampered blob, ~(~a~)" scope)
                     (app-decrypt d tampered))))))

    (erase-all-records d)
    (check (null (dongle-records d)) "erase all")

    (rotate-write-key d *replacement-key*)
    (write-record d "lic" (text-octets "still-writable"))
    (close-session d)
    (check (device-info-write-auth-rotated-p (dongle-info d)) "rotated flag")
    (open-session d)
    (fails :not-genuine "factory key after rotation" (authorize-write d *factory-key*))
    (authorize-write d *replacement-key*)
    (write-record d "lic" (text-octets "new-key-writes"))
    (check (equalp (read-record d "lic") (text-octets "new-key-writes")) "write with the new key")
    (close-session d)
    (close-dongle d)
    (check (not (dongle-open-p d)) "closed")
    (fails :invalid-arg "serial after close" (dongle-serial d)))

  (check (equal (with-dongle (dd) (dongle-serial dd)) *serial*) "open with a block")
  ;; DONGLE-RECORDS needs a session, so a value back proves WITH-SESSION
  ;; opened one.
  (let ((count (with-dongle (dd :serial *serial*)
                 (with-session (dd) (length (dongle-records dd))))))
    (check (>= count 0) "session with a block"))
  (let ((closed (call-with-dongle #'identity)))
    (check (not (dongle-open-p closed)) "closed after the block"))
  (check (equal (loaded-library-path) (library-path)) "loaded path")

  (cond
    ((plusp *failures*)
     (format t "~d check(s) failed~%" *failures*)
     (uiop:quit 1))
    (t
     (format t "keynub_licdongle: every call passed against the ABI stand-in~%")
     (uiop:quit 0))))

(handler-case (run-checks)
  (error (e)
    (format t "  FAIL  unexpected error: ~a~%" e)
    (uiop:quit 1)))
