;; KeyNub SDK - Clojure sample: take ownership of a new dongle.
;;
;; A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
;; so that from the next session onward only your key can write records, erase
;; them or increment counters. Run it once per dongle, when it arrives.
;;
;; Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
;;
;;     openssl ecparam -name prime256v1 -genkey -noout |
;;       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
;;
;;     clojure -Sdeps '{:deps {com.keynub/keynub-licdongle-clj {:mvn/version "1.1.1"}}}' \
;;       -M samples/clojure/rotate_write_key.clj keys/keynub-shipping-writeauth.key.der my-key.der
;;
;; Clojure 1.11 or later on Java 17 or later. Targets real hardware: with no
;; dongle attached it prints guidance and exits 0.
;;
;; The replacement key is worth what your licence-signing key is worth. It
;; cannot be recovered from the dongle, and a unit rotated to a key you have
;; lost has to come back to be re-provisioned.
(require '[keynub.licdongle :as kn])
(import '(java.nio.file Files Paths))

(defn read-file ^bytes [path]
  (Files/readAllBytes (Paths/get path (make-array String 0))))

(when (not= 2 (count *command-line-args*))
  (println "usage: rotate_write_key <current-key.der> <new-key.der>")
  (System/exit 2))

(try
  (let [[current-path new-path] *command-line-args*
        current (read-file current-path)
        replacement (read-file new-path)]
    (if (empty? (kn/devices))
      (println "Connect a KeyNub dongle and re-run.")
      (kn/with-dongle [d]
        (println "Dongle" (kn/serial d))
        (when (:write-auth-rotated (kn/info d))
          (println "This dongle's write key has already been rotated away from the factory one."))
        (kn/with-session [s d]
          (kn/authorize-write! s current)          ; the key the dongle accepts today
          (kn/rotate-write-key! s replacement))    ; from the next session: only the new one
        (println "Write key rotated:" (if (:write-auth-rotated (kn/info d)) "yes" "no")))))
  (catch clojure.lang.ExceptionInfo e
    (println "KeyNub error:" (ex-message e))
    (System/exit 1))
  (catch java.io.IOException e
    (println "KeyNub error:" (.getMessage e))
    (System/exit 1)))
