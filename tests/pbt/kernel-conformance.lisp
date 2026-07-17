;;;; tests/pbt/kernel-conformance.lisp -- SPEC-VK VK-2 differential acceptance.
;;;;
;;;; Runs random edit scripts against BOTH a live production buffer (via
;;;; insert-string/point and delete-char/point at point positions) and the
;;;; certified kernel (k-insert / k-delete loaded through verified/shim.lisp)
;;;; from identical initial states, and after EVERY step compares:
;;;;   * the full buffer content (as codepoint lines),
;;;;   * (linum charpos kind) of every registered point -- the three
;;;;     distinguished points and every extra point of both inserting kinds,
;;;;   * production's cached buffer-nlines against (len model-lines),
;;;;   * the string returned by delete-char/point against the kernel's deleted
;;;;     payload (mv-nth 1 of k-delete),
;;;;   * production's position-at-point coordinates against the kernel's
;;;;     k-point-at-position for the position each edit targets,
;;;;   * wf-buffer of the kernel model (free structural teeth).
;;;;
;;;; Production is the spec: any divergence is a kernel transcription bug.
;;;; Codepoint conversion (char-code) happens here, never inside a book.

(defpackage :lem-tests/pbt/kernel-conformance
  (:use :cl
        :rove
        :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/kernel-conformance)

;;; ------------------------------------------------------------------
;;; Kernel loading (shim + certified books)
;;; ------------------------------------------------------------------

(defun repo-root ()
  (asdf:system-source-directory :lem-tests))

(defun ensure-kernel-loaded ()
  "Load the dual-load shim and the VK-2 buffer-edit book (which pulls in the
VK-1 buffer-model book via include-book) into this image once. Idempotent."
  (handler-bind ((warning #'muffle-warning))
    (unless (find-package "LEM/KERNEL")
      (load (merge-pathnames "verified/shim.lisp" (repo-root))))
    (let ((ki (find-symbol "K-INSERT" "LEM/KERNEL")))
      (when (or (null ki) (not (fboundp ki)))
        (funcall (find-symbol "LOAD-VERIFIED-BOOK" "LEM/KERNEL") "buffer-edit")))))

(defmacro defkernel (name kernel-name)
  `(defun ,name (&rest args)
     (apply (find-symbol ,kernel-name "LEM/KERNEL") args)))

(defkernel kwf "WF-BUFFER")
(defkernel k-empty-buffer "EMPTY-BUFFER")
(defkernel k-insert "K-INSERT")
(defkernel k-flatten "K-FLATTEN")

(defun k-delete (model linum charpos n)
  "Kernel k-delete: returns (values model2 deleted-codepoints)."
  (funcall (find-symbol "K-DELETE" "LEM/KERNEL") model linum charpos n))

(defun k-point-at-position (lines pos)
  "Kernel position->point conversion: (values linum charpos)."
  (funcall (find-symbol "K-POINT-AT-POSITION" "LEM/KERNEL") lines pos))

;;; ------------------------------------------------------------------
;;; Model helpers (model = (list lines points tick))
;;; ------------------------------------------------------------------

(defun model-lines (model) (first model))
(defun model-points (model) (second model))

(defun model-char-count (model)
  "Number of characters in the model buffer (newlines included)."
  (length (k-flatten (model-lines model))))

(defun model-find-point (model id)
  (find id (model-points model) :key #'first))

(defun model-set-point (model id linum charpos)
  "Fresh model with point ID moved to (LINUM, CHARPOS) -- the shell-side mirror
of production move-to-position (moving a point is not an edit primitive)."
  (list (model-lines model)
        (mapcar (lambda (p)
                  (if (eql (first p) id)
                      (list id linum charpos (fourth p))
                      p))
                (model-points model))
        (third model)))

(defun model-add-point (model id linum charpos kind)
  (list (model-lines model)
        (append (model-points model) (list (list id linum charpos kind)))
        (third model)))

(defun model-remove-point (model id)
  (list (model-lines model)
        (remove id (model-points model) :key #'first)
        (third model)))

;;; ------------------------------------------------------------------
;;; Production-side helpers
;;; ------------------------------------------------------------------

(defun production-lines (buffer)
  "Buffer content as a list of codepoint lists, in line order."
  (loop :for line := (lem/buffer/internal:point-line
                      (lem/buffer/internal:buffer-start-point buffer))
          :then (lem/buffer/line:line-next line)
        :while line
        :collect (map 'list #'char-code (lem/buffer/line:line-string line))))

(defun point-coords (point)
  (list (lem/buffer/internal::point-linum point)
        (lem/buffer/internal:point-charpos point)))

;;; ------------------------------------------------------------------
;;; The differential interpreter
;;; ------------------------------------------------------------------

(defstruct (state (:constructor make-state (buffer model)))
  buffer                ; production buffer
  model                 ; kernel model, updated via k-insert / k-delete
  (extras '())          ; alist (id . production-point), creation order
  (next-id 3))

(defun state-point (state)
  (lem/buffer/internal:buffer-point (state-buffer state)))

(defun clamp-position (state raw)
  "Map RAW into a valid 1-based position of the current buffer."
  (1+ (mod raw (1+ (model-char-count (state-model state))))))

(defun sync-to-position (state point raw &key (point-id nil))
  "Move production POINT to the clamped position RAW; return (values linum
charpos) or NIL on a divergence between production's landing coordinates and
the kernel's k-point-at-position. When POINT-ID is given, mirror the move into
the model point with that id."
  (let ((pos (clamp-position state raw)))
    (lem:move-to-position point pos)
    (multiple-value-bind (klinum kcharpos)
        (k-point-at-position (model-lines (state-model state)) pos)
      (if (equal (point-coords point) (list klinum kcharpos))
          (progn
            (when point-id
              (setf (state-model state)
                    (model-set-point (state-model state) point-id klinum kcharpos)))
            (values klinum kcharpos))
          nil))))

(defun state-consistent-p (state)
  "The full VK-2 comparison: content, nlines, every registered point, wf."
  (let* ((buffer (state-buffer state))
         (model (state-model state))
         (prod-points
           (list* (cons 0 (lem/buffer/internal:buffer-start-point buffer))
                  (cons 1 (lem/buffer/internal:buffer-end-point buffer))
                  (cons 2 (lem/buffer/internal:buffer-point buffer))
                  (state-extras state))))
    (and (equal (production-lines buffer) (model-lines model))
         (= (lem/buffer/internal:buffer-nlines buffer)
            (length (model-lines model)))
         (= (length (model-points model)) (length prod-points))
         (loop :for (id . point) :in prod-points
               :for mp := (model-find-point model id)
               :always (and mp
                            (equal (point-coords point)
                                   (list (second mp) (third mp)))
                            (eq (lem/buffer/internal:point-kind point)
                                (fourth mp))))
         (kwf model))))

(defun run-op (state op)
  "Execute OP on both sides. Return NIL on a divergence detected inside the op
(position conversion or deleted-payload mismatch), T otherwise."
  (ecase (first op)
    (:insert
     (destructuring-bind (raw string) (rest op)
       (multiple-value-bind (linum charpos)
           (sync-to-position state (state-point state) raw :point-id 2)
         (when linum
           (setf (state-model state)
                 (k-insert (state-model state) linum charpos
                           (map 'list #'char-code string)))
           (lem/buffer/internal::insert-string/point (state-point state) string)
           t))))
    (:delete
     (destructuring-bind (raw n) (rest op)
       (multiple-value-bind (linum charpos)
           (sync-to-position state (state-point state) raw :point-id 2)
         (when linum
           (multiple-value-bind (model2 deleted)
               (k-delete (state-model state) linum charpos n)
             (setf (state-model state) model2)
             (let ((string (lem/buffer/internal::delete-char/point
                            (state-point state) n)))
               (equal (map 'list #'char-code string) deleted)))))))
    (:move
     (multiple-value-bind (linum charpos)
         (sync-to-position state (state-point state) (second op) :point-id 2)
       (declare (ignore charpos))
       (and linum t)))
    (:add-point
     (destructuring-bind (kind raw) (rest op)
       (let ((p (lem:copy-point (state-point state) kind))
             (id (state-next-id state)))
         (incf (state-next-id state))
         (setf (state-extras state)
               (append (state-extras state) (list (cons id p))))
         (multiple-value-bind (linum charpos)
             (sync-to-position state p raw)
           (when linum
             (setf (state-model state)
                   (model-add-point (state-model state) id linum charpos kind))
             t)))))
    (:move-point
     (destructuring-bind (i raw) (rest op)
       (if (null (state-extras state))
           t
           (let* ((entry (nth (mod i (length (state-extras state)))
                              (state-extras state))))
             (multiple-value-bind (linum charpos)
                 (sync-to-position state (cdr entry) raw :point-id (car entry))
               (declare (ignore charpos))
               (and linum t))))))
    (:del-point
     (destructuring-bind (i) (rest op)
       (if (null (state-extras state))
           t
           (let ((entry (nth (mod i (length (state-extras state)))
                             (state-extras state))))
             (setf (state-extras state)
                   (remove entry (state-extras state) :test #'eq))
             (lem:delete-point (cdr entry))
             (setf (state-model state)
                   (model-remove-point (state-model state) (car entry)))
             t))))))

(defun run-script (script)
  "Run SCRIPT differentially. T iff every op succeeded and the full comparison
held after every step (and initially)."
  (let* ((buffer (lem:make-buffer "pbt-vk2" :temporary t :enable-undo-p nil))
         (state (make-state buffer (k-empty-buffer))))
    (unwind-protect
         (and (state-consistent-p state)
              (loop :for op :in script
                    :always (and (run-op state op)
                                 (state-consistent-p state))))
      (loop :for (id . point) :in (state-extras state)
            :do (ignore-errors (lem:delete-point point)))
      (ignore-errors (lem:delete-buffer buffer)))))

;;; ------------------------------------------------------------------
;;; Script generator: inserts mix in newlines and multibyte codepoints;
;;; extra registered points of both kinds participate
;;; ------------------------------------------------------------------

(defun gen-insert-string (max-length)
  "Short Unicode strings (multibyte, combining, emoji via the harness
alphabet); ~40% get a newline spliced in so multi-line inserts and cross-line
marker relocation are exercised."
  (let ((base (gen-string :max-length max-length)))
    (make-generator
     :sample (lambda (rng)
               (let ((s (draw base rng)))
                 (if (< (rng-below rng 100) 40)
                     (let ((i (rng-below rng (1+ (length s)))))
                       (concatenate 'string (subseq s 0 i)
                                    (string #\Newline)
                                    (subseq s i)))
                     s)))
     :shrink (generator-shrink base))))

(defun gen-op (&key (max-pos 200) (max-delete 8) (max-insert 6))
  (let ((string-gen (gen-insert-string max-insert)))
    (make-generator
     :sample (lambda (rng)
               (case (rng-below rng 10)
                 ((0 1 2) (list :insert (rng-below rng max-pos)
                                (draw string-gen rng)))
                 ((3 4 5) (list :delete (rng-below rng max-pos)
                                (rng-range rng 1 max-delete)))
                 (6 (list :move (rng-below rng max-pos)))
                 (7 (list :add-point
                          (if (rng-boolean rng) :left-inserting :right-inserting)
                          (rng-below rng max-pos)))
                 (8 (list :move-point (rng-below rng 8) (rng-below rng max-pos)))
                 (t (list :del-point (rng-below rng 8))))))))

(defun gen-script (&key (min-ops 15) (max-ops 30))
  (gen-list (gen-op) :min-length min-ops :max-length max-ops))

;;; ------------------------------------------------------------------
;;; Tests
;;; ------------------------------------------------------------------

(deftest kernel-conformance-smoke
  (ensure-kernel-loaded)
  ;; A deterministic mixed script exercising all four shift-markers cases.
  (ok (run-script
       (list '(:insert 0 "hello")
             '(:add-point :left-inserting 3)
             '(:add-point :right-inserting 3)
             '(:insert 3 "ab")                        ; case 1 boundary: kinds differ
             (list :insert 4 (format nil "x~%y"))     ; case 2: multi-line insert
             '(:delete 2 3)                           ; case 3 / case 4
             (list :insert 0 (format nil "~%~%"))     ; newline-only payload
             '(:delete 1 50)                          ; run off the end of the buffer
             '(:move-point 0 5)
             '(:del-point 1)
             '(:delete 1 8)))
      "deterministic mixed script conforms"))

;;; VK-2 acceptance: ~2k random scripts, full comparison after every step.
(deftest kernel-conformance-differential
  (ensure-kernel-loaded)
  (let ((*num-tests* 10000))
    (for-all ((script (gen-script)))
      (run-script script))))
