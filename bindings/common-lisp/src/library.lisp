;;;; library.lisp -- where the native library (keynub_licdongle_flat) comes
;;;; from, and the table of the flat C API's functions.
;;;;
;;;; The path given to SET-LIBRARY-PATH, then KEYNUB_LICDONGLE_FLAT_LIBRARY in
;;;; the environment, then natives/<platform>/ of an SDK clone from the
;;;; program's folder, the current directory and this system's folder upwards,
;;;; then the bare file name for the system loader. The library is loaded on
;;;; the first call that needs it, and a process loads it once.

(in-package #:keynub-licdongle)

(defun library-environment-variable ()
  "The environment variable that names the library file."
  "KEYNUB_LICDONGLE_FLAT_LIBRARY")

(defparameter *native-folders*
  '("win-x64" "win-x86" "win-arm64" "linux-x64" "linux-arm64" "osx-x64" "osx-arm64"))

(defparameter *function-names*
  '("licdf_version" "licdf_device_count" "licdf_device_serial" "licdf_device_path"
    "licdf_open" "licdf_open_path" "licdf_close" "licdf_set_trust_root"
    "licdf_get_serial" "licdf_get_info" "licdf_verify_genuine"
    "licdf_session_open" "licdf_session_close" "licdf_write_auth" "licdf_write_auth_rotate"
    "licdf_record_count" "licdf_record_name" "licdf_record_size" "licdf_record_read"
    "licdf_record_write" "licdf_record_erase" "licdf_record_erase_all"
    "licdf_counter_read" "licdf_counter_increment"
    "licdf_app_encrypt" "licdf_app_decrypt"
    "licdf_strerror" "licdf_last_error")
  "Every function of the flat API.")

(defun library-basename ()
  "The library's file name on this operating system."
  (cond ((uiop:os-windows-p) "keynub_licdongle_flat.dll")
        ((uiop:os-macosx-p) "libkeynub_licdongle_flat.dylib")
        (t "libkeynub_licdongle_flat.so")))

;;; ---- a lock around loading ---------------------------------------------

(defun make-lock ()
  #+sbcl (sb-thread:make-mutex :name "keynub-licdongle")
  #+ccl (ccl:make-lock "keynub-licdongle")
  #+ecl (mp:make-lock :name "keynub-licdongle" :recursive t)
  #-(or sbcl ccl ecl) nil)

(defmacro with-lock ((lock) &body body)
  #+sbcl `(sb-thread:with-recursive-lock (,lock) ,@body)
  #+ccl `(ccl:with-lock-grabbed (,lock) ,@body)
  #+ecl `(mp:with-lock (,lock) ,@body)
  #-(or sbcl ccl ecl) `(progn ,lock ,@body))

(defvar *lock* (make-lock))
(defvar *chosen-path* nil)
(defvar *loaded-path* nil)
(defvar *api* nil)

(defun set-library-path (path)
  "Names the library file to load. Call it before the first dongle call."
  (check-type path (or string pathname))
  (let ((text (if (pathnamep path) (uiop:native-namestring path) path)))
    (with-lock (*lock*)
      (when (and *loaded-path* (string/= *loaded-path* text))
        (library-error "the KeyNub library is already loaded from ~a; a process loads it once"
                       *loaded-path*))
      (setf *chosen-path* text))
    (values)))

(defun loaded-library-path ()
  "The path of the loaded library; NIL before the first call."
  (with-lock (*lock*) *loaded-path*))

(defun library-path ()
  "The path in use, or the first candidate when nothing is loaded yet."
  (with-lock (*lock*) (or *loaded-path* (first (library-candidates)))))

;;; ---- the candidates ----------------------------------------------------

(defparameter *system-folder*
  #.(let ((here (or *compile-file-truename* *load-truename*)))
      (and here (uiop:pathname-directory-pathname here)))
  "The folder this file was compiled from.")

(defun program-folder ()
  "The folder of the running executable, when it is known."
  (let ((exe #+sbcl sb-ext:*runtime-pathname* #-sbcl (uiop:argv0)))
    (when (and (stringp exe) (plusp (length exe)))
      (let ((path (uiop:parse-native-namestring exe)))
        (and (uiop:absolute-pathname-p path)
             (uiop:pathname-directory-pathname path))))))

(defun folder-and-parents (folder)
  "FOLDER, its parent, and so on up to the root."
  (let* ((dir (uiop:ensure-directory-pathname folder))
         (components (pathname-directory dir)))
    (loop for n from (length components) downto 1
          collect (make-pathname :directory (subseq components 0 n)
                                 :name nil :type nil :version nil :defaults dir))))

(defun library-candidates ()
  "The paths tried, in order."
  (let ((from-environment (uiop:getenv (library-environment-variable))))
    (cond
      (*chosen-path* (list *chosen-path*))
      ((and from-environment (string/= from-environment "")) (list from-environment))
      (t
       (let* ((base (library-basename))
              (starts (remove-duplicates
                       (remove nil (list (program-folder) (uiop:getcwd) *system-folder*))
                       :key #'uiop:native-namestring :test #'string= :from-end t))
              (found '()))
         (dolist (start starts)
           (dolist (dir (folder-and-parents start))
             (dolist (folder *native-folders*)
               (let ((file (merge-pathnames base (merge-pathnames
                                                  (make-pathname :directory (list :relative "natives" folder))
                                                  dir))))
                 (when (uiop:file-exists-p file)
                   (pushnew (uiop:native-namestring file) found :test #'string=))))))
         (append (nreverse found) (list base)))))))

;;; ---- loading -----------------------------------------------------------

(defun try-load (path)
  "A table of every function from the library at PATH, or a string giving the
reason it cannot be used."
  (handler-case
      (let ((library (cffi:load-foreign-library path))
            (table (make-hash-table :test #'equal)))
        (dolist (name *function-names* table)
          (let ((pointer (cffi:foreign-symbol-pointer name :library library)))
            (if pointer
                (setf (gethash name table) pointer)
                (return (format nil "does not export ~a" name))))))
    (error (e)
      (remove #\Newline (princ-to-string e)))))

(defun load-library ()
  (loop with reasons = '()
        for path in (library-candidates)
        for result = (try-load path)
        when (hash-table-p result)
          do (setf *loaded-path* path)
             (return result)
        do (push (format nil "~a (~a)" path result) reasons)
        finally (library-error "cannot load the KeyNub library; tried ~{~a~^, ~}"
                               (reverse reasons))))

(defun flat-function (name)
  "The address of the flat API function NAME, loading the library on the first call."
  (let ((table (or *api*
                   (with-lock (*lock*)
                     (or *api* (setf *api* (load-library)))))))
    (gethash name table)))

(defmacro flat-call (name &rest arguments)
  "Calls the flat API function NAME (a string) with ARGUMENTS, given as
alternating CFFI types and values; returns its int32 status."
  `(cffi:foreign-funcall-pointer (flat-function ,name) () ,@arguments :int32))
