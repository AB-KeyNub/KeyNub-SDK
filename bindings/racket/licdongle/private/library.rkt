#lang racket/base
;; Where the native library (keynub_licdongle_flat) comes from, and the table
;; of the flat C API's functions (bindings/flat/licd_flat.h).
;;
;; The path given to `set-library-path!`, then KEYNUB_LICDONGLE_FLAT_LIBRARY in
;; the environment, then natives/<platform>/ of an SDK clone from the program's
;; folder, the current directory and this package's folder upwards, then the
;; bare file name for the system loader. The library is loaded on the first
;; call that needs it, and a process loads it once.
(require ffi/unsafe
         racket/list
         racket/string
         "common.rkt")

(provide library-environment-variable
         native-folders
         library-basename
         library-candidates
         set-library-path!
         library-path
         loaded-library-path
         flat)

;; The environment variable that names the library file.
(define library-environment-variable "KEYNUB_LICDONGLE_FLAT_LIBRARY")

(define native-folders
  '("win-x64" "win-x86" "win-arm64" "linux-x64" "linux-arm64" "osx-x64" "osx-arm64"))

;; The library's file name on this operating system.
(define (library-basename)
  (case (system-type 'os)
    [(windows) "keynub_licdongle_flat.dll"]
    [(macosx) "libkeynub_licdongle_flat.dylib"]
    [else "libkeynub_licdongle_flat.so"]))

(define lock (make-semaphore 1))
(define chosen-path #f)
(define loaded-path #f)
(define api #f)

(define (->string p)
  (if (path? p) (path->string p) p))

;; Names the library file to load. Call it before the first dongle call.
(define (set-library-path! path)
  (define text (->string path))
  (call-with-semaphore
   lock
   (lambda ()
     (when (and loaded-path (not (string=? loaded-path text)))
       (raise-library-error
        (format "the KeyNub library is already loaded from ~a; a process loads it once" loaded-path)))
     (set! chosen-path text))))

;; The path of the loaded library; #f before the first call.
(define (loaded-library-path)
  (call-with-semaphore lock (lambda () loaded-path)))

;; The path in use, or the first candidate when nothing is loaded yet.
(define (library-path)
  (call-with-semaphore lock (lambda () (or loaded-path (first (library-candidates))))))

;; The folder of the running program, when it is known.
(define (program-folder)
  (define run (find-system-path 'run-file))
  (define full
    (cond
      [(complete-path? run) run]
      [(find-executable-path run) => values]
      [else #f]))
  (and full
       (let-values ([(base name dir?) (split-path full)])
         (and (path? base) base))))

;; The folder this module was loaded from, when it is a file.
(define (package-folder)
  (define source (variable-reference->module-source (#%variable-reference)))
  (and (path? source)
       (complete-path? source)
       (let-values ([(base name dir?) (split-path source)])
         (and (path? base) base))))

;; The paths tried, in order.
(define (library-candidates)
  (define from-environment (getenv library-environment-variable))
  (cond
    [chosen-path (list chosen-path)]
    [(and from-environment (not (string=? from-environment ""))) (list from-environment)]
    [else
     (define base (library-basename))
     (define starts
       (remove-duplicates
        (for/list ([start (in-list (list (program-folder) (current-directory) (package-folder)))]
                   #:when start)
          (simplify-path (path->complete-path start)))))
     (define found
       (for*/list ([start (in-list starts)]
                   [dir (in-list (folder-and-parents start))]
                   [folder (in-list native-folders)]
                   #:when (file-exists? (build-path dir "natives" folder base)))
         (path->string (build-path dir "natives" folder base))))
     (append (remove-duplicates found) (list base))]))

(define (folder-and-parents dir)
  (let loop ([dir dir] [acc '()])
    (define-values (parent name dir?) (split-path dir))
    (if (path? parent)
        (loop parent (cons dir acc))
        (reverse (cons dir acc)))))

;; ---- the flat API -------------------------------------------------------

;; Every function of the flat API: its C name and its signature. Integer
;; out-parameters come back as extra values after the status code.
(define functions
  (list
   (cons 'licdf_version
         (_fun (a : (_ptr o _int32)) (b : (_ptr o _int32)) (c : (_ptr o _int32))
               -> (rc : _int32) -> (values rc a b c)))
   (cons 'licdf_device_count
         (_fun (n : (_ptr o _int32)) -> (rc : _int32) -> (values rc n)))
   (cons 'licdf_device_serial (_fun _int32 _bytes _int32 -> _int32))
   (cons 'licdf_device_path (_fun _int32 _bytes _int32 -> _int32))
   (cons 'licdf_open (_fun _string/utf-8 -> _int32))
   (cons 'licdf_open_path (_fun _string/utf-8 -> _int32))
   (cons 'licdf_close (_fun _int32 -> _int32))
   (cons 'licdf_set_trust_root (_fun _int32 _bytes _int32 -> _int32))
   (cons 'licdf_get_serial (_fun _int32 _bytes _int32 -> _int32))
   (cons 'licdf_get_info
         (_fun _int32
               (pa : (_ptr o _int32)) (pb : (_ptr o _int32))
               (fa : (_ptr o _int32)) (fb : (_ptr o _int32)) (fc : (_ptr o _int32))
               (flags : (_ptr o _int32)) (capacity : (_ptr o _int32)) (free : (_ptr o _int32))
               -> (rc : _int32) -> (values rc pa pb fa fb fc flags capacity free)))
   (cons 'licdf_verify_genuine
         (_fun _int32 (genuine : (_ptr o _int32)) _bytes _int32 _bytes _int32
               -> (rc : _int32) -> (values rc genuine)))
   (cons 'licdf_session_open (_fun _int32 -> _int32))
   (cons 'licdf_session_close (_fun _int32 -> _int32))
   (cons 'licdf_write_auth (_fun _int32 _bytes _int32 -> _int32))
   (cons 'licdf_write_auth_rotate (_fun _int32 _bytes _int32 -> _int32))
   (cons 'licdf_record_count
         (_fun _int32 (n : (_ptr o _int32)) -> (rc : _int32) -> (values rc n)))
   (cons 'licdf_record_name
         (_fun _int32 _int32 _bytes _int32 (size : (_ptr o _int32))
               -> (rc : _int32) -> (values rc size)))
   (cons 'licdf_record_size
         (_fun _int32 _string/utf-8 (size : (_ptr o _int32)) -> (rc : _int32) -> (values rc size)))
   (cons 'licdf_record_read
         (_fun _int32 _string/utf-8 _bytes _int32 (n : (_ptr o _int32))
               -> (rc : _int32) -> (values rc n)))
   (cons 'licdf_record_write (_fun _int32 _string/utf-8 _bytes _int32 -> _int32))
   (cons 'licdf_record_erase (_fun _int32 _string/utf-8 -> _int32))
   (cons 'licdf_record_erase_all (_fun _int32 -> _int32))
   (cons 'licdf_counter_read
         (_fun _int32 _int32 (v : (_ptr o _int32)) -> (rc : _int32) -> (values rc v)))
   (cons 'licdf_counter_increment
         (_fun _int32 _int32 (v : (_ptr o _int32)) -> (rc : _int32) -> (values rc v)))
   (cons 'licdf_app_encrypt
         (_fun _int32 _int32 _bytes _int32 _bytes _int32 (n : (_ptr o _int32))
               -> (rc : _int32) -> (values rc n)))
   (cons 'licdf_app_decrypt
         (_fun _int32 _bytes _int32 _bytes _int32 (n : (_ptr o _int32))
               -> (rc : _int32) -> (values rc n)))
   (cons 'licdf_strerror (_fun _int32 _bytes _int32 -> _int32))
   (cons 'licdf_last_error (_fun _int32 _bytes _int32 -> _int32))))

;; A table of every function from the library at `path`, or the reason it
;; cannot be used.
(define (try-load path)
  (with-handlers ([exn:fail? exn-message])
    (define lib (ffi-lib path))
    (let loop ([rest functions] [table (hasheq)])
      (cond
        [(null? rest) table]
        [else
         (define name (car (car rest)))
         (define proc (get-ffi-obj name lib (cdr (car rest)) (lambda () #f)))
         (if proc
             (loop (cdr rest) (hash-set table name proc))
             (format "does not export ~a" name))]))))

(define (load-library)
  (let loop ([candidates (library-candidates)] [reasons '()])
    (cond
      [(null? candidates)
       (raise-library-error
        (format "cannot load the KeyNub library; tried ~a" (string-join (reverse reasons) ", ")))]
      [else
       (define path (car candidates))
       (define result (try-load path))
       (cond
         [(hash? result)
          (set! loaded-path path)
          result]
         [else (loop (cdr candidates) (cons (format "~a (~a)" path result) reasons))])])))

;; The function `name` of the flat API, loading the library on the first call.
(define (flat name)
  (define table
    (or api
        (call-with-semaphore
         lock
         (lambda ()
           (unless api
             (set! api (load-library)))
           api))))
  (hash-ref table name))
