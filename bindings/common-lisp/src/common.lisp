;;;; common.lisp -- the SDK's status codes, the conditions the binding signals
;;;; and the helpers that turn C buffers into Lisp values.

(in-package #:keynub-licdongle)

(defparameter *status-codes*
  '((:ok . 0)
    (:invalid-arg . -1)
    (:no-device . -2)
    (:access-denied . -3)
    (:io . -4)
    (:timeout . -5)
    (:protocol . -6)
    (:not-genuine . -7)
    (:cert-invalid . -8)
    (:session-expired . -9)
    (:tag-mismatch . -10)
    (:range . -11)
    (:storage-full . -12)
    (:busy . -13)
    (:not-found . -14)
    (:auth-required . -15)
    (:fw-incompatible . -16)
    (:sdk-too-old . -17)
    (:cancelled . -18)
    (:not-implemented . -19)
    (:internal . -20))
  "The names of the SDK's status codes and their values.")

(defun status-keyword (code)
  "The keyword naming a status code, or NIL for a code this binding does not know."
  (car (rassoc code *status-codes*)))

(defun status-code (keyword)
  "The value of a status keyword, or NIL for a keyword this binding does not know."
  (cdr (assoc keyword *status-codes*)))

(defun status-name (code)
  (string-downcase (symbol-name (or (status-keyword code) :unknown))))

(define-condition licdongle-error (error)
  ((status :initarg :status :initform nil :reader licdongle-error-status
           :documentation "The status keyword, or NIL for a code this binding does not know.")
   (code :initarg :code :initform nil :reader licdongle-error-code
         :documentation "The raw status code.")
   (operation :initarg :operation :initform "" :reader licdongle-error-operation
              :documentation "The flat API function that failed.")
   (detail :initarg :detail :initform "" :reader licdongle-error-detail
           :documentation "The library's detail text; may be empty."))
  (:report (lambda (condition stream)
             (let ((detail (licdongle-error-detail condition)))
               (format stream "~a: ~a (~a)~:[~;: ~a~]"
                       (licdongle-error-operation condition)
                       (status-name (licdongle-error-code condition))
                       (licdongle-error-code condition)
                       (plusp (length detail))
                       detail))))
  (:documentation "A failed dongle call: \"operation: status (code)\", followed by
\": detail\" when the library gave one."))

(define-condition licdongle-library-error (licdongle-error)
  ()
  (:report (lambda (condition stream)
             (write-string (licdongle-error-detail condition) stream)))
  (:documentation "The native library could not be loaded, or does not fit. Its
status and code are NIL; the detail says what was tried."))

(defun make-licdongle-error (operation code &optional (detail ""))
  (make-condition 'licdongle-error :status (status-keyword code) :code code
                                   :operation operation :detail detail))

(defun library-error (control &rest arguments)
  (error 'licdongle-library-error :operation "load"
                                  :detail (apply #'format nil control arguments)))

(deftype octets () '(vector (unsigned-byte 8)))

(defun make-octets (length)
  (make-array length :element-type '(unsigned-byte 8) :initial-element 0))

(defun c-string (octets)
  "The text before the first NUL byte of OCTETS (all of it when there is none),
decoded as UTF-8; bytes that are not UTF-8 become U+FFFD."
  (let ((end (or (position 0 octets) (length octets))))
    (babel:octets-to-string (coerce octets '(simple-array (unsigned-byte 8) (*)))
                            :end end :encoding :utf-8 :errorp nil)))
