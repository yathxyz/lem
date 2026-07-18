(defpackage :lem-fake-interface
  (:use :cl :lem)
  (:export :fake-interface
           :with-fake-interface
           :get-displayed-text
           ;; Recording frontend (SPEC-VK VK-12): a fake interface whose
           ;; render-line paints into a persistent per-view character grid,
           ;; modelling a persistent-texture frontend (SDL2) so that a frame
           ;; skipped by the redisplay cache retains the previously drawn
           ;; content -- exactly the surface a cache-soundness bug corrupts.
           :recording-fake-interface
           :with-recording-interface
           :recording-view
           :recording-view-grid
           :recording-view-cursor
           :recording-frame-alist
           :recording-cells-text
           :recording-cells-width))
(in-package :lem-fake-interface)

(defclass fake-interface (lem:implementation)
  ((foreground
    :initform nil
    :accessor fake-interface-foreground)
   (background
    :initform nil
    :accessor fake-interface-background)
   (display-width
    :initform 80
    :reader fake-interface-display-width)
   (display-height
    :initform 24
    :reader fake-interface-display-height))
  (:default-initargs
   :name :fake
   :redraw-after-modifying-floating-window t))

(defstruct view
  x
  y
  width
  height
  modeline
  lines)

(defun get-displayed-text (&optional (window (current-window)))
  (let ((lines (view-lines (screen-view (window-screen window)))))
    (with-output-to-string (out)
      (loop :for line :across lines
            :for line-string := (string-right-trim (string (code-char 0)) line)
            :do (fresh-line out)
                (write-string line-string out)))))

(defmethod lem-if:invoke ((implementation fake-interface) function)
  (funcall function))

(defmethod lem-if:get-background-color ((implementation fake-interface))
  (make-color 0 0 0))

(defmethod lem-if:update-foreground ((implementation fake-interface) color-name)
  (setf (fake-interface-foreground implementation) color-name))

(defmethod lem-if:update-background ((implementation fake-interface) color-name)
  (setf (fake-interface-background implementation) color-name))

(defmethod lem-if:display-width ((implementation fake-interface))
  (fake-interface-display-width implementation))

(defmethod lem-if:display-height ((implementation fake-interface))
  (fake-interface-display-height implementation))

(defmethod lem-if:make-view ((implementation fake-interface) window x y width height use-modeline)
  (make-view
   :x x
   :y y
   :width width
   :height height
   :modeline use-modeline
   :lines (let ((lines (make-array height)))
            (dotimes (i height)
              (setf (aref lines i)
                    (make-string width :initial-element (code-char 0))))
            lines)))

(defmethod lem-if:delete-view ((implementation fake-interface) view)
  nil)

(defmethod lem-if:clear ((implementation fake-interface) view)
  nil)

(defmethod lem-if:set-view-size ((implementation fake-interface) view width height)
  (setf (view-width view) width
        (view-height view) height))

(defmethod lem-if:set-view-pos ((implementation fake-interface) view x y)
  (setf (view-x view) x
        (view-y view) y))

(defmethod lem-if:update-display ((implementation fake-interface)))

(defmethod lem-if:view-width ((implementation fake-interface) view)
  (view-width view))

(defmethod lem-if:view-height ((implementation fake-interface) view)
  (view-height view))

(defmethod lem-if:object-width ((implementation fake-interface) object)
  1)

(defmethod lem-if:object-height ((implementation fake-interface) object)
  1)

(defmethod lem-if:render-line ((implementation fake-interface) view x y objects height)
  nil)

(defmethod lem-if:clear-to-end-of-window ((implementation fake-interface) view y)
  nil)

(defmethod lem-if:get-char-width ((implementation fake-interface))
  1)

(defmethod lem-if:get-char-height ((implementation fake-interface))
  1)

(defmethod lem-if:render-line-on-modeline ((implementation fake-interface)
                                           view
                                           left-objects
                                           right-objects
                                           default-attribute
                                           height)
  nil)

(defmacro with-fake-interface (() &body body)
  `(with-implementation (make-instance 'fake-interface)
     (setup-first-frame)
     ,@body))

;;; ===========================================================================
;;; Recording fake interface (SPEC-VK VK-12)
;;; ===========================================================================
;;;
;;; The base `fake-interface' above has a no-op `render-line' and a constant
;;; `object-width' of 1, so it captures nothing about what would be drawn.  The
;;; recording subclass below is additive (all existing users keep the base
;;; class unchanged) and does two things a screen-fidelity test needs:
;;;
;;;   1. `object-width' returns the REAL display width (string-width for text
;;;      objects, 0 for everything else) -- the ncurses semantics
;;;      (frontends/ncurses/drawing-object.lisp), so wrapping and clipping match
;;;      the terminal reality instead of collapsing every object to width 1.
;;;
;;;   2. `render-line' records each drawn row into a persistent grid keyed by
;;;      screen row Y, and `clear-to-end-of-window' evicts rows from Y down.
;;;      Because the grid PERSISTS across frames, a frame the redisplay cache
;;;      skips leaves the previous row content in place -- modelling the SDL2
;;;      persistent texture, where an unsound cache produces stale (ghosted)
;;;      pixels.  Comparing the persistent grid of a cached render against a
;;;      force-invalidated full render is therefore the exact cache-soundness
;;;      property (the cache may skip work, never change output).
;;;
;;; A recorded row is a list of CELLS, one per drawing object, in draw order.
;;; A cell is (KIND STRING ATTR-SIG WIDTH CURSOR-P); the ATTR-SIG is content
;;; based (foreground/background/bold/reverse/underline), so an attribute
;;; mutated in place -- the display-cache.lisp fingerprint hazard -- changes the
;;; recorded cell and a cache that failed to notice it diverges from the fresh
;;; render.

