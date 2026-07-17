;;;; verified/hello.lisp -- Permanent canary book for the Lem verified kernel.
;;;;
;;;; SPEC-VK V0-1 acceptance: a hello-world book that certifies in ACL2 AND, via
;;;; verified/shim.lisp, loads and executes in the plain Lem SBCL image from the
;;;; SAME source (one source of truth, SPEC-VK Constraint 2). Keep this book
;;;; forever as a smoke test of the whole toolchain: if run-proofs.sh or the
;;;; dual-load shim ever break, this is the first thing that goes red.
;;;;
;;;; It uses only the applicative CL subset (defun over *) so it needs NO entry
;;;; in the shim's ACL2 base-function whitelist. K-SQ is re-exported as
;;;; lem/kernel:k-sq (see verified/shim.lisp *kernel-exports*).

(in-package "ACL2")

(defun k-sq (n)
  "Square of N. Pure; applicable in both ACL2 and the SBCL image."
  (* n n))

(defthm k-sq-nonneg
  (implies (rationalp n)
           (<= 0 (k-sq n))))

(defthm k-sq-of-known-value
  (equal (k-sq 7) 49))
