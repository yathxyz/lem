;;;; verified/shim.lisp -- Dual-load shim for the Lem verified kernel (SPEC-VK V0-3).
;;;;
;;;; PURPOSE
;;;;   The kernel books under verified/ are ONE source of truth (SPEC-VK
;;;;   Constraint 2): the very same verified/*.lisp files are (a) certified by
;;;;   ACL2 and (b) loaded verbatim into the plain Lem SBCL image and executed.
;;;;   This shim is the (b) side: it makes the ACL2-subset sources load in a raw
;;;;   SBCL image with no ACL2 present. It is PART OF THE TRUST BASE -- keep it
;;;;   tiny and reviewed line by line.
;;;;
;;;; EVERY CONSTRUCT THIS SHIM REINTERPRETS (exhaustive; trust base):
;;;;   1. package "ACL2"      -- created as (:use :cl). ACL2 books do
;;;;                             (in-package "ACL2"); in-image that means the
;;;;                             applicative subset resolves defun/if/let/etc. to
;;;;                             their identical CL homonyms. Names that collide
;;;;                             with CL are shadowed (see *acl2-shadows*).
;;;;   2. (defthm ...) and (defthmd ...) -- proof-only events (defthmd is the
;;;;                             disabled-by-default variant; identical here).
;;;;                             Each is reinterpreted as a no-op MACRO that
;;;;                             expands to NIL WITHOUT evaluating its body
;;;;                             (the body is a logical formula using symbols such
;;;;                             as IMPLIES that have no in-image function).
;;;;   3. (declare (xargs ...)) -- ACL2 guard/measure/mode annotations. Declared a
;;;;                             valid-and-ignored declaration identifier so the CL
;;;;                             compiler accepts and discards it. Guards are thus
;;;;                             not enforced in-image (they are proved in ACL2).
;;;;
;;;; ACL2 BASE-FUNCTION WHITELIST: the small set of ACL2 built-ins (natp, len,
;;;;   true-listp, ...) that are ACL2 defuns, do NOT exist in CL, and are
;;;;   actually used by the exec path of some book. Each is defined here with its
;;;;   ACL2 semantics and a citation. Anything a book references outside CL and
;;;;   this whitelist fails LOUDLY at load time (undefined function) -- that is
;;;;   the intended enforcement. Current entries (used by buffer-model.lisp):
;;;;     natp, len, true-listp  (see the ACL2 base-function whitelist section).
;;;;
;;;; NOT reinterpreted (deliberately): ACL2's own `defun` for the applicative
;;;;   subset IS just CL `defun`; we rely on that. Do not add a `defun` macro.
;;;;
;;;; This file is NOT an ACL2 book; run-proofs.sh skips it.

(in-package :cl-user)

;;; ---- package "ACL2" ------------------------------------------------------
;;; Symbols whose ACL2 usage would clash with CL if inherited; shadow them so
;;; the ACL2 package owns its own binding. (Empty today; hello.lisp inherits all
;;; of CL cleanly. Add a name here only when a book needs an ACL2-specific
;;; meaning for a CL symbol, and document why.)
(defparameter *acl2-shadows* '()
  "CL symbol-names the ACL2 package shadows. See header.")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package "ACL2")
    (make-package "ACL2" :use '("CL")))
  (dolist (name *acl2-shadows*)
    (shadow name (find-package "ACL2"))))

;;; ---- (2) defthm: proof-only, no-op, body NOT evaluated -------------------
(defmacro acl2::defthm (&rest ignored)
  (declare (ignore ignored))
  nil)
;; defthmd is the disabled-by-default variant; identical in-image (no-op).
(defmacro acl2::defthmd (&rest ignored)
  (declare (ignore ignored))
  nil)

;;; ---- (3) (declare (xargs ...)) accepted and ignored ----------------------
(declaim (declaration acl2::xargs))

;;; ---- ACL2 base-function whitelist ---------------------------------------
;;; Define ONLY built-ins actually used by some book's exec path. Each is a
;;; fresh symbol in the ACL2 package (none of these names exist in CL, so no
;;; shadowing is needed) matching its ACL2 axiomatic semantics.

;; natp: ACL2 axioms.lisp -- (natp x) = x is a non-negative integer.
(defun acl2::natp (x)
  (and (integerp x) (<= 0 x)))

;; len: ACL2 axioms.lisp -- length of the list prefix of x; 0 on an atom.
(defun acl2::len (x)
  (if (consp x)
      (+ 1 (acl2::len (cdr x)))
      0))

;; true-listp: ACL2 axioms.lisp -- x is a nil-terminated (proper) list.
(defun acl2::true-listp (x)
  (if (consp x)
      (acl2::true-listp (cdr x))
      (null x)))

;;; ---- :lem/kernel re-export surface --------------------------------------
;;; The in-image callable surface of the certified kernel. Each name is an
;;; ACL2-package symbol that :lem/kernel imports and re-exports, so callers use
;;; lem/kernel:<name>. Interned + exported at shim load so the reader syntax
;;; resolves before any book is loaded; the function becomes fbound once the
;;; owning book is loaded via LOAD-VERIFIED-BOOK. Extend as kernel books grow.
(defparameter *kernel-exports* '("K-SQ"
                                 ;; buffer-model.lisp (VK-1)
                                 "WF-BUFFER" "EMPTY-BUFFER")
  "ACL2 symbol-names re-exported through :lem/kernel. See header.")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package "LEM/KERNEL")
    (make-package "LEM/KERNEL" :use '()))
  (dolist (name *kernel-exports*)
    (let ((sym (intern name (find-package "ACL2"))))
      (import sym (find-package "LEM/KERNEL"))
      (export sym (find-package "LEM/KERNEL")))))

;;; ---- load-verified-book: the (b) side entry point ------------------------
(defparameter cl-user::*verified-directory*
  (make-pathname :name nil :type nil
                 :defaults (or *load-truename* *load-pathname*
                               *default-pathname-defaults*))
  "Directory holding verified/*.lisp, resolved from this shim's own location.")

(defun lem/kernel::load-verified-book (name)
  "Load verified/NAME.lisp into the running SBCL image the same way ACL2
certified it: in the ACL2 package, with a clean readtable. NAME is the book's
base name without extension. Signals loudly if the book references any construct
the shim does not provide."
  (let ((*package* (find-package "ACL2"))
        (*readtable* (copy-readtable nil)))
    (load (make-pathname :name name :type "lisp"
                         :defaults cl-user::*verified-directory*))))

(export 'lem/kernel::load-verified-book (find-package "LEM/KERNEL"))
