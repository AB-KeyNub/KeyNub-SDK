(ns keynub.licdongle.standin-test
  "Every function of keynub.licdongle against a stand-in for the C ABI
  (bindings/julia/test/stub/licd_stub.c): one imaginary dongle held in memory,
  compiled into a shared library in the temp directory with the first C
  compiler found of cc, gcc, clang, zig cc and cl. The stand-in keeps records,
  counters and the write key per opened device, so each test starts from a
  fresh dongle.

      mvn test                       (in bindings/clojure)
      clojure -M:test

  KEYNUB_SDK_ROOT names the SDK sources when the test does not run inside a
  clone; KEYNUB_LICDONGLE_LIBRARY names an already compiled stand-in."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is run-tests testing]]
            [keynub.licdongle :as kn])
  (:import (clojure.lang ExceptionInfo)
           (com.keynub.licdongle DeviceNotFoundException Dongle Session)
           (java.io File IOException)
           (java.util Arrays)))

(set! *warn-on-reflection* true)

;; --- the stand-in -----------------------------------------------------------

(defn- sdk-root ^File []
  (if-let [given (not-empty (System/getenv "KEYNUB_SDK_ROOT"))]
    (io/file given)
    (loop [dir (.getAbsoluteFile (io/file (System/getProperty "user.dir")))]
      (cond (nil? dir) (throw (IllegalStateException.
                                "the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT"))
            (.isFile (io/file dir "bindings" "flat" "licd_flat.c")) dir
            :else (recur (.getParentFile dir))))))

(defn- succeeds? [^File dir command]
  (try
    (let [p (-> (ProcessBuilder. ^java.util.List command)
                (.directory dir)
                (.redirectErrorStream true)
                (.start))]
      (slurp (.getInputStream p))
      (zero? (.waitFor p)))
    (catch IOException _
      false)))

(defn- build-standin []
  (let [root (sdk-root)
        os (str/lower-case (System/getProperty "os.name"))
        windows (str/starts-with? os "windows")
        dir (io/file (System/getProperty "java.io.tmpdir") "keynub-standin-clojure")
        ;; Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf name.
        out (io/file dir (cond windows "keynub_licdongle_standin.dll"
                               (str/includes? os "mac") "libkeynub_licdongle_standin.dylib"
                               :else "libkeynub_licdongle_standin.so"))
        include (let [core (io/file root "core" "include")]
                  (if (.isFile (io/file core "licdongle.h")) core (io/file root "include")))
        source (io/file root "bindings" "julia" "test" "stub" "licd_stub.c")
        gcc (cond-> ["-shared" "-O1" "-DLICD_BUILD_SHARED" (str "-I" include) "-o" (str out) (str source)]
              (not windows) (conj "-fPIC"))
        cl ["/nologo" "/LD" "/O1" "/DLICD_BUILD_SHARED" (str "/I" include) (str "/Fe:" out) (str source)]]
    (.mkdirs dir)
    (or (some (fn [command] (when (and (succeeds? dir command) (.isFile out)) (str out)))
              [(into ["cc"] gcc) (into ["gcc"] gcc) (into ["clang"] gcc) (into ["zig" "cc"] gcc) (into ["cl"] cl)])
        (throw (IllegalStateException.
                 "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path")))))

;; --- helpers ----------------------------------------------------------------

(def serial "04A1B2C3D4E5F6")
(def factory-key (byte-array (map unchecked-byte [0x30 0x10 0x01 0x02 0x03])))
(def replacement-key (byte-array (map unchecked-byte [0x30 0x11 0x09 0x08 0x07 0x06])))

(defn- utf8 ^bytes [^String s] (.getBytes s "UTF-8"))

(defn- same? [a b] (Arrays/equals ^bytes a ^bytes b))

(defn- failure
  "The ex-info that (f) throws, or nil."
  [f]
  (try
    (f)
    nil
    (catch ExceptionInfo e
      e)))

(defn- status
  "The ::kn/status of what (f) throws, or :nothing."
  [f]
  (if-let [e (failure f)] (::kn/status (ex-data e)) :nothing))

(defn- throws-iae? [f]
  (try
    (f)
    false
    (catch IllegalArgumentException _
      true)))

;; --- the tests --------------------------------------------------------------

