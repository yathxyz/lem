;;;; tests/pbt/layout-conformance.lisp -- SPEC-VK VK-11 differential + property acceptance.
;;;;
;;;; Since the VK-4 layout swap, production `separate-objects-by-width' /
;;;; `clip-objects-to-display-range' ARE thin shells over the certified kernel
;;;; (verified/layout.lisp via the CLOS<->kernel adapter in
;;;; src/display/physical-line.lisp).  This suite therefore pins the ADAPTER --
;;;; the CLOS -> kernel-record -> CLOS round trip (per-char width decomposition,
;;;; tag-identity reuse, explode/clip rebuilds, marker attachment) -- against
;;;; the raw kernel, two ways:
;;;;
;;;;   1. DIFFERENTIAL: random drawing-object lists (narrow/wide/emoji runs,
;;;;      mixed-width runs, tabs, control characters, zero-width combining
;;;;      runs, opaque void objects) and random view widths (down to 1) are fed
;;;;      through PRODUCTION `separate-objects-by-width' (iterated exactly like
;;;;      the redraw loop, with its window-height row budget) and through
;;;;      kernel `k-wrap', comparing row break positions, per-row contents and
;;;;      per-object widths; likewise `clip-objects-to-display-range' vs
;;;;      `k-clip'.  Widths use the ncurses semantics (string-width; a
;;;;      test-local `lem:implementation' subclass supplies
;;;;      `lem-if:object-width', mirroring frontends/ncurses/drawing-object.lisp).
;;;;
;;;;      Deliberate input restrictions, mirroring documented deviations
;;;;      (verified/layout.lisp header, verified/README.md VK-11):
;;;;        * clip inputs now INCLUDE multi-char :control-typed objects and
;;;;          mixed-width runs: the pre-swap clip approximated per-char width
;;;;          as total/len and rebuilt a straddled :control object through
;;;;          make-object-with-type on the ALREADY-replaced string ("^A" ->
;;;;          NIL string); the swapped clip walks exact per-char widths
;;;;          (k-clip-chars) and rebuilds content-correctly, so both former
;;;;          exclusions are lifted (SPEC-VK VK-4, milestone-brief item 4).
;;;;        * tab objects are single tabs: the real pipeline never builds
;;;;          multi-char raw-tab text objects (tabs are expanded/replaced
;;;;          before drawing objects exist), and exploding one through
;;;;          production would re-classify it via char-type -> :control.
;;;;
;;;;   2. PROPERTY TESTS of the certified theorems on random inputs through
;;;;      the executable kernel: content/width-list preservation, the row
;;;;      width bound (opaque-excess form and strict zero-opaque form), the
;;;;      blocked-head characterization, the clip width bound, fully-visible
;;;;      retention, and the auto-scroll cursor-containment composition.
;;;;
;;;; Codepoint<->string conversion (code-char / char-code) happens here, never
;;;; inside a book.
;;;;
;;;; Internal-symbol access (contract.yml internal_symbol_rule): the functions
;;;; under differential test -- `separate-objects-by-width',
;;;; `clip-objects-to-display-range', `make-object-with-type', `object-width'
;;;; -- are deliberately unexported display internals, so this suite must
;;;; reach them via `lem-core::', exactly as other white-box tests do.

(defpackage :lem-tests/pbt/layout-conformance
  (:use :cl
        :rove
        :lem-tests/pbt/harness))
(in-package :lem-tests/pbt/layout-conformance)

;;; ------------------------------------------------------------------
;;; Kernel loading + accessors (find-symbol: no read-time package dep)
;;; ------------------------------------------------------------------

(defun repo-root ()
  (asdf:system-source-directory :lem-tests))

