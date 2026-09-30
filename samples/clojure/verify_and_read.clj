;; KeyNub SDK - Clojure sample: verify a dongle and read what it holds.
;;
;;     clojure -Sdeps '{:deps {com.keynub/keynub-licdongle-clj {:mvn/version "1.1.1"}}}' \
;;       -M samples/clojure/verify_and_read.clj      (from the repository root)
;;
;; Clojure 1.11 or later on Java 17 or later. Run from a clone, the library is
;; found in natives/<platform>/. Targets real hardware: with no dongle attached
;; it prints guidance and exits 0.
(require '[keynub.licdongle :as kn])

(defn report [d]
  (let [i (kn/info d)]
    (println (format "Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free."
                     (:protocol-major i) (:protocol-minor i)
                     (:firmware-major i) (:firmware-minor i) (:firmware-patch i)
                     (:data-free i) (:data-capacity i)))
    ;; The only trace a firmware hang leaves behind. Worth reporting to support.
    (when (:watchdog-reboot i)
      (println "WARNING: this dongle's previous boot ended in a watchdog reset.")))
  (let [g (kn/verify-genuine d)]
    (println (str "Genuine: yes (serial " (:serial g) ", provisioned " (:provisioned-date g) ")"))))

(defn read-records [s]
  (let [rs (kn/records s)]
    (println (count rs) "record(s) on the dongle:")
    (doseq [r rs]
      (println (format "  %-16s %d bytes" (:name r) (:size r))))
    ;; A missing record is a normal state, not an error.
    (when (some #(= "license" (:name %)) rs)
      (println "Read" (alength ^bytes (kn/read-record s "license")) "bytes from the license record."))))

;; The part that protects something. At licence-issue time you would call
;; app-encrypt once, with a developer dongle, and ship only the sealed data;
;; the program then cannot proceed without a dongle, because it holds no other
;; copy. :developer lets any dongle you have issued decrypt it, so one file
;; serves every customer; :device locks it to one dongle.
(defn protect-something [s]
  (let [needed "the data this program cannot run without"
        sealed (kn/app-encrypt s :developer needed)
        recovered (String. ^bytes (kn/app-decrypt s sealed) "UTF-8")]
    (println (str "App-crypto round trip: " (count needed) " bytes -> " (alength ^bytes sealed) " sealed -> "
                  (if (= recovered needed) "recovered intact" "MISMATCH")))))

(try
  (println (str "KeyNub library v" (kn/library-version)))
  (if (empty? (kn/devices))
    (println "Connect a KeyNub dongle and re-run.")
    (kn/with-dongle [d]                  ; the first dongle, or (kn/with-dongle [d serial] ...)
      (report d)
      (kn/with-session [s d]             ; closed on every exit path
        (read-records s)
        (protect-something s))))
  (catch clojure.lang.ExceptionInfo e
    (println "KeyNub error:" (ex-message e))
    (System/exit 1)))
