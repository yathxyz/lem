(in-package :lem/buffer/internal)

;;; SPEC-VK VK-4: the buffer mutation engine is an imperative shell over the
;;; certified kernel (verified/buffer-edit.lisp, loaded via verified/shim.lisp).
;;; Hooks, read-only checks, interrupt masking and undo recording stay here;
;;; marker relocation is computed by the certified kernel point maps restricted
;;; to the affected region and materialized onto the production point objects.
;;; Line strings/properties are materialized by the line surgery functions,
;;; whose content output is the kernel's content answer by the certified
;;; content laws (`k-flatten-of-k-insert', `content-of-k-delete').
;;; Locality boundary + modes: verified/README.md, section VK-4.

(defvar *inhibit-read-only* nil
  "If T, disables read-only for `buffer`.")

(defvar *inhibit-modification-hooks* nil
  "If T, prevents `before-change-functions` and `after-change-functions` from being called.")

(defvar *edit-engine-mode*
  (if (member :lem-paranoid *features*) :paranoid :release)
  "Checking mode of the kernel-backed edit engine (SPEC-VK VK-4).
One of:
  :release     -- fast path, no per-edit checking (default).
  :paranoid    -- assert the certified `wf-buffer` on the affected-region model
                  after every mutation (default when the image was built with
                  :lem-paranoid on `*features*`, e.g. LEM_PARANOID=1 make ncurses).
  :conformance -- tests only: additionally mirror every mutation through the
                  full kernel on the full buffer model and compare
                  field-for-field.")

(define-editor-variable before-change-functions '())
(define-editor-variable after-change-functions '())

(define-condition edit-engine-conformance-error (simple-error) ()
  (:documentation
   "Signalled in :conformance mode when a mutation's materialized result
diverges from the full kernel's answer on the full buffer model."))

(defun check-read-only-at-point (point n)
  (loop :for line := (point-line point) :then (line:line-next line)
        :for charpos := (point-charpos point) :then 0
        :do (unless line
              (return))
            (when (line:line-search-property-range line :read-only charpos (+ charpos n))
              (error 'read-only-error))
            (when (>= 0 (decf n (1+ (- (line:line-length line) charpos))))
              (return))))

(defun call-with-modify-buffer (point n function)
  (without-interrupts
    (let ((buffer (point-buffer point)))
      (unless *inhibit-read-only*
        (check-read-only-buffer buffer)
        (check-read-only-at-point point n))
      (prog1 (funcall function)
        (buffer-modify buffer)))))

(defmacro with-modify-buffer ((point n) &body body)
  `(call-with-modify-buffer ,point ,n (lambda () ,@body)))

(defun line-next-n (line n)
  (loop :repeat n
        :do (setf line (line:line-next line)))
  line)

;;; ---------------------------------------------------------------------------
;;; Kernel-backed marker relocation (replaces the pre-VK-4 `shift-markers')
;;; ---------------------------------------------------------------------------

(defun kernel-point-tuples (points base-linum)
  "Kernel point records (id linum charpos kind) for the production POINTS,
region-relative: linum 1 is production line BASE-LINUM; ids are positional (the
kernel point maps preserve order, so the answer zips back against POINTS)."
  (loop :for p :in points
        :for id :from 0
        :collect (list id
                       (1+ (- (point-linum p) base-linum))
                       (point-charpos p)
                       (point-kind p))))

(defun materialize-kernel-points (points ktuples base-linum base-line)
  "Write the kernel's relocated coordinates KTUPLES (same order as POINTS) back
onto the production point objects. Region line I maps to the (I-1)th
`line:line-next' of BASE-LINE and production linum (+ BASE-LINUM I -1)."
  (loop :for p :in points
        :for kt :in ktuples
        :do (let* ((new-linum (+ base-linum (second kt) -1))
                   (new-line (line-next-n base-line (1- (second kt)))))
              (unless (and (= new-linum (point-linum p))
                           (eq new-line (point-line p)))
                (point-change-line p new-linum new-line))
              (setf (point-charpos p) (third kt)))))

(defun renumber-points-below (buffer linum delta)
  "Add DELTA to the cached linum of every registered point strictly below line
LINUM -- the uniform tail renumber of shift-markers cases 2 and 4; charpos and
line membership of those points are unaffected by construction."
  (dolist (p (buffer-points buffer))
    (when (< linum (point-linum p))
      (incf (point-linum p) delta))))

(defun kernel-shift-markers (point offset-line offset-char)
  "Marker relocation via the certified kernel (SPEC-VK VK-4). Same call
contract as the pre-VK-4 `shift-markers': called exactly once per edit, after
the line surgery, with POINT still holding the edit origin (L, C) and
\(OFFSET-LINE, OFFSET-CHAR) as the surgery loop computed them. The kernel
computes the relocation restricted to the affected region -- the registered
points of the touched lines -- and the answer is materialized onto the point
objects; points below the region get the uniform linum renumber."
  (let ((linum (point-linum point))
        (charpos (point-charpos point))
        (buffer (point-buffer point)))
    (cond ((or (< 0 offset-line)
               (and (= 0 offset-line) (< 0 offset-char)))
           ;; Insert: region = the target line's registered points (a
           ;; multi-line payload can only move them onto the lines it created).
           (when (< 0 offset-line)
             (renumber-points-below buffer linum offset-line))
           (let ((region-points (copy-list (line:line-points (point-line point)))))
             (materialize-kernel-points
              region-points
              ;; Iterate the certified per-point map (mapcar is iterative in
              ;; SBCL): identical semantics to the book's shift-points-insert
              ;; list recursion, but O(1) control stack however many points
              ;; the region holds (overlay-heavy buffers register thousands).
              (mapcar (lambda (tuple)
                        (lem/kernel:shift-point-insert
                         tuple 1 charpos offset-line offset-char))
                      (kernel-point-tuples region-points linum))
              linum
              (point-line point))))
          ((or (> 0 offset-line)
               (and (= 0 offset-line) (> 0 offset-char)))
           ;; Delete: region = the registered points of the touched lines
           ;; [L, L+j]. For j > 0 the merged lines' `line-points' were wiped by
           ;; `line-free', so collect by cached linum from `buffer-points'.
           (let* ((j (- offset-line))
                  (oc (abs offset-char))
                  (region-points
                    (if (= j 0)
                        (copy-list (line:line-points (point-line point)))
                        (loop :for p :in (buffer-points buffer)
                              :when (<= linum (point-linum p) (+ linum j))
                                :collect p))))
             (when (< 0 j)
               (renumber-points-below buffer (+ linum j) offset-line))
             (materialize-kernel-points
              region-points
              ;; Same iterative materialization of the certified per-point map
              ;; as the insert branch (O(1) stack; see comment there).
              (mapcar (lambda (tuple)
                        (lem/kernel:shift-point-delete
                         tuple 1 charpos j oc))
                      (kernel-point-tuples region-points linum))
              linum
              (point-line point)))))))

;;; ---------------------------------------------------------------------------
;;; Mode machinery: paranoid region assertion, conformance full-kernel mirror
;;; ---------------------------------------------------------------------------

(defun line-codepoints (line)
  (map 'list #'char-code (line:line-string line)))

(defun string-codepoints (string)
  (map 'list #'char-code string))

(defun paranoid-check-edit (buffer base-line base-linum extra-lines)
  "Paranoid-mode per-edit assertion (SPEC-VK VK-4): the affected region --
BASE-LINE plus the EXTRA-LINES lines an insert created -- must satisfy the
certified `wf-buffer` when modelled with synthetic start/end/buffer-point
records; every region point's cached linum must agree with the line it is
registered on; and no registered point of BUFFER may reference a freed line
\(absorbing `check-buffer-corruption`'s role). Signals `corruption-warning`
on violation."
  (let* ((region-lines (loop :repeat (1+ extra-lines)
                             :for line := base-line :then (line:line-next line)
                             :collect line))
         (nrel (length region-lines))
         (linum-agreement
           (loop :for line :in region-lines
                 :for linum :from base-linum
                 :always (loop :for p :in (line:line-points line)
                               :always (= (point-linum p) linum))))
         (lines-alive
           (loop :for p :in (buffer-points buffer)
                 :always (and (point-line p)
                              (line:line-alive-p (point-line p)))))
         (model
           (list (mapcar #'line-codepoints region-lines)
                 (list* (list 0 1 0 :right-inserting)
                        (list 1
                              nrel
                              (line:line-length (car (last region-lines)))
                              :left-inserting)
                        (list 2 1 0 :left-inserting)
                        (loop :with id := 2
                              :for line :in region-lines
                              :for linum-rel :from 1
                              :append (loop :for p :in (line:line-points line)
                                            :collect (list (incf id)
                                                           linum-rel
                                                           (point-charpos p)
                                                           (point-kind p)))))
                 0)))
    (unless (and linum-agreement
                 lines-alive
                 (lem/kernel:wf-buffer model))
      (log:error "paranoid edit-engine check failed"
                 base-linum extra-lines linum-agreement lines-alive)
      (warn 'corruption-warning
            :format-control "paranoid edit-engine check failed at line ~d"
            :format-arguments (list base-linum)))))

(defun buffer-full-model (buffer)
  "Full kernel model of BUFFER: every line as a codepoint list, every
registered point as (id linum charpos kind) with positional ids over
`buffer-points` (stable across a single edit), tick 0 (tick semantics belong
to the undo layer, SPEC-VK VK-3)."
  (list (loop :for line := (point-line (buffer-start-point buffer))
                :then (line:line-next line)
              :while line
              :collect (line-codepoints line))
        (loop :for p :in (buffer-points buffer)
              :for id :from 0
              :collect (list id (point-linum p) (point-charpos p) (point-kind p)))
        0))

(defun conformance-check-edit (buffer kernel-model deleted-codes killring)
  "Conformance-mode comparison (SPEC-VK VK-4): the materialized production
state must equal KERNEL-MODEL -- the full kernel's answer on the full pre-edit
model -- field-for-field: lines, every registered point, cached nlines, and
\(for deletes) the killring string against the kernel's deleted payload. The
model tick is excluded: `buffer-modify` runs outside the mirrored mutation and
its +-1 semantics is VK-3's, pinned by kernel-undo-conformance."
  (let ((post (buffer-full-model buffer)))
    (unless (and (equal (first post) (first kernel-model))
                 (equal (second post) (second kernel-model))
                 (= (buffer-nlines buffer) (length (first kernel-model)))
                 (or (null killring)
                     (equal (string-codepoints killring) deleted-codes)))
      (error 'edit-engine-conformance-error
             :format-control "edit-engine conformance mismatch:~% prod ~s~% kern ~s"
             :format-arguments (list post kernel-model)))))

;;; ---------------------------------------------------------------------------
;;; The edit primitives: line surgery + kernel marker relocation
;;; ---------------------------------------------------------------------------

(defun %insert-string/point (buffer point string)
  "Line surgery + kernel marker relocation for `insert-string/point`.
Returns the number of line splits (the kernel's offset-line)."
  (loop :with start := 0
        :for pos := (position #\newline string :start start)
        :for line := (point-line point) :then (line:line-next line)
        :for charpos := (point-charpos point) :then 0
        :for offset-line :from 0
        :do (cond ((null pos)
                   (let ((substr (if (= start 0) string (subseq string start))))
                     (line:insert-string line substr charpos)
                     (kernel-shift-markers point offset-line (length substr)))
                   (return offset-line))
                  (t
                   (let ((substr (subseq string start pos)))
                     (line:insert-string line substr charpos)
                     (line:insert-newline line (+ charpos (length substr)))
                     (incf (buffer-nlines buffer))
                     (setf start (1+ pos)))))))

(defun %delete-char/point (buffer point remaining-deletions)
  "Line surgery + kernel marker relocation for `delete-char/point`.
Returns the deleted text (the killring string)."
  (with-output-to-string (killring-stream)
    (let ((charpos (point-charpos point))
          (line (point-line point))
          (offset-line 0))
      (loop :while (plusp remaining-deletions)
            :for eolp := (> remaining-deletions
                            (- (line:line-length line) charpos))
            :do (cond
                  ((not eolp)
                   (let ((end (+ charpos remaining-deletions)))
                     (write-string (line:line-substring line :start charpos :end end)
                                   killring-stream)
                     (line:delete-region line :start charpos :end end))
                   (kernel-shift-markers point offset-line (- remaining-deletions))
                   (return))
                  ((null (line:line-next line))
                   (let ((offset (- charpos (line:line-length line))))
                     (write-string (line:line-substring line :start charpos) killring-stream)
                     (line:delete-region line :start charpos)
                     (kernel-shift-markers point offset-line offset))
                   (return))
                  (t
                   (decf (buffer-nlines buffer))
                   (decf remaining-deletions (1+ (- (line:line-length line) charpos)))
                   (write-line (line:line-substring line :start charpos) killring-stream)
                   (line:merge-with-next-line line :start charpos)))
                (decf offset-line)
            :finally (kernel-shift-markers point offset-line 0)))))

(defgeneric insert-string/point (point string)
  (:method (point string)
    (let ((buffer (point-buffer point)))
      (with-modify-buffer (point 0)
        (ecase *edit-engine-mode*
          (:release
           (%insert-string/point buffer point string))
          (:paranoid
           (let* ((base-line (point-line point))
                  (base-linum (point-linum point))
                  (offset-line (%insert-string/point buffer point string)))
             (paranoid-check-edit buffer base-line base-linum offset-line)))
          (:conformance
           (let ((linum (point-linum point))
                 (charpos (point-charpos point))
                 (pre-model (buffer-full-model buffer)))
             (%insert-string/point buffer point string)
             (conformance-check-edit
              buffer
              (lem/kernel:k-insert pre-model linum charpos
                                   (string-codepoints string))
              nil nil))))))
    string))

(defgeneric delete-char/point (point remaining-deletions)
  (:method (point remaining-deletions)
    (let ((buffer (point-buffer point)))
      (with-modify-buffer (point remaining-deletions)
        (ecase *edit-engine-mode*
          (:release
           (%delete-char/point buffer point remaining-deletions))
          (:paranoid
           (let* ((base-line (point-line point))
                  (base-linum (point-linum point))
                  (string (%delete-char/point buffer point remaining-deletions)))
             (paranoid-check-edit buffer base-line base-linum 0)
             string))
          (:conformance
           (let ((linum (point-linum point))
                 (charpos (point-charpos point))
                 (pre-model (buffer-full-model buffer)))
             (multiple-value-bind (kernel-model deleted)
                 (lem/kernel:k-delete pre-model linum charpos remaining-deletions)
               (let ((string (%delete-char/point buffer point remaining-deletions)))
                 (conformance-check-edit buffer kernel-model deleted string)
                 string)))))))))


(defun call-before-change-functions (point arg)
  (unless *inhibit-modification-hooks*
    (run-hooks (make-per-buffer-hook :var 'before-change-functions :buffer (point-buffer point))
               point arg)))

(defun call-after-change-functions (buffer start end old-len)
  (unless *inhibit-modification-hooks*
    (run-hooks (make-per-buffer-hook :var 'after-change-functions :buffer buffer)
               start end old-len)))

(defun need-to-call-after-change-functions-p (buffer)
  (and (not *inhibit-modification-hooks*)
       (or (variable-value 'after-change-functions :buffer buffer)
           (variable-value 'after-change-functions :global))))

(defun insert/after-change-function (point arg call-next-method)
  (if (need-to-call-after-change-functions-p (point-buffer point))
      (with-point ((start point))
        (prog1 (funcall call-next-method)
          (with-point ((end start))
            (character-offset end arg)
            (call-after-change-functions (point-buffer point) start end 0))))
      (funcall call-next-method)))

(defun delete/after-change-function (point call-next-method)
  (if (need-to-call-after-change-functions-p (point-buffer point))
      (let ((string (funcall call-next-method)))
        (with-point ((start point)
                     (end point))
          (call-after-change-functions (point-buffer point) start end (length string)))
        string)
      (funcall call-next-method)))

(defmethod insert-string/point :around (point string)
  (call-before-change-functions point string)
  (let ((buffer (point-buffer point)))
    (cond ((buffer-enable-undo-p buffer)
           (let ((position (position-at-point point)))
             (prog1 (insert/after-change-function point (length string) #'call-next-method)
               (let ((edit (make-edit :insert-string position string)))
                 (if (inhibit-undo-p)
                     (recompute-undo-position-offset buffer edit)
                     (push-undo buffer edit))))))
          (t
           (prog1 (insert/after-change-function point (length string) #'call-next-method)
             (when (inhibit-undo-p)
               (let ((edit (make-edit :insert-string (position-at-point point) string)))
                 (recompute-undo-position-offset buffer edit))))))))

(defmethod delete-char/point :around (point remaining-deletions)
  (call-before-change-functions point remaining-deletions)
  (let ((buffer (point-buffer point)))
    (cond ((buffer-enable-undo-p buffer)
           (let* ((position (position-at-point point))
                  (string (delete/after-change-function point #'call-next-method))
                  (edit (make-edit :delete-string position string)))
             (if (inhibit-undo-p)
                 (recompute-undo-position-offset buffer edit)
                 (push-undo buffer edit))
             string))
          (t
           (let ((string (delete/after-change-function point #'call-next-method)))
             (when (inhibit-undo-p)
               (let ((edit (make-edit :delete-string
                                      (position-at-point point)
                                      string)))
                 (recompute-undo-position-offset buffer edit)))
             string)))))