(deftest devices-and-open
  (is (= "9.8.7" (kn/library-version)))
  (is (= [{:serial serial :path "stub:0" :vendor-id 0x1234 :product-id 0xABCD}] (kn/devices)))
  (let [e (failure #(kn/open "nope"))
        data (ex-data e)]
    (is (= :no-device (::kn/status data)))
    (is (= -2 (::kn/code data)))
    (is (= "no dongle with that serial" (::kn/detail data)))
    (is (str/includes? (ex-message e) "no device") "the message carries the status text")
    (is (instance? DeviceNotFoundException (ex-cause e)) "the Java exception is the cause"))
  (is (= "no dongle with that serial" (kn/last-error-detail)))
  (is (= :no-device (status #(kn/open-path "stub:9"))))
  (kn/with-dongle [d]
    (is (instance? Dongle d))
    (is (= serial (kn/serial d))))
  (kn/with-dongle [d serial]
    (is (= serial (kn/serial d))))
  (let [d (kn/open-path "stub:0")]
    (is (= serial (kn/serial d)))
    (kn/close d)
    (kn/close d))
  (is (throws-iae? #(kn/close :not-a-dongle)))
  (is (= (kn/library-path) (kn/set-library-path! (kn/library-path))) "naming the loaded library again is allowed")
  (is (= :invalid-argument (status #(kn/set-library-path! "some/other/library"))) "a second library is refused"))

(deftest info-and-genuine
  (let [d (kn/open)]
    (is (= {:protocol-major 1 :protocol-minor 0 :firmware-major 2 :firmware-minor 3 :firmware-patch 4
            :se-ready true :provisioned true :data-capacity (* 1024 1024) :data-free 1000000
            :watchdog-reboot false :isolated true :write-auth-rotated false}
           (kn/info d)))
    (is (true? (kn/genuine? d)))
    (is (= {:genuine true :serial serial :provisioned-date "2026-08-15"} (kn/verify-genuine d)))
    (kn/close d)
    (is (false? (kn/genuine? d)) "genuine? fails closed on a closed dongle")))

(deftest records-and-write-role
  (kn/with-dongle [d]
    (kn/with-session [s d]
      (let [payload "license-blob-0123456789"]
        (is (= :auth-required (status #(kn/write-record! s "lic" payload))))
        (is (= :auth-required (status #(kn/erase-record! s "lic"))))
        (is (= :auth-required (status #(kn/erase-all-records! s))))
        (is (= :auth-required (status #(kn/increment-counter! s 0))))
        (is (= :not-genuine (status #(kn/authorize-write! s (byte-array [0x30 0x00])))))

        (kn/authorize-write! s factory-key)
        (kn/write-record! s "lic" payload)
        (is (same? (utf8 payload) (kn/read-record s "lic")))
        (kn/write-record! s "cfg" (utf8 "cfgdata"))
        (let [rs (sort-by :name (kn/records s))]
          (is (= ["cfg" "lic"] (map :name rs)))
          (is (= (count payload) (:size (second rs)))))
        (is (same? (utf8 "cfgdata") (kn/read-record s "cfg")))
        (is (= :not-found (status #(kn/read-record s "nope"))))
        (is (= :not-found (status #(kn/erase-record! s "nope"))))

        (testing "an empty name is refused, never passed on as erase everything"
          (is (throws-iae? #(kn/read-record s "")))
          (is (throws-iae? #(kn/erase-record! s "")))
          (is (= 2 (count (kn/records s)))))
        (kn/erase-record! s "cfg")
        (is (= ["lic"] (map :name (kn/records s))))

        (kn/write-record! s "empty" (byte-array 0))
        (is (zero? (alength ^bytes (kn/read-record s "empty"))))
        (kn/write-record! s "empty" "")
        (is (zero? (alength ^bytes (kn/read-record s "empty"))))
        (is (throws-iae? #(kn/write-record! s "bad" 42)) "a number is not record data")

        (testing "bigger than one transfer chunk, with progress and cancellation"
          (let [big (byte-array (map #(unchecked-byte (+ 5 (* 31 %))) (range 3000)))
                writes (atom [])
                reads (atom [])]
            (kn/write-record! s "big" big (fn [done total] (swap! writes conj [done total]) true))
            (is (= [3000 3000] (peek @writes)))
            (is (same? big (kn/read-record s "big" (fn [done total] (swap! reads conj [done total]) true))))
            (is (= [3000 3000] (peek @reads)))
            (is (= :cancelled (status #(kn/read-record s "big" (fn [_ _] false)))))
            (is (= :cancelled (status #(kn/write-record! s "big2" big (fn [_ _] false)))))
            (is (same? big (kn/read-record s "big" (fn [_ _] nil))) "nil from the progress function continues")
            (is (same? big (kn/read-record s "big")) "the dongle is usable afterwards")))

        (kn/erase-all-records! s)
        (is (empty? (kn/records s)))))))

(deftest counters
  (kn/with-dongle [d]
    (kn/with-session [s d]
      (kn/authorize-write! s factory-key)
      (let [before (kn/read-counter s 0)]
        (is (= (inc before) (kn/increment-counter! s 0)))
        (is (= (inc before) (kn/read-counter s 0))))
      (is (zero? (kn/read-counter s 1)))
      (is (= :range (status #(kn/read-counter s 7))))
      (is (= :range (status #(kn/increment-counter! s 7)))))))

(deftest app-crypto
  (kn/with-dongle [d]
    (kn/with-session [s d]
      (let [secret (byte-array (map #(unchecked-byte (mod (+ 7 (* 3 %)) 256)) (range 100)))]
        (doseq [[scope code] [[:device 0] [:developer 1]]]
          (let [^bytes blob (kn/app-encrypt s scope secret)]
            (is (> (alength blob) (alength ^bytes secret)))
            (is (= code (aget blob 0)) "the envelope names its scope")
            (is (same? secret (kn/app-decrypt s blob)))
            (let [^bytes tampered (aclone blob)
                  last-index (dec (alength tampered))]
              (aset-byte tampered last-index (unchecked-byte (bit-xor (aget tampered last-index) 1)))
              (is (= :tag-mismatch (status #(kn/app-decrypt s tampered)))))))
        (is (= "the data" (String. (kn/app-decrypt s (kn/app-encrypt s :developer "the data")) "UTF-8")))
        (is (zero? (alength ^bytes (kn/app-decrypt s (kn/app-encrypt s :device (byte-array 0))))))
        (is (throws-iae? #(kn/app-encrypt s :everyone secret)) "an unknown scope is refused")))))

(deftest write-key-rotation
  (kn/with-dongle [d]
    (kn/with-session [s d]
      (is (= :auth-required (status #(kn/rotate-write-key! s replacement-key))))
      (kn/authorize-write! s factory-key)
      (kn/rotate-write-key! s replacement-key)
      (kn/write-record! s "lic" "still-writable"))
    (is (true? (:write-auth-rotated (kn/info d))))
    (kn/with-session [s d]
      (is (= :not-genuine (status #(kn/authorize-write! s factory-key))) "the factory key no longer elevates")
      (kn/authorize-write! s replacement-key)
      (kn/write-record! s "lic" "new-key-writes")
      (is (same? (utf8 "new-key-writes") (kn/read-record s "lic"))))))

(deftest session-lifetime
  (let [d (kn/open)
        kept (atom nil)]
    (is (= 42 (kn/with-session [s d] (reset! kept s) 42)) "with-session returns the value of its body")
    (is (.isClosed ^Session @kept) "and closes the session")
    (is (= "inside" (try
                      (kn/with-session [s d] (reset! kept s) (throw (ex-info "inside" {})))
                      (catch ExceptionInfo e (ex-message e))))
        "an exception inside with-session propagates")
    (is (.isClosed ^Session @kept) "and the session is closed after it")
    (let [stale (kn/open-session d)
          s (kn/open-session d)]
      (kn/close s)
      (is (= :session-expired (status #(kn/records stale))) "a new session ends the one before it")
      (kn/close stale)
      (kn/close s)
      (is (.isClosed s))
      (is (try (kn/read-counter s 0) false (catch IllegalStateException _ true)) "a closed session refuses calls"))
    (let [orphan (kn/open-session d)]
      (kn/close d)
      (is (try (kn/records orphan) false (catch IllegalStateException _ true)) "a session ends with its dongle")
      (kn/close orphan))
    (kn/close d)))

(deftest trust-root
  (kn/with-dongle [d]
    (is (= :certificate-invalid (status #(kn/set-trust-root! (byte-array [0x02 0x01 0x00])))))
    (let [root (byte-array 132)]
      (aset-byte root 0 0x30)
      (aset-byte root 1 (unchecked-byte 0x82))
      (aset-byte root 2 0x01)
      (aset-byte root 3 0x00)
      (doseq [k (range 4 132)] (aset-byte root k (unchecked-byte 0xAB)))
      (kn/set-trust-root! root)
      (is (= :certificate-invalid (status #(kn/verify-genuine d))))
      (is (false? (kn/genuine? d)))
      (doseq [k (range 4 132)] (aset-byte root k 0x01))
      (kn/set-trust-root! root)
      (is (true? (kn/genuine? d))))))

;; The trust root belongs to the one context of the process, so its test runs last.
(defn test-ns-hook []
  (devices-and-open)
  (info-and-genuine)
  (records-and-write-role)
  (counters)
  (app-crypto)
  (write-key-rotation)
  (session-lifetime)
  (trust-root))

(defn -main [& _]
  (kn/set-library-path! (or (not-empty (System/getenv "KEYNUB_LICDONGLE_LIBRARY")) (build-standin)))
  (let [{:keys [fail error]} (run-tests 'keynub.licdongle.standin-test)]
    (if (zero? (+ fail error))
      (do (println "keynub-licdongle-clj: every call passed against the ABI stand-in"
                   (str "(Clojure " (clojure-version) ")"))
          (shutdown-agents)
          (System/exit 0))
      (System/exit 1))))
