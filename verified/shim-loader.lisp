;;;; verified/shim-loader.lisp -- ASDF entry point for the verified kernel.
;;;;
;;;; Sole component of the `lem-verified-kernel' system (lem-verified-kernel.asd
;;;; at the repository root): loading that system loads verified/shim.lisp (the
;;;; dual-load shim, SPEC-VK V0-3) and then the kernel books production code
;;;; depends on, via lem/kernel::load-verified-book (load-once per book, so
;;;; test files that load further books on demand interoperate without double
;;;; loading).
;;;;
;;;; NOT an ACL2 book -- scripts/run-proofs.sh skips shim*.lisp files.
;;;; Books are loaded as source through the shim (never compiled separately):
;;;; the eval-when covers compile time so kernel packages/symbols exist while
;;;; dependent systems (lem-ncurses, lem-tests) are compiled, and load time so
;;;; a fresh image loading cached fasls gets the kernel too.

(in-package :cl-user)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package "LEM/KERNEL")
    (load (merge-pathnames "verified/shim.lisp"
                           (asdf:system-source-directory "lem-verified-kernel"))))
  ;; Books required by production code paths:
  ;;   VK-7  ncurses input decode (frontends/ncurses/input.lisp)
  ;;   VK-10 width algebra (src/common/character/string-width-utils.lisp; `width'
  ;;         includes `eastasian-data' via the shim's include-book, so loading
  ;;         `width' pulls the table book too)
  ;;   VK-4  kernel-backed edit engine (src/buffer/internal/buffer-insert.lisp
  ;;         calls the buffer-edit point maps + wf-buffer/k-insert/k-delete in
  ;;         the checking modes; src/buffer/internal/edit.lisp calls the offset
  ;;         algebra). `buffer-edit' includes `buffer-model'; `undo' includes
  ;;         `buffer-edit'; all three listed explicitly as the VK-4 kernel.
  (let ((load-book (find-symbol "LOAD-VERIFIED-BOOK" "LEM/KERNEL")))
    (funcall load-book "input-decode")
    (funcall load-book "width")
    (funcall load-book "buffer-model")
    (funcall load-book "buffer-edit")
    (funcall load-book "undo")))
