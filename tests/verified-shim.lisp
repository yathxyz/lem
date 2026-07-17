;;;; tests/verified-shim.lisp -- SPEC-VK V0-3 acceptance.
;;;;
;;;; Proves the "one source of truth" contract (SPEC-VK Constraint 2) for the V0
;;;; canary: the SAME verified/hello.lisp source that ACL2 certifies via
;;;; scripts/run-proofs.sh also loads into this SBCL image and executes, and the
;;;; value asserted by its certified theorem (defthm k-sq-of-known-value:
;;;; (k-sq 7) = 49) is reproduced in-image, called through the :lem/kernel
;;;; re-export surface.
;;;;
;;;; The shim itself is loaded by the lem-verified-kernel system (a lem-tests
;;;; dependency, see lem-verified-kernel.asd); this test only loads the hello
;;;; canary book on top.  LOAD-VERIFIED-BOOK is load-once per book, so calling
;;;; it here never double-loads.

(defpackage :lem-tests/verified-shim
  (:use :cl :rove))
(in-package :lem-tests/verified-shim)

(defun ensure-kernel-loaded ()
  "Load the hello canary book into this image through the shim established by
the lem-verified-kernel system. Idempotent; muffles redefinition warnings."
  (handler-bind ((warning #'muffle-warning))
    (lem/kernel:load-verified-book "hello")))

(deftest verified-shim-dual-load
  (ensure-kernel-loaded)
  (ok (find-package "LEM/KERNEL")
      ":lem/kernel package is established by the shim")
  (multiple-value-bind (k-sq status) (find-symbol "K-SQ" "LEM/KERNEL")
    (ok k-sq "k-sq is re-exported through :lem/kernel")
    (ok (eq status :external) "k-sq is external in :lem/kernel")
    (ok (fboundp k-sq)
        "k-sq is fbound after loading the certified book through the shim")
    ;; The certified fact, reproduced by executing the same source in-image.
    (ok (= 49 (funcall k-sq 7))
        "certified (k-sq 7) = 49 holds when executed in the Lem image")
    ;; And it is a genuine executable function, not just the pinned constant.
    (ok (= 144 (funcall k-sq 12))
        "k-sq executes as ordinary CL over the applicative subset")))
