(lang dune 3.0)
(name keynub-licdongle)
(generate_opam_files true)

(source (github AB-KeyNub/KeyNub-SDK))
(license Apache-2.0)
(authors "KeyNub")
(maintainers "KeyNub <info@keynub.com>")
(homepage "https://www.keynub.com/developers/ocaml/")
(bug_reports "https://github.com/AB-KeyNub/KeyNub-SDK/issues")
(documentation "https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/bindings/ocaml/README.md")

(package
 (name keynub-licdongle)
 (synopsis "Client for the KeyNub USB license dongle")
 (description
  "Verify that a KeyNub USB license dongle is genuine, read and write the license records it stores, use its hardware counters and encrypt data so that only a dongle can decrypt it. Pure OCaml over the SDK's flat C API through ctypes-foreign: the native library is loaded at run time, nothing is linked.")
 (depends
  (ocaml (>= 4.08))
  (ctypes (>= 0.20))
  (ctypes-foreign (>= 0.20)))
 (tags (licensing "copy protection" dongle usb hardware)))
