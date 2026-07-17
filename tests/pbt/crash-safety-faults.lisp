;;;; tests/pbt/crash-safety-faults.lisp -- SPEC-VK VK-6 fault-injection acceptance.
;;;;
;;;; Pins the certified crash-safety model (verified/crash-safety.lisp, loaded
;;;; through verified/shim.lisp) to reality: a driver executes the REAL syscall
;;;; sequence of the DS-2 atomic save + DS-3 checkpoint interplay against a
;;;; throwaway tmpdir, stopping after k steps for every k = 0..N.  STOPPING IS
;;;; THE CRASH MODEL: a crash, as far as this process's protocol is concerned,
;;;; is exactly "no further syscalls are issued".  What stopping does NOT cover
;;;; -- power loss, lying fsyncs, data-vs-rename reordering below the OS -- is
;;;; covered by the model's filesystem AXIOMS (verified/crash-safety.lisp
;;;; header, A1-A4), which are trust base, not testable from userland.
;;;;
;;;; The driver is a step-faithful transcription of the production functions
;;;; (same syscalls, same order, same open flags), because the production
;;;; functions are single opaque calls that cannot be stopped mid-flight:
;;;;   steps 1-3: src/ext/checkpoint.lisp write-string-to-file-atomically
;;;;              (lines 88-105): open temp (:if-exists :supersede),
;;;;              write-string + finish-output + close, sb-posix:rename.
;;;;   steps 4-8: src/buffer/file-utils.lisp write-file-atomically (242-285):
;;;;              open temp (:if-exists :error), writer, fsync-stream
;;;;              (finish-output + sb-posix:fsync) + close,
;;;;              preserve-file-metadata (chown/chmod), sb-posix:rename.
;;;;   step 9:    src/ext/checkpoint.lisp delete-checkpoint (138-145), the
;;;;              after-save-hook (file.lisp:182-186 orders it strictly after
;;;;              the rename commits).
;;;; The checkpoint file path comes from the REAL production
;;;; lem/checkpoint:checkpoint-filename (encode-path dispatch included).
;;;;
;;;; At every kill point k the test asserts, against the REAL filesystem:
;;;;   * the VK-6 invariant: target content is OLD or NEW (never torn/lost),
;;;;     and checkpoint-absent => target = NEW (delete ordering);
;;;;   * the model's prediction: the kernel's cs-run over the same k actions
;;;;     must match the disk -- exactly for synced/absent files, and as a
;;;;     prefix for files whose data the model marks unsynced (a live stream's
;;;;     userland buffer is not yet on disk; "real is a prefix of model" is
;;;;     precisely the crash transition's tear axiom A3 observed from outside).
;;;; That pins the model's step semantics to the real syscall behavior.
;;;;
;;;; Also here: differential PBT of the certified encode-path port against the
;;;; production lem/checkpoint::encode-path, and fixed namespace-dispatch
;;;; fixtures ("!s" prefix for encoded absolute paths vs. base-36 first char
;;;; for hash-fallback names).  Codepoint conversion (char-code / code-char)
;;;; happens here, never inside a book.

(defpackage :lem-tests/pbt/crash-safety-faults
  (:use :cl
        :rove
        :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/crash-safety-faults)

;;; ------------------------------------------------------------------
;;; Kernel loading (shim + certified crash-safety book)
;;; ------------------------------------------------------------------

(defun repo-root ()
  (asdf:system-source-directory :lem-tests))

(defun ensure-kernel-loaded ()
  "Load the dual-load shim and the VK-6 crash-safety book into this image once."
  (handler-bind ((warning #'muffle-warning))
    (unless (find-package "LEM/KERNEL")
      (load (merge-pathnames "verified/shim.lisp" (repo-root))))
    (let ((s (find-symbol "CS-RUN" "LEM/KERNEL")))
      (when (or (null s) (not (fboundp s)))
        (funcall (find-symbol "LOAD-VERIFIED-BOOK" "LEM/KERNEL") "crash-safety")))))

(defun kcall (name &rest args)
  "Call the certified kernel function NAME through the :lem/kernel surface."
  (let ((symbol (find-symbol name "LEM/KERNEL")))
    (unless (and symbol (fboundp symbol))
      (error "kernel function ~A is not loaded" name))
    (apply symbol args)))

;;; ------------------------------------------------------------------
;;; Codepoint / file plumbing
;;; ------------------------------------------------------------------

(defun cps (string)
  (map 'list #'char-code string))

(defun cps->string (codepoints)
  (map 'string #'code-char codepoints))

(defun write-text-file (path string)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
    (write-string string out)))

(defun read-text-file (path)
  (with-open-file (in path :direction :input :external-format :utf-8)
    (let ((string (make-string (file-length in))))
      (subseq string 0 (read-sequence string in)))))

(defun string-prefix-p (a b)
  "A is a prefix of B."
  (let ((m (mismatch a b)))
    (or (null m) (= m (length a)))))

;;; ------------------------------------------------------------------
;;; The scenario: one save of NEW over OLD, with a checkpoint of CPC being
;;; written first and a stale durable checkpoint CP0 already on disk.
;;; ------------------------------------------------------------------

(defparameter *old* (format nil "old line one~%old line two~%"))
(defparameter *new* (format nil "NEW content, longer than the old one~%line 2~%line 3~%"))
(defparameter *cpc* (format nil "checkpointed unsaved edits~%"))
(defparameter *cp0* (format nil "stale previous checkpoint~%"))

;; Model actions, in 1:1 correspondence (same order) with the driver steps.
(defparameter *model-actions*
  '(:cp-create-temp :cp-write-temp :cp-rename
    :save-create-temp :save-write-temp :save-fsync-temp
    :save-metadata :save-rename :save-delete-checkpoint))

(defun model-state-after (k)
  "The kernel model's state after the first K protocol steps."
  (kcall "CS-RUN"
         (kcall "CS-INIT" (cps *old*) (cps *new*) (cps *cpc*) (cps *cp0*) t)
         (subseq *model-actions* 0 k)))

(defun model-file-matches-disk-p (model-file path)
  "Does the on-disk file at PATH match MODEL-FILE (a kernel file record or NIL)?
Synced model data must match exactly (axiom A2); unsynced model data admits any
prefix on disk (axiom A3 -- here: a live stream's buffer is not yet written);
an absent model file must be absent on disk."
  (if (consp model-file)
      (and (probe-file path)
           (let ((real (read-text-file path))
                 (model (cps->string (kcall "FILE-CONTENT" model-file))))
             (if (kcall "FILE-SYNCED" model-file)
                 (equal real model)
                 (string-prefix-p real model))))
      (not (probe-file path))))

(defun run-kill-point (k)
  "Execute the first K real protocol steps in a fresh tmpdir, then check the
on-disk state against the VK-6 invariant and the kernel model. Returns a list
of failed check names (NIL = all green)."
  (let* ((dir (merge-pathnames (format nil "lem-vk6-~36R/" (random (expt 36 10)))
                               (uiop:temporary-directory)))
         (target (namestring (merge-pathnames "target.txt" dir)))
         (lem/checkpoint:*checkpoint-directory* dir)
         (cp-path (namestring (lem/checkpoint:checkpoint-filename target)))
         ;; Temp names follow the production patterns (file-utils.lisp:193-204,
         ;; checkpoint.lisp:93), chosen up front so every kill point can probe them.
         (save-temp (format nil "~A.#target.txt.~36R.~D.tmp"
                            (namestring dir) (random (expt 36 12)) (sb-posix:getpid)))
         (cp-temp (format nil "~A.~36R.tmp" cp-path (random (expt 36 12))))
         (save-stream nil)
         (cp-stream nil)
         (failed '()))
    (ensure-directories-exist dir)
    ;; Durable initial state: target holds OLD, previous checkpoint holds CP0.
    (write-text-file target *old*)
    (write-text-file cp-path *cp0*)
    (unwind-protect
         (let ((steps
                 (list
                  ;; 1 :cp-create-temp -- checkpoint.lisp:92-100
                  (lambda ()
                    (setf cp-stream (open cp-temp :direction :output
                                                  :if-exists :supersede
                                                  :if-does-not-exist :create
                                                  :external-format :utf-8)))
                  ;; 2 :cp-write-temp -- checkpoint.lisp:101-102 (+ stream close
                  ;; on with-open-file exit; note: finish-output, NO fsync)
                  (lambda ()
                    (write-string *cpc* cp-stream)
                    (finish-output cp-stream)
                    (close cp-stream))
                  ;; 3 :cp-rename -- checkpoint.lisp:103
                  (lambda () (sb-posix:rename cp-temp cp-path))
                  ;; 4 :save-create-temp -- file-utils.lisp:224-230, 267
                  (lambda ()
                    (setf save-stream (open save-temp :direction :output
                                                      :if-exists :error
                                                      :if-does-not-exist :create)))
                  ;; 5 :save-write-temp -- file-utils.lisp:269 (buffered; the
                  ;; data reaches the OS only at the fsync step, as in production)
                  (lambda () (write-string *new* save-stream))
                  ;; 6 :save-fsync-temp -- fsync-stream, file-utils.lisp:186-191,
                  ;; 270-271 (finish-output + fsync, then close)
                  (lambda ()
                    (finish-output save-stream)
                    (sb-posix:fsync (sb-sys:fd-stream-fd save-stream))
                    (close save-stream))
                  ;; 7 :save-metadata -- preserve-file-metadata,
                  ;; file-utils.lisp:206-222, 275 (chown before chmod)
                  (lambda ()
                    (let ((stat (ignore-errors (sb-posix:stat target))))
                      (when stat
                        (ignore-errors
                         (sb-posix:chown save-temp
                                         (sb-posix:stat-uid stat)
                                         (sb-posix:stat-gid stat)))
                        (ignore-errors
                         (sb-posix:chmod save-temp
                                         (logand (sb-posix:stat-mode stat) #o7777))))))
                  ;; 8 :save-rename -- file-utils.lisp:278
                  (lambda () (sb-posix:rename save-temp target))
                  ;; 9 :save-delete-checkpoint -- checkpoint.lisp:138-145 via the
                  ;; after-save hook (file.lisp:182-186: strictly after rename)
                  (lambda () (uiop:delete-file-if-exists cp-path)))))
           (assert (= (length steps) (length *model-actions*)))
           (loop :for i :from 0 :below k
                 :do (funcall (nth i steps)))
           ;; "Crash": no further syscalls. Now judge the disk.
           (let ((m (model-state-after k)))
             (flet ((chk (name okp)
                      (unless okp (push name failed))))
               (let ((real-target (read-text-file target)))
                 ;; The certified invariant holds of the model state (sanity).
                 (chk :kernel-invariant (kcall "CS-INV" m))
                 ;; VK-6 obligation 1 on the REAL disk: old or new, never torn.
                 (chk :target-old-or-new
                      (or (equal real-target *old*) (equal real-target *new*)))
                 ;; VK-6 obligation 2 on the REAL disk: checkpoint absent =>
                 ;; the rename committed.
                 (chk :checkpoint-absent-implies-new
                      (or (probe-file cp-path) (equal real-target *new*)))
                 ;; Model-vs-disk: every file slot the model tracks.
                 (chk :target-matches-model
                      (and (model-file-matches-disk-p (kcall "ST-TARGET" m) target)
                           ;; the target is always synced in the model, so this
                           ;; comparison was exact:
                           (equal real-target
                                  (cps->string
                                   (kcall "FILE-CONTENT" (kcall "ST-TARGET" m))))))
                 (chk :checkpoint-matches-model
                      (model-file-matches-disk-p (kcall "ST-CHECKPOINT" m) cp-path))
                 (chk :save-temp-matches-model
                      (model-file-matches-disk-p (kcall "ST-SAVE-TEMP" m) save-temp))
                 (chk :cp-temp-matches-model
                      (model-file-matches-disk-p (kcall "ST-CP-TEMP" m) cp-temp))))))
      (when (and cp-stream (open-stream-p cp-stream))
        (ignore-errors (close cp-stream :abort t)))
      (when (and save-stream (open-stream-p save-stream))
        (ignore-errors (close save-stream :abort t)))
      (ignore-errors (uiop:delete-directory-tree dir :validate (constantly t))))
    (nreverse failed)))

(deftest crash-safety-fault-injection
  (ensure-kernel-loaded)
  ;; Every kill point k: crash after k real steps, k = 0 (nothing ran) through
  ;; 9 (the full protocol committed).
  (loop :for k :from 0 :to (length *model-actions*)
        :do (let ((failed (run-kill-point k)))
              (ok (null failed)
                  (format nil "kill point k=~D~@[ FAILED checks: ~S~]" k failed)))))

;;; ------------------------------------------------------------------
;;; encode-path: certified port vs. production, differentially
;;; ------------------------------------------------------------------

;; Path characters biased toward the interesting ones: the escapes '/' (47)
;; and '!' (33), the name terminator '#' (35), plus multibyte.
(defparameter *path-char-pool*
  (coerce (append (cps "abcxyzABC0123456789 ._-~")
                  (list 47 47 47 33 33 35 #xE9 #x4E2D))
          'vector))

(defun gen-path-codepoints (&key (max-len 40))
  (make-generator
   :sample (lambda (rng)
             (let ((n (rng-below rng (1+ max-len))))
               (loop :repeat n
                     :collect (rng-element rng *path-char-pool*))))
   :shrink (constantly nil)))

(deftest encode-path-conformance
  (ensure-kernel-loaded)
  ;; Fixed points first: the documented escapes.
  (ok (equal (kcall "ENCODE-PATH" (cps "/a!b"))
             (list 33 115 97 33 33 98))
      "/a!b encodes to !sa!!b")
  (ok (null (kcall "ENCODE-PATH" nil)) "empty path encodes to empty")
  ;; Differential: kernel port == production encode-path on random paths.
  (for-all ((codepoints (gen-path-codepoints)))
    (equal (cps (lem/checkpoint::encode-path (cps->string codepoints)))
           (kcall "ENCODE-PATH" codepoints))))

;;; ------------------------------------------------------------------
;;; checkpoint-filename namespace dispatch: encoded vs. hash-fallback names
;;; (fixtures for the certified disjointness theorems)
;;; ------------------------------------------------------------------

(deftest checkpoint-name-namespaces
  (ensure-kernel-loaded)
  (let ((lem/checkpoint:*checkpoint-directory* (uiop:temporary-directory)))
    (let ((short-name (file-namestring
                       (lem/checkpoint:checkpoint-filename "/tmp/vk6!demo file.txt")))
          (long-name (file-namestring
                      (lem/checkpoint:checkpoint-filename
                       (format nil "/tmp/~A.txt"
                               (make-string 250 :initial-element #\a))))))
      ;; Encoded namespace: absolute paths start with "/" so names start "!s".
      (ok (and (< 2 (length short-name)) (string= "!s" short-name :end2 2))
          "encoded absolute-path name starts with !s")
      (ok (char= #\# (char short-name (1- (length short-name))))
          "encoded name ends with #")
      ;; Hash-fallback namespace: names start with a lowercase base-36 digit.
      (ok (find (char long-name 0) "0123456789abcdefghijklmnopqrstuvwxyz")
          "hash-fallback name starts with a base-36 digit")
      (ok (char/= #\! (char long-name 0))
          "hash-fallback name can never collide with an encoded name (first char)")
      (ok (char= #\# (char long-name (1- (length long-name))))
          "hash-fallback name ends with #"))))
