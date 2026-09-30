(ns keynub.licdongle
  "Client for the KeyNub USB license dongle, over the Java binding
  com.keynub/keynub-licdongle (JNA).

  Dongles and sessions are the Java binding's Dongle and Session objects;
  results are maps and vectors; record data and keys are byte arrays, and the
  functions that take data also take a string, used as its UTF-8 bytes. Every
  failure the native library reports is thrown as an ex-info whose data has
  ::status (a keyword such as :no-device), ::code and ::detail, with the Java
  exception as its cause."
  (:require [clojure.java.io :as io]
            [clojure.string :as str])
  (:import (com.keynub.licdongle DeviceInfo Dongle DongleInfo GenuineResult LicenseDongleContext
                                 LicenseDongleException OperationCancelledException ProgressCallback
                                 RecordInfo Scope Session TransferProgress)
           (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

;; --- the native library -----------------------------------------------------

(def ^:private library-property
  "The system property the Java binding loads the native library from."
  "keynub.licdongle.library")

(defn- platform
  "The natives/<platform> folder name of the SDK repository, and the library's
  file name, for this JVM."
  []
  (let [os (str/lower-case (System/getProperty "os.name"))
        arch (str/lower-case (System/getProperty "os.arch"))
        cpu (cond (#{"amd64" "x86_64"} arch) "x64"
                  (#{"aarch64" "arm64"} arch) "arm64"
                  (#{"x86" "i386" "i486" "i586" "i686"} arch) "x86"
                  :else arch)]
    (cond (str/starts-with? os "windows") [(str "win-" cpu) "keynub_licdongle.dll"]
          (or (str/starts-with? os "mac") (str/includes? os "darwin")) [(str "osx-" cpu) "libkeynub_licdongle.dylib"]
          :else [(str "linux-" cpu) "libkeynub_licdongle.so"])))

(defn- find-in-clone
  "In a clone of the SDK repository the library sits in natives/<platform>; the
  working directory, or one of its parents, is that clone when a sample runs."
  []
  (let [[folder file] (platform)]
    (loop [dir (.getAbsoluteFile (io/file (System/getProperty "user.dir"))) n 0]
      (when (and dir (< n 8))
        (let [candidate (io/file dir "natives" folder file)]
          (if (.isFile candidate)
            (.getPath candidate)
            (recur (.getParentFile dir) (inc n))))))))

(def ^:private chosen
  "The library this process uses, chosen once, before the Java binding's first
  call: the system property if it is set, else KEYNUB_LICDONGLE_LIBRARY, else
  natives/<platform> of a clone, else nil for the bare name that JNA resolves
  along jna.library.path and the system search path."
  (delay
    (or (not-empty (System/getProperty library-property))
        (when-let [path (or (not-empty (System/getenv "KEYNUB_LICDONGLE_LIBRARY")) (find-in-clone))]
          (System/setProperty library-property path)
          path))))

(defn set-library-path!
  "Names the native library file to load. Must come before the first call that
  needs the library; a process loads it once. Returns the path."
  [path]
  (when (realized? chosen)
    (when-not (= path @chosen)
      (throw (ex-info (str "the KeyNub library is already chosen: " (or @chosen "keynub_licdongle")
                           "; a process loads it once")
                      {::status :invalid-argument ::code -1 ::detail ""}))))
  (System/setProperty library-property path)
  path)

(defn library-path
  "The library file this process loads, or nil when JNA resolves the bare name
  keynub_licdongle along its search path."
  []
  @chosen)

;; --- errors -----------------------------------------------------------------

(defn- status-keyword [status]
  (keyword (str/replace (str/lower-case (str status)) "_" "-")))

(defn- ->ex-info [^LicenseDongleException e]
  (let [status (.getStatus e)]
    (ex-info (.getMessage e)
             {::status (status-keyword status)
              ::code (.code status)
              ::detail (or (.getDetail e) "")}
             e)))

(defmacro ^:private licd
  "Evaluates body; a failure the native library reports becomes an ex-info."
  [& body]
  `(try
     ~@body
     (catch LicenseDongleException e#
       (throw (->ex-info e#)))
     (catch OperationCancelledException e#
       (throw (ex-info (.getMessage e#) {::status :cancelled ::code -18 ::detail ""} e#)))))

(defn- ->bytes ^bytes [x what]
  (cond (bytes? x) x
        (string? x) (.getBytes ^String x StandardCharsets/UTF_8)
        :else (throw (IllegalArgumentException. (str what " must be a byte array or a string")))))

(defn- ->name ^String [name]
  (when-not (and (string? name) (seq name))
    (throw (IllegalArgumentException. "the record name must be a non-empty string")))
  name)

;; --- library and context ----------------------------------------------------

(def ^:private context-lock (Object.))
(def ^:private context-ref (atom nil))

(defn- context ^LicenseDongleContext []
  @chosen
  (locking context-lock
    (or @context-ref
        (reset! context-ref (licd (LicenseDongleContext.))))))

(defn library-version
  "The version of the native library, which is the SDK version it was built
  from, as a string such as \"1.1.1\"."
  []
  @chosen
  (licd (LicenseDongleContext/libraryVersion)))

(defn last-error-detail
  "The native library's diagnostic text for the last call that failed on this
  thread, \"\" when it succeeded. The same text is ::detail of the ex-info."
  []
  (.lastErrorDetail (context)))

(defn set-trust-root!
  "Replaces the root certificate (DER bytes) that dongle certificates are
  verified against, for every later verification in this process.
  Applications do not need this: the native library embeds the KeyNub
  production root."
  [der]
  (licd (.setTrustRoot (context) (->bytes der "der")))
  nil)

;; --- dongles ----------------------------------------------------------------

(defn- device->map [^DeviceInfo d]
  {:serial (.serial d) :path (.path d) :vendor-id (.vendorId d) :product-id (.productId d)})

(defn devices
  "The attached dongles, without opening any: a vector of maps with :serial,
  :path (the operating system's device path, for open-path), :vendor-id and
  :product-id."
  []
  (mapv device->map (licd (.enumerate (context)))))

(defn open
  "Opens the first attached dongle, or the one with the given serial. Close it
  with close, or use with-dongle."
  (^Dongle [] (licd (.open (context))))
  (^Dongle [serial] (licd (.open (context) ^String serial))))

(defn open-path
  "Opens the dongle at a device path from devices."
  ^Dongle [path]
  (licd (.openPath (context) ^String path)))

(defn close
  "Closes a dongle (and the session on it) or a session. Safe to call more
  than once."
  [x]
  (cond (instance? Dongle x) (.close ^Dongle x)
        (instance? Session x) (.close ^Session x)
        :else (throw (IllegalArgumentException. "close takes a dongle or a session")))
  nil)

(defmacro with-dongle
  "(with-dongle [d] body...) or (with-dongle [d serial] body...): opens the first
  dongle, or the one with that serial, binds it to d, evaluates body and closes
  the dongle on every exit path. Returns the value of body."
  [[sym serial] & body]
  `(let [~sym ~(if serial `(open ~serial) `(open))]
     (try
       ~@body
       (finally
         (close ~sym)))))

(defn info
  "The dongle's protocol and firmware versions, storage and status flags."
  [^Dongle dongle]
  (let [^DongleInfo i (licd (.getInfo dongle))]
    {:protocol-major (.protocolMajor i) :protocol-minor (.protocolMinor i)
     :firmware-major (.firmwareMajor i) :firmware-minor (.firmwareMinor i) :firmware-patch (.firmwarePatch i)
     :se-ready (.seReady i) :provisioned (.provisioned i)
     :data-capacity (.dataCapacity i) :data-free (.dataFree i)
     :watchdog-reboot (.watchdogReboot i) :isolated (.isolated i)
     :write-auth-rotated (.writeauthRotated i)}))

(defn serial
  "The dongle's serial, a hex string."
  [^Dongle dongle]
  (licd (.getSerial dongle)))

(defn verify-genuine
  "Proves that the dongle is genuine: verifies its certificate chain against the
  trusted root and runs a live challenge-response against the key inside it.
  Returns {:genuine true :serial ... :provisioned-date \"YYYY-MM-DD\"}; a dongle
  that fails throws with ::status :not-genuine or :certificate-invalid."
  [^Dongle dongle]
  (let [^GenuineResult g (licd (.verifyGenuine dongle))]
    {:genuine (.genuine g) :serial (.serial g) :provisioned-date (.provisionedDate g)}))

(defn genuine?
  "true when the dongle proves genuine, false otherwise. Fails closed: every
  failure, a closed dongle included, gives false.

  (when-not (genuine? d) (System/exit 1)) is one form to delete. Put data the
  program needs through app-encrypt, and ship only the sealed form."
  [^Dongle dongle]
  (try
    (.genuine (.verifyGenuine dongle))
    (catch Throwable _
      false)))

;; --- sessions ---------------------------------------------------------------

(defn open-session
  "Opens the encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM) that
  records, counters and app-crypto need. A dongle has one session at a time:
  opening another ends the one before it. Close it with close, or use
  with-session; closing the dongle ends it too."
  ^Session [^Dongle dongle]
  (licd (.openSession dongle)))

(defmacro with-session
  "(with-session [s dongle] body...): opens a session on the dongle, binds it to
  s, evaluates body and closes the session on every exit path. Returns the
  value of body."
  [[sym dongle] & body]
  `(let [~sym (open-session ~dongle)]
     (try
       ~@body
       (finally
         (close ~sym)))))

(defn authorize-write!
  "Unlocks writing, erasing and counter increments for the rest of the session
  with the dongle's write key, a P-256 private key in PKCS#8 DER. This belongs
  in your licence-issuing tooling; never ship that key with what your users
  run. A key the dongle does not accept throws with ::status :not-genuine."
  [^Session session key]
  (licd (.authorizeWrite session (->bytes key "key")))
  nil)

(defn rotate-write-key!
  "Replaces the dongle's write key with one you hold (PKCS#8 DER). Needs the
  write role, so authorize-write! with the current key first. The session keeps
  the write role; from the next session on only the new key elevates. Do this
  once per dongle, when it arrives: the factory key is public."
  [^Session session key]
  (licd (.rotateWriteKey session (->bytes key "key")))
  nil)

(defn- progress-callback
  "A ProgressCallback over (f done total); false from f cancels, anything else
  continues."
  [f]
  (when f
    (reify ProgressCallback
      (onProgress [_ p]
        (let [^TransferProgress p p]
          (not (false? (f (.bytesTransferred p) (.totalBytes p)))))))))

(defn records
  "The records on the dongle: a vector of maps with :name and :size (bytes)."
  [^Session session]
  (mapv (fn [^RecordInfo r] {:name (.name r) :size (.size r)})
        (licd (.listRecords session))))

(defn read-record
  "Reads a record as a byte array; (String. bytes \"UTF-8\") gives text back.
  progress, if given, is called as (progress done total) in bytes and cancels
  the transfer by returning false. A record that does not exist throws with
  ::status :not-found."
  (^bytes [session name] (read-record session name nil))
  (^bytes [^Session session name progress]
   (licd (.readRecord session (->name name) ^ProgressCallback (progress-callback progress)))))

(defn write-record!
  "Creates or replaces a record atomically. data is a byte array, or a string
  stored as UTF-8. Needs the write role (authorize-write!)."
  ([session name data] (write-record! session name data nil))
  ([^Session session name data progress]
   (licd (.writeRecord session (->name name) (->bytes data "data") ^ProgressCallback (progress-callback progress)))
   nil))

(defn erase-record!
  "Erases one record. Needs the write role."
  [^Session session name]
  (licd (.eraseRecord session (->name name)))
  nil)

(defn erase-all-records!
  "Erases every record on the dongle. Needs the write role. erase-record!
  refuses an empty name, so it never erases more than one record."
  [^Session session]
  (licd (.eraseAllRecords session))
  nil)

;; --- counters ---------------------------------------------------------------

(defn read-counter
  "Reads a monotonic counter (an integer id from 0 upwards)."
  [^Session session id]
  (licd (.readCounter session (int id))))

(defn increment-counter!
  "Increments a monotonic counter and returns its new value. Needs the write
  role; an increment cannot be undone."
  [^Session session id]
  (licd (.incrementCounter session (int id))))

;; --- data only a dongle can decrypt -----------------------------------------

(defn- ->scope ^Scope [scope]
  (case scope
    :device Scope/DEVICE
    :developer Scope/DEVELOPER
    (throw (IllegalArgumentException. "scope must be :device or :developer"))))

(defn app-encrypt
  "Encrypts data (a byte array, or a string as UTF-8) so that only a dongle can
  decrypt it, and returns the sealed bytes. The pair to build a licence check
  on: put something the program needs through this and ship only the sealed
  form, so removing the check removes the data. :developer lets any dongle you
  have issued decrypt it; :device locks it to the one dongle that sealed it."
  ^bytes [^Session session scope data]
  (licd (.appEncrypt session (->scope scope) (->bytes data "data"))))

(defn app-decrypt
  "Decrypts data from app-encrypt; returns the plaintext bytes."
  ^bytes [^Session session sealed]
  (licd (.appDecrypt session (->bytes sealed "sealed"))))
