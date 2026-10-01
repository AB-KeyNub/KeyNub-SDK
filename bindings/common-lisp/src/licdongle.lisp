;;;; licdongle.lisp -- the dongle API over the flat C API.

(in-package #:keynub-licdongle)

;;; Buffer sizes (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE, LICDF_PATH_SIZE,
;;; LICDF_ERROR_SIZE), and one for a record name.
(defconstant +serial-size+ 15)
(defconstant +date-size+ 11)
(defconstant +path-size+ 512)
(defconstant +error-size+ 256)
(defconstant +name-size+ 256)

;;; Bits in the flags value of licdf_get_info.
(defconstant +flag-secure-element-ready+ #x01)
(defconstant +flag-provisioned+ #x02)
(defconstant +flag-watchdog-reboot+ #x04)
(defconstant +flag-isolated+ #x08)
(defconstant +flag-write-auth-rotated+ #x10)

(defstruct (device (:constructor make-device (serial path)) (:copier nil))
  "An attached dongle."
  (serial "" :type string :read-only t)
  (path "" :type string :read-only t))

(defstruct (device-info (:copier nil))
  "Plaintext device information."
  (protocol-major 0 :type integer :read-only t)
  (protocol-minor 0 :type integer :read-only t)
  (firmware-major 0 :type integer :read-only t)
  (firmware-minor 0 :type integer :read-only t)
  (firmware-patch 0 :type integer :read-only t)
  (secure-element-ready-p nil :type boolean :read-only t)
  (provisioned-p nil :type boolean :read-only t)
  (watchdog-reboot-p nil :type boolean :read-only t)
  (isolated-p nil :type boolean :read-only t)
  (write-auth-rotated-p nil :type boolean :read-only t)
  (data-capacity 0 :type integer :read-only t)
  (data-free 0 :type integer :read-only t))

(defstruct (verification (:constructor make-verification (serial provisioned-date)) (:copier nil))
  "The result of a successful DONGLE-VERIFY-GENUINE."
  (serial "" :type string :read-only t)
  (provisioned-date "" :type string :read-only t))

(defstruct (record (:constructor make-record (name size)) (:copier nil))
  "A record on the dongle."
  (name "" :type string :read-only t)
  (size 0 :type integer :read-only t))

(defstruct (dongle (:constructor %make-dongle (cell)) (:copier nil))
  "An open dongle. CELL holds the flat API's handle, 0 once closed."
  (cell (list 0) :type cons :read-only t))

(defmethod print-object ((d dongle) stream)
  (print-unreadable-object (d stream :type t)
    (write-string (if (dongle-open-p d) "open" "closed") stream)))

;;; ---- helpers -----------------------------------------------------------

(defun handle-of (d)
  (check-type d dongle)
  (car (dongle-cell d)))

(defun detail-of (handle)
  (handler-case
      (cffi:with-foreign-pointer (text +error-size+)
        (setf (cffi:mem-ref text :uint8) 0)
        (if (zerop (flat-call "licdf_last_error" :int32 handle :pointer text :int32 +error-size+))
            (foreign-text text +error-size+)
            ""))
    (error () "")))

(defun check (operation handle rc)
  (unless (zerop rc)
    (error (make-licdongle-error operation rc (if (plusp handle) (detail-of handle) "")))))

(defun foreign-octets (pointer length)
  (let ((octets (make-octets length)))
    (dotimes (i length octets)
      (setf (aref octets i) (cffi:mem-aref pointer :uint8 i)))))

(defun foreign-text (pointer size)
  (c-string (foreign-octets pointer size)))

(defun length-of (data)
  (check-type data octets)
  (let ((n (length data)))
    (when (> n 2147483647)
      (error (make-licdongle-error "argument" (status-code :invalid-arg) "more than 2 GiB of data")))
    n))

(defmacro with-octets ((pointer length data) &body body)
  "Runs BODY with POINTER at a foreign copy of the octet vector DATA and LENGTH
bound to its length. The buffer has at least one byte, so the library can read
it even for empty data."
  (let ((source (gensym "DATA")) (i (gensym "I")))
    `(let* ((,source ,data)
            (,length (length-of ,source)))
       (cffi:with-foreign-pointer (,pointer (max ,length 1))
         (dotimes (,i ,length)
           (setf (cffi:mem-aref ,pointer :uint8 ,i) (aref ,source ,i)))
         ,@body))))

(defmacro with-text ((pointer text) &body body)
  "Runs BODY with POINTER at TEXT as a NUL-terminated UTF-8 string."
  (let ((value (gensym "TEXT")))
    `(let ((,value ,text))
       (check-type ,value string)
       (cffi:with-foreign-string (,pointer ,value :encoding :utf-8)
         ,@body))))

(defmacro with-int32 ((&rest pointers) &body body)
  "Runs BODY with each of POINTERS at a foreign int32 that starts at 0."
  `(cffi:with-foreign-objects ,(mapcar (lambda (p) `(,p :int32)) pointers)
     ,@(mapcar (lambda (p) `(setf (cffi:mem-ref ,p :int32) 0)) pointers)
     ,@body))

(defun int32 (pointer)
  (cffi:mem-ref pointer :int32))

(defun read-sized (d operation call)
  "The two-call convention: asks for the size with a capacity of 0, then reads
into a buffer of that size. CALL takes the buffer, its capacity and the length
pointer, and returns the status."
  (with-int32 (needed)
    (let ((rc (cffi:with-foreign-pointer (empty 1) (funcall call empty 0 needed))))
      (cond
        ((zerop rc) (make-octets 0))
        ((/= rc (status-code :range))
         (error (make-licdongle-error operation rc (dongle-last-error d))))
        (t
         (let ((size (int32 needed)))
           (cffi:with-foreign-pointer (buffer (max size 1))
             (let ((rc2 (funcall call buffer size needed)))
               (unless (zerop rc2)
                 (error (make-licdongle-error operation rc2 (dongle-last-error d))))
               (foreign-octets buffer (int32 needed))))))))))

;;; ---- the library and status codes -------------------------------------

(defun library-version ()
  "The native library's version, as three values: major, minor and patch."
  (with-int32 (major minor patch)
    (check "licdf_version" 0
           (flat-call "licdf_version" :pointer major :pointer minor :pointer patch))
    (values (int32 major) (int32 minor) (int32 patch))))

(defun status-text (code)
  "Human-readable text for a status code; needs no dongle."
  (check-type code (signed-byte 32))
  (cffi:with-foreign-pointer (text +error-size+)
    (setf (cffi:mem-ref text :uint8) 0)
    (if (zerop (flat-call "licdf_strerror" :int32 code :pointer text :int32 +error-size+))
        (foreign-text text +error-size+)
        (status-name code))))

;;; ---- discovery and opening --------------------------------------------

(defun devices ()
  "The attached dongles, as a list of DEVICE."
  (with-int32 (count)
    (check "licdf_device_count" 0 (flat-call "licdf_device_count" :pointer count))
    (cffi:with-foreign-pointer (text +path-size+)
      (loop for i below (int32 count)
            collect (progn
                      (setf (cffi:mem-ref text :uint8) 0)
                      (check "licdf_device_serial" 0
                             (flat-call "licdf_device_serial" :int32 i :pointer text :int32 +path-size+))
                      (let ((serial (foreign-text text +path-size+)))
                        (setf (cffi:mem-ref text :uint8) 0)
                        (check "licdf_device_path" 0
                               (flat-call "licdf_device_path" :int32 i :pointer text :int32 +path-size+))
                        (make-device serial (foreign-text text +path-size+))))))))

(defun close-handle (handle)
  (flat-call "licdf_close" :int32 handle))

(defun make-dongle (handle)
  (let* ((cell (list handle))
         (d (%make-dongle cell)))
    #+sbcl
    (sb-ext:finalize d (lambda ()
                         (let ((h (car cell)))
                           (when (plusp h)
                             (setf (car cell) 0)
                             (ignore-errors (close-handle h)))))
                     :dont-save t)
    d))

(defun open-dongle (&optional serial)
  "Opens the dongle with this serial, or the first one found when SERIAL is NIL
or empty."
  (check-type serial (or null string))
  (let ((handle (with-text (text (or serial "")) (flat-call "licdf_open" :pointer text))))
    (when (minusp handle)
      (error (make-licdongle-error "licdf_open" handle)))
    (make-dongle handle)))

(defun open-dongle-path (path)
  "Opens the dongle at this device path (from DEVICES)."
  (check-type path string)
  (let ((handle (with-text (text path) (flat-call "licdf_open_path" :pointer text))))
    (when (minusp handle)
      (error (make-licdongle-error "licdf_open_path" handle)))
    (make-dongle handle)))

(defun dongle-open-p (d)
  "True until CLOSE-DONGLE is called."
  (plusp (handle-of d)))

(defun close-dongle (d)
  "Closes the dongle. Further calls fail with :INVALID-ARG."
  (let ((handle (handle-of d)))
    (when (plusp handle)
      (setf (car (dongle-cell d)) 0)
      (check "licdf_close" handle (close-handle handle)))
    (values)))

(defun close-quietly (d)
  (ignore-errors (close-dongle d)))

(defun call-with-dongle (function &key serial path)
  "Opens the dongle (the first one, the one with SERIAL or the one at PATH),
calls FUNCTION with it and closes it on every exit path. Returns what FUNCTION
returns."
  (when (and serial path)
    (error "call-with-dongle: give :serial or :path, not both"))
  (let ((d (if path (open-dongle-path path) (open-dongle serial))))
    (unwind-protect (funcall function d)
      (close-quietly d))))

(defmacro with-dongle ((var &key serial path) &body body)
  "(with-dongle (d) ...), (with-dongle (d :serial serial) ...) or
(with-dongle (d :path path) ...): CALL-WITH-DONGLE with the body."
  `(call-with-dongle (lambda (,var) ,@body) :serial ,serial :path ,path))

;;; ---- plaintext information and authenticity --------------------------

(defun dongle-serial (d)
  "The dongle's serial number (14 hex digits)."
  (let ((handle (handle-of d)))
    (cffi:with-foreign-pointer (text +serial-size+)
      (setf (cffi:mem-ref text :uint8) 0)
      (check "licdf_get_serial" handle
             (flat-call "licdf_get_serial" :int32 handle :pointer text :int32 +serial-size+))
      (foreign-text text +serial-size+))))

(defun dongle-info (d)
  "Plaintext device information, as a DEVICE-INFO."
  (let ((handle (handle-of d)))
    (with-int32 (pa pb fa fb fc flags capacity free)
      (check "licdf_get_info" handle
             (flat-call "licdf_get_info" :int32 handle
                        :pointer pa :pointer pb :pointer fa :pointer fb :pointer fc
                        :pointer flags :pointer capacity :pointer free))
      (let ((bits (int32 flags)))
        (flet ((flag (bit) (logtest bits bit)))
          (make-device-info :protocol-major (int32 pa)
                            :protocol-minor (int32 pb)
                            :firmware-major (int32 fa)
                            :firmware-minor (int32 fb)
                            :firmware-patch (int32 fc)
                            :secure-element-ready-p (flag +flag-secure-element-ready+)
                            :provisioned-p (flag +flag-provisioned+)
                            :watchdog-reboot-p (flag +flag-watchdog-reboot+)
                            :isolated-p (flag +flag-isolated+)
                            :write-auth-rotated-p (flag +flag-write-auth-rotated+)
                            :data-capacity (int32 capacity)
                            :data-free (int32 free)))))))

(defun dongle-verify-genuine (d)
  "Proves the dongle is genuine: certificate chain to the trusted root plus a
live challenge-response. Returns a VERIFICATION only when it is; signals
LICDONGLE-ERROR otherwise."
  (let ((handle (handle-of d)))
    (with-int32 (genuine)
      (cffi:with-foreign-pointer (serial +serial-size+)
        (cffi:with-foreign-pointer (date +date-size+)
          (setf (cffi:mem-ref serial :uint8) 0
                (cffi:mem-ref date :uint8) 0)
          (check "licdf_verify_genuine" handle
                 (flat-call "licdf_verify_genuine" :int32 handle :pointer genuine
                            :pointer serial :int32 +serial-size+
                            :pointer date :int32 +date-size+))
          (when (zerop (int32 genuine))
            (error (make-licdongle-error "licdf_verify_genuine" (status-code :not-genuine))))
          (make-verification (foreign-text serial +serial-size+)
                             (foreign-text date +date-size+)))))))

(defun dongle-genuine-p (d)
  "The boolean form for a gate: T only when DONGLE-VERIFY-GENUINE succeeds.
Fails closed: every failure gives NIL."
  (handler-case (progn (dongle-verify-genuine d) t)
    (error () nil)))

(defun set-trust-root (d der)
  "Overrides the CA root that DONGLE-VERIFY-GENUINE checks against (DER octets)."
  (let ((handle (handle-of d)))
    (with-octets (pointer length der)
      (check "licdf_set_trust_root" handle
             (flat-call "licdf_set_trust_root" :int32 handle :pointer pointer :int32 length)))
    (values)))

(defun dongle-last-error (d)
  "Diagnostic detail for the most recent failure on this dongle; may be empty."
  (detail-of (handle-of d)))

;;; ---- sessions and the write role -------------------------------------

(defun open-session (d)
  "Opens an authenticated session; records, counters and app crypto need one."
  (let ((handle (handle-of d)))
    (check "licdf_session_open" handle (flat-call "licdf_session_open" :int32 handle))
    (values)))

(defun close-session (d)
  "Closes the session."
  (let ((handle (handle-of d)))
    (check "licdf_session_close" handle (flat-call "licdf_session_close" :int32 handle))
    (values)))

(defun call-with-session (d function)
  "Opens a session, calls FUNCTION with no arguments and closes the session on
every exit path. Returns what FUNCTION returns."
  (open-session d)
  (unwind-protect (funcall function)
    (ignore-errors (close-session d))))

(defmacro with-session ((d) &body body)
  "(with-session (d) ...): CALL-WITH-SESSION with the body."
  `(call-with-session ,d (lambda () ,@body)))

(defun authorize-write (d key)
  "Elevates the session to the write role with a write-auth key (P-256 PKCS#8
DER octets)."
  (let ((handle (handle-of d)))
    (with-octets (pointer length key)
      (check "licdf_write_auth" handle
             (flat-call "licdf_write_auth" :int32 handle :pointer pointer :int32 length)))
    (values)))

(defun rotate-write-key (d key)
  "Replaces the dongle's write-auth key with KEY (P-256 PKCS#8 DER octets).
Call AUTHORIZE-WRITE first. From the next session on, only the new key
elevates."
  (let ((handle (handle-of d)))
    (with-octets (pointer length key)
      (check "licdf_write_auth_rotate" handle
             (flat-call "licdf_write_auth_rotate" :int32 handle :pointer pointer :int32 length)))
    (values)))

;;; ---- records -----------------------------------------------------------

(defun dongle-records (d)
  "The records on the dongle, as a list of RECORD."
  (let ((handle (handle-of d)))
    (with-int32 (count size)
      (check "licdf_record_count" handle (flat-call "licdf_record_count" :int32 handle :pointer count))
      (cffi:with-foreign-pointer (text +name-size+)
        (loop for i below (int32 count)
              collect (progn
                        (setf (cffi:mem-ref text :uint8) 0)
                        (check "licdf_record_name" handle
                               (flat-call "licdf_record_name" :int32 handle :int32 i
                                          :pointer text :int32 +name-size+ :pointer size))
                        (make-record (foreign-text text +name-size+) (int32 size))))))))

(defun read-record (d name)
  "The content of a record, as an octet vector."
  (let ((handle (handle-of d)))
    (with-text (text name)
      (read-sized d "licdf_record_read"
                  (lambda (buffer capacity needed)
                    (flat-call "licdf_record_read" :int32 handle :pointer text
                               :pointer buffer :int32 capacity :pointer needed))))))

(defun write-record (d name data)
  "Writes a record, replacing one of the same name. Needs the write role."
  (let ((handle (handle-of d)))
    (with-text (text name)
      (with-octets (pointer length data)
        (check "licdf_record_write" handle
               (flat-call "licdf_record_write" :int32 handle :pointer text
                          :pointer pointer :int32 length))))
    (values)))

(defun erase-record (d name)
  "Erases one record. Needs the write role."
  (let ((handle (handle-of d)))
    (with-text (text name)
      (check "licdf_record_erase" handle
             (flat-call "licdf_record_erase" :int32 handle :pointer text)))
    (values)))

(defun erase-all-records (d)
  "Erases every record. Needs the write role."
  (let ((handle (handle-of d)))
    (check "licdf_record_erase_all" handle (flat-call "licdf_record_erase_all" :int32 handle))
    (values)))

;;; ---- counters ----------------------------------------------------------

(defun read-counter (d counter-id)
  "The value of a hardware monotonic counter."
  (let ((handle (handle-of d)))
    (check-type counter-id (signed-byte 32))
    (with-int32 (value)
      (check "licdf_counter_read" handle
             (flat-call "licdf_counter_read" :int32 handle :int32 counter-id :pointer value))
      (int32 value))))

(defun increment-counter (d counter-id)
  "Increments a counter and returns the new value. Needs the write role."
  (let ((handle (handle-of d)))
    (check-type counter-id (signed-byte 32))
    (with-int32 (value)
      (check "licdf_counter_increment" handle
             (flat-call "licdf_counter_increment" :int32 handle :int32 counter-id :pointer value))
      (int32 value))))

;;; ---- app-data encryption ----------------------------------------------

(defun app-encrypt (d scope plaintext)
  "Seals PLAINTEXT (octets) so that only a dongle can open it: this one
(:DEVICE) or any dongle issued by the same developer (:DEVELOPER)."
  (let ((handle (handle-of d)))
    (check-type scope (member :device :developer))
    (let ((scope-value (if (eq scope :device) 0 1)))
      (with-octets (input input-length plaintext)
        (read-sized d "licdf_app_encrypt"
                    (lambda (buffer capacity needed)
                      (flat-call "licdf_app_encrypt" :int32 handle :int32 scope-value
                                 :pointer input :int32 input-length
                                 :pointer buffer :int32 capacity :pointer needed)))))))

(defun app-decrypt (d packed)
  "Opens data sealed with APP-ENCRYPT."
  (let ((handle (handle-of d)))
    (with-octets (input input-length packed)
      (read-sized d "licdf_app_decrypt"
                  (lambda (buffer capacity needed)
                    (flat-call "licdf_app_decrypt" :int32 handle
                               :pointer input :int32 input-length
                               :pointer buffer :int32 capacity :pointer needed))))))