(defclass recording-fake-interface (fake-interface)
  ()
  (:default-initargs :name :fake-recording))

(defstruct recording-view
  x
  y
  width
  height
  modeline
  ;; screen-row Y -> list of cells (persistent across frames).
  (grid (make-hash-table :test 'eql))
  ;; (column . row) of the last drawn cursor object, or NIL.
  (cursor nil))

(defun attr-sig (attribute)
  "Content signature of ATTRIBUTE (NIL when absent).  Identity independent, so a
mutated-in-place attribute yields a different signature -- the property the
line-fingerprint cache must preserve (see tests/display-cache.lisp)."
  (when attribute
    (list (lem:attribute-foreground attribute)
          (lem:attribute-background attribute)
          (lem:attribute-bold attribute)
          (lem:attribute-reverse attribute)
          (lem:attribute-underline attribute))))

(defun object->cell (object)
  "Canonical record of a drawing OBJECT: (KIND STRING ATTR-SIG WIDTH CURSOR-P).
STRING is the already-resolved display text (tabs are pre-expanded to spaces in
the logical line, control chars appear as their ^X/\\N replacement, zero-width
chars as the middle dot), so concatenating the STRINGs of a row's text cells is
exactly the projected screen text."
  (typecase object
    (lem-core/display:text-object
     (list :text
           (lem-core/display:text-object-string object)
           (attr-sig (lem-core/display:text-object-attribute object))
           (lem-core::object-width object)
           (and (lem-core::cursor-object-p object) t)))
    (lem-core/display:eol-cursor-object
     (list :eol-cursor "" (list (lem-core/display:eol-cursor-object-color object)) 0 t))
    (lem-core/display:void-object
     (list :void "" nil 0 nil))
    (lem-core/display:extend-to-eol-object
     (list :extend "" (list (lem-core/display:extend-to-eol-object-color object)) 0 nil))
    (lem-core/display:image-object
     (list :image "" nil (lem-core/display:image-object-width object) nil))
    (t
     (list :other "" nil 0 nil))))

(defun cell-kind (cell) (first cell))
(defun cell-string (cell) (second cell))
(defun cell-width (cell) (fourth cell))
(defun cell-cursor-p (cell) (fifth cell))

(defun recording-cells-text (cells)
  "The concatenated display text of a recorded row (text and cursor cells only;
void/extend/image contribute nothing visible)."
  (with-output-to-string (out)
    (dolist (cell cells)
      (write-string (cell-string cell) out))))

(defun recording-cells-width (cells)
  "Total display column width of a recorded row."
  (loop :for cell :in cells :sum (cell-width cell)))

(defun recording-frame-alist (view)
  "The persistent grid of VIEW as a Y-sorted alist (Y . CELLS)."
  (let ((rows '()))
    (maphash (lambda (y cells) (push (cons y cells) rows))
             (recording-view-grid view))
    (sort rows #'< :key #'car)))

(defmethod lem-if:make-view ((implementation recording-fake-interface)
                             window x y width height use-modeline)
  (make-recording-view :x x :y y :width width :height height :modeline use-modeline))

(defmethod lem-if:delete-view ((implementation recording-fake-interface) view)
  nil)

(defmethod lem-if:clear ((implementation recording-fake-interface) view)
  (clrhash (recording-view-grid view))
  (setf (recording-view-cursor view) nil))

(defmethod lem-if:set-view-size ((implementation recording-fake-interface) view width height)
  (setf (recording-view-width view) width
        (recording-view-height view) height))

(defmethod lem-if:set-view-pos ((implementation recording-fake-interface) view x y)
  (setf (recording-view-x view) x
        (recording-view-y view) y))

(defmethod lem-if:view-width ((implementation recording-fake-interface) view)
  (recording-view-width view))

(defmethod lem-if:view-height ((implementation recording-fake-interface) view)
  (recording-view-height view))

;; ncurses object-width: text objects measure string-width, all others 0.
(defmethod lem-if:object-width ((implementation recording-fake-interface) object)
  (if (typep object 'lem-core/display:text-object)
      (lem:string-width (lem-core/display:text-object-string object))
      0))

(defmethod lem-if:render-line ((implementation recording-fake-interface)
                               view x y objects height)
  (declare (ignore height))
  (let ((cells (mapcar #'object->cell objects)))
    (setf (gethash y (recording-view-grid view)) cells)
    (loop :with col := x
          :for object :in objects
          :do (when (lem-core::cursor-object-p object)
                (setf (recording-view-cursor view) (cons col y)))
              (incf col (lem-if:object-width implementation object)))))

(defmethod lem-if:clear-to-end-of-window ((implementation recording-fake-interface) view y)
  (let ((grid (recording-view-grid view))
        (stale '()))
    (maphash (lambda (row cells)
               (declare (ignore cells))
               (when (>= row y) (push row stale)))
             grid)
    (dolist (row stale) (remhash row grid)))
  (let ((cursor (recording-view-cursor view)))
    (when (and cursor (>= (cdr cursor) y))
      (setf (recording-view-cursor view) nil))))

(defmacro with-recording-interface (() &body body)
  `(with-implementation (make-instance 'recording-fake-interface)
     (setup-first-frame)
     ,@body))
