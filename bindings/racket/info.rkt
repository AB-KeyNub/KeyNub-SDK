#lang info

;; A single-collection package: this directory is the `keynub` collection, so
;; licdongle.rkt is the module `keynub/licdongle`.
(define collection "keynub")

(define pkg-desc
  "KeyNub License Dongle: verify that a dongle is genuine, read and write the license records it holds, use its hardware counters and seal data that only a dongle can open.")
(define version "1.1.1")
(define pkg-authors '(KeyNub))
(define license 'Apache-2.0)

(define deps '(("base" #:version "8.0")))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))

(define scribblings '(("scribblings/licdongle.scrbl" () (library) "keynub-licdongle")))

;; The stand-in test compiles C and runs against a stand-in library; run it
;; with `racket test/standin-test.rkt`.
(define test-omit-paths '("test/standin-test.rkt"))