(defun ensure-kernel-loaded ()
  "Load the shim + certified layout book into this image once (idempotent)."
  (handler-bind ((warning #'muffle-warning))
    (unless (find-package "LEM/KERNEL")
      (load (merge-pathnames "verified/shim.lisp" (repo-root))))
    (let ((k (find-symbol "K-WRAP" "LEM/KERNEL")))
      (when (or (null k) (not (fboundp k)))
        (funcall (find-symbol "LOAD-VERIFIED-BOOK" "LEM/KERNEL") "layout")))))

(defun ktext (codes widths tag)
  (funcall (find-symbol "K-TEXT" "LEM/KERNEL") codes widths tag))
(defun kopaque (width tag)
  (funcall (find-symbol "K-OPAQUE" "LEM/KERNEL") width tag))
(defun kwrap (objects view-width fuel)
  (funcall (find-symbol "K-WRAP" "LEM/KERNEL") objects view-width fuel))
(defun kwrap-row (objects view-width total)
  (funcall (find-symbol "K-WRAP-ROW" "LEM/KERNEL") objects view-width total))
(defun kclip (objects x start-x end-x)
  (funcall (find-symbol "K-CLIP" "LEM/KERNEL") objects x start-x end-x))
(defun kscroll-adjust (start width cursor-x cursor-w)
  (funcall (find-symbol "K-SCROLL-ADJUST" "LEM/KERNEL") start width cursor-x cursor-w))

;;; ------------------------------------------------------------------
;;; Kernel record helpers (records are the book's documented list format)
;;; ------------------------------------------------------------------

(defun ktext-p (kobj) (eq (first kobj) :text))
(defun kcodes (kobj) (second kobj))
(defun kwidths (kobj) (third kobj))
(defun kobj-width (kobj)
  (if (ktext-p kobj)
      (reduce #'+ (kwidths kobj) :initial-value 0)
      (second kobj)))

(defun kobjs-contents (kobjs)
  "The book's k-objs-contents: text codes spliced, opaque objects verbatim."
  (loop :for kobj :in kobjs
        :append (if (ktext-p kobj) (copy-list (kcodes kobj)) (list kobj))))

(defun kobjs-wcontents (kobjs)
  (loop :for kobj :in kobjs
        :append (when (ktext-p kobj) (copy-list (kwidths kobj)))))

(defun krow-width (kobjs)
  (reduce #'+ kobjs :key #'kobj-width :initial-value 0))

(defun krow-opq-width (kobjs)
  (loop :for kobj :in kobjs
        :unless (ktext-p kobj)
        :sum (kobj-width kobj)))

;;; ------------------------------------------------------------------
;;; ncurses-width test frontend (production object-width during the diff)
;;; ------------------------------------------------------------------

(defclass layout-test-interface (lem:implementation)
  ()
  (:default-initargs :name :layout-conformance-test))

;; frontends/ncurses/drawing-object.lisp semantics: text objects measure
;; string-width, every other drawing object measures 0.
(defmethod lem-if:object-width ((implementation layout-test-interface) object)
  (if (typep object 'lem-core/display:text-object)
      (lem:string-width (lem-core/display:text-object-string object))
      0))

(defmacro with-layout-env ((buffer-var) &body body)
  `(lem-core:with-implementation (make-instance 'layout-test-interface)
     (let ((,buffer-var (lem:make-buffer "*layout-conformance*" :temporary t)))
       ,@body)))

;;; ------------------------------------------------------------------
;;; Object generation: specs are plain data (printable/shrinkable)
;;; ------------------------------------------------------------------

(defparameter *narrow-pool* (coerce (loop :for c :from 33 :to 126 :collect c) 'vector))
(defparameter *wide-pool* #(#x4E2D #x56FD #x3042 #xAC00 #x1F600 #x1F468))
(defparameter *zero-pool* #(#x300 #x301 #x36F))
(defparameter *greek-pool* #(#x391 #x3A9 #x3B1))

(defun spec-string (spec)
  (map 'string #'code-char (second spec)))

(defun per-char-widths (string)
  "Exact per-char ncurses widths: deltas of string-width over prefixes
(column-independent for every generated run; single tabs measure from col 0)."
  (loop :for i :from 0 :below (length string)
        :collect (- (lem:string-width string :end (1+ i))
                    (lem:string-width string :end i))))

(defun random-run (rng pool min-len max-len)
  (loop :repeat (rng-range rng min-len max-len)
        :collect (rng-element rng pool)))

(defun random-object-spec (rng)
  "One object spec: (KIND CODES). KIND :opaque has no codes; KIND :control
codes are the RAW control codepoint (object built via make-object-with-type)."
  (let ((kind (rng-element rng #(:narrow :wide :zero :mixed :tab :control :opaque))))
    (ecase kind
      (:narrow (list :narrow (random-run rng *narrow-pool* 1 6)))
      (:wide (list :wide (random-run rng *wide-pool* 1 3)))
      (:zero (list :zero (random-run rng *zero-pool* 1 2)))
      (:mixed (list :mixed (append (random-run rng *greek-pool* 1 2)
                                   (random-run rng *wide-pool* 1 2))))
      (:tab (list :tab (list 9)))
      (:control (list :control (list (rng-below rng 9))))
      (:opaque (list :opaque nil)))))

(defun gen-object-specs (&key (max-objects 7))
  (make-generator
   :sample (lambda (rng)
             (loop :repeat (rng-below rng (1+ max-objects))
                   :collect (random-object-spec rng)))
   :shrink (lambda (specs)
             (when (cdr specs)
               (list (butlast specs) (cdr specs))))))

(defun build-clos-object (spec)
  "Production drawing object for SPEC (inside the layout env)."
  (ecase (first spec)
    (:narrow (make-instance 'lem-core/display:text-object
                            :string (spec-string spec) :attribute nil :type :latin))
    ((:wide :zero :mixed)
     (make-instance 'lem-core/display:text-object
                    :string (spec-string spec) :attribute nil :type :cjk))
    (:tab (make-instance 'lem-core/display:text-object
                         :string (spec-string spec) :attribute nil :type :control))
    (:control (lem-core::make-object-with-type (spec-string spec) nil :control))
    (:opaque (make-instance 'lem-core/display:void-object))))

(defun build-kernel-object (spec index clos-object)
  "Kernel record matching CLOS-OBJECT (whose string a :control spec replaces)."
  (if (eq (first spec) :opaque)
      (kopaque 0 index)
      (let ((string (lem-core/display:text-object-string clos-object)))
        (ktext (map 'list #'char-code string)
               (per-char-widths string)
               index))))

(defun build-objects (specs)
  "Values: list of CLOS objects, list of matching kernel records."
  (let ((clos-objects '())
        (kernel-objects '()))
    (loop :for spec :in specs
          :for index :from 0
          :for clos-object := (build-clos-object spec)
          :do (push clos-object clos-objects)
              (push (build-kernel-object spec index clos-object) kernel-objects))
    (values (nreverse clos-objects) (nreverse kernel-objects))))

;;; ------------------------------------------------------------------
;;; Signatures: what both sides must agree on
;;; ------------------------------------------------------------------

(defun clos-signature (object)
  (if (typep object 'lem-core/display:text-object)
      (list :text
            (map 'list #'char-code (lem-core/display:text-object-string object))
            (lem-core::object-width object))
      (list :opaque)))

(defun kernel-signature (kobj)
  (if (ktext-p kobj)
      (list :text (kcodes kobj) (kobj-width kobj))
      (list :opaque)))

;;; ------------------------------------------------------------------
;;; 1a. Wrap differential
;;; ------------------------------------------------------------------

(defun production-wrap (objects view-width buffer max-rows)
  "Iterate production separate-objects-by-width exactly as k-wrap iterates
k-wrap-row (the redraw loop's height cutoff = MAX-ROWS; ncurses rows all have
height 1).  Values: rows (wrap marker stripped -- the kernel abstracts it as
the row boundary), leftover objects, and marker-ok (every wrapped row ended in
the wrap-line-character letter object, and no unwrapped row did)."
  (let ((wrap-string (string (lem:variable-value 'lem:wrap-line-character :default buffer)))
        (rows '())
        (marker-ok t))
    (loop :repeat max-rows
          :while objects
          :do (multiple-value-bind (row rest)
                  (lem-core::separate-objects-by-width objects view-width buffer)
                (cond (rest
                       (let ((marker (car (last row))))
                         (unless (and (typep marker 'lem-core/display:text-object)
                                      (equal wrap-string
                                             (lem-core/display:text-object-string marker)))
                           (setf marker-ok nil)))
                       (push (butlast row) rows))
                      (t (push row rows)))
                (setf objects rest)))
    (values (nreverse rows) objects marker-ok)))

(deftest wrap-differential
  (ensure-kernel-loaded)
  (for-all ((specs (gen-object-specs))
            (view-width (gen-integer :min 1 :max 20))
            (max-rows (gen-integer :min 1 :max 25)))
    (with-layout-env (buffer)
      (multiple-value-bind (clos-objects kernel-objects) (build-objects specs)
        (multiple-value-bind (production-rows production-rest marker-ok)
            (production-wrap clos-objects view-width buffer max-rows)
          (multiple-value-bind (kernel-rows kernel-rest)
              (kwrap kernel-objects view-width max-rows)
            (and marker-ok
                 (equal (mapcar (lambda (row) (mapcar #'clos-signature row))
                                production-rows)
                        (mapcar (lambda (row) (mapcar #'kernel-signature row))
                                kernel-rows))
                 (equal (mapcar #'clos-signature production-rest)
                        (mapcar #'kernel-signature kernel-rest)))))))))

;;; ------------------------------------------------------------------
;;; 1b. Clip differential
;;; ------------------------------------------------------------------

(deftest clip-differential
  (ensure-kernel-loaded)
  (for-all ((specs (gen-object-specs))
            (start-x (gen-integer :min 0 :max 30))
            (range (gen-integer :min 0 :max 30)))
    (with-layout-env (buffer)
      (declare (ignorable buffer))
      (multiple-value-bind (clos-objects kernel-objects) (build-objects specs)
        (equal (mapcar #'clos-signature
                       (lem-core::clip-objects-to-display-range
                        clos-objects start-x (+ start-x range)))
               (mapcar #'kernel-signature
                       (kclip kernel-objects 0 start-x (+ start-x range))))))))

;;; ------------------------------------------------------------------
;;; 2. Property tests of the certified theorems (kernel exec)
;;; ------------------------------------------------------------------

(defun random-kernel-objects (rng &key zero-opaque)
  (loop :repeat (rng-below rng 7)
        :for tag :from 0
        :collect (if (zerop (rng-below rng 4))
                     (kopaque (if zero-opaque 0 (rng-below rng 12)) tag)
                     (let ((n (rng-range rng 1 6)))
                       (ktext (loop :repeat n :collect (rng-below rng 500))
                              (loop :repeat n :collect (rng-below rng 9))
                              tag)))))

(defun gen-kernel-objects (&key zero-opaque)
  (make-generator
   :sample (lambda (rng) (random-kernel-objects rng :zero-opaque zero-opaque))
   :shrink (lambda (objs) (when (cdr objs) (list (butlast objs) (cdr objs))))))

(deftest wrap-theorem-properties
  (ensure-kernel-loaded)
  ;; Obligation 1: content + width-list preservation across k-wrap.
  (for-all ((objects (gen-kernel-objects))
            (view-width (gen-integer :min 0 :max 15))
            (fuel (gen-integer :min 0 :max 20)))
    (multiple-value-bind (rows rest) (kwrap objects view-width fuel)
      (let ((row-objects (apply #'append rows)))
        (and (equal (append (kobjs-contents row-objects) (kobjs-contents rest))
                    (kobjs-contents objects))
             (equal (append (kobjs-wcontents row-objects) (kobjs-wcontents rest))
                    (kobjs-wcontents objects))))))
  ;; Obligation 2: general bound (excess only from opaque objects) and the
  ;; strict zero-opaque (ncurses) corollary.
  (for-all ((objects (gen-kernel-objects))
            (view-width (gen-integer :min 1 :max 15))
            (fuel (gen-integer :min 0 :max 20)))
    (every (lambda (row)
             (<= (krow-width row)
                 (+ (krow-opq-width row) (max 0 (1- view-width)))))
           (nth-value 0 (kwrap objects view-width fuel))))
  (for-all ((objects (gen-kernel-objects :zero-opaque t))
            (view-width (gen-integer :min 1 :max 15))
            (fuel (gen-integer :min 0 :max 20)))
    (every (lambda (row) (< (krow-width row) view-width))
           (nth-value 0 (kwrap objects view-width fuel))))
  ;; Blocked-head characterization (the precise unbreakable exception).
  (for-all ((objects (gen-kernel-objects))
            (view-width (gen-integer :min 1 :max 6)))
    (multiple-value-bind (row rest) (kwrap-row objects view-width 0)
      (or (consp row)
          (null rest)
          (let ((head (first rest)))
            (and (ktext-p head)
                 (<= (length (kcodes head)) 1)
                 (<= view-width (kobj-width head))))))))

(deftest clip-theorem-properties
  (ensure-kernel-loaded)
  ;; Obligation 4a: clipped output fits the display range.
  (for-all ((objects (gen-kernel-objects :zero-opaque t))
            (start-x (gen-integer :min 0 :max 25))
            (range (gen-integer :min 0 :max 25)))
    (<= (krow-width (kclip objects 0 start-x (+ start-x range)))
        range))
  ;; Obligation 4b: fully-visible objects survive clipping verbatim.
  (for-all ((objects (gen-kernel-objects))
            (start-x (gen-integer :min 0 :max 20))
            (range (gen-integer :min 1 :max 25)))
    (let* ((end-x (+ start-x range))
           (clipped (kclip objects 0 start-x end-x)))
      (loop :with x := 0
            :for kobj :in objects
            :for w := (kobj-width kobj)
            :always (or (not (and (<= start-x x) (< x end-x)
                                  (<= (+ x w) end-x) (< start-x (+ x w))))
                        (member kobj clipped :test #'equal))
            :do (incf x w))))
  ;; Obligation 4c: auto-scroll adjustment contains the cursor cells, and the
  ;; composed clip keeps the cursor object.
  (for-all ((start (gen-integer :min 0 :max 30))
            (width (gen-integer :min 1 :max 20))
            (cursor-x (gen-integer :min 0 :max 40))
            (cursor-w (gen-integer :min 0 :max 20)))
    (or (> cursor-w width)
        (let ((adjusted (kscroll-adjust start width cursor-x cursor-w)))
          (and (<= adjusted cursor-x)
               (<= (+ cursor-x cursor-w) (+ adjusted width))))))
  (for-all ((objects (gen-kernel-objects))
            (start (gen-integer :min 0 :max 20))
            (width (gen-integer :min 1 :max 30))
            (extra (gen-integer :min 0 :max 5)))
    (let ((view-width (+ width extra)))
      (loop :with x := 0
            :for kobj :in objects
            :for w := (kobj-width kobj)
            :always (or (not (and (plusp w) (<= w width)))
                        (let ((adjusted (kscroll-adjust start width x w)))
                          (member kobj
                                  (kclip objects 0 adjusted (+ adjusted view-width))
                                  :test #'equal)))
            :do (incf x w)))))
