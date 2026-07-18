;;;; tests/pbt/redisplay-cache.lisp -- SPEC-VK VK-12 suite 1: redisplay cache
;;;; soundness (PBT, no ACL2 book -- the composed CLOS redisplay pipeline is
;;;; verified empirically, by design; see SPEC-VK VK-12 and verified/README.md).
;;;;
;;;; PROPERTY (the cache may skip work, never change output).  For a random
;;;; edit / scroll / resize script driven against a real Lem editor session
;;;; under the recording fake interface (frontends/fake-interface/), the FINAL
;;;; rendered frame content must be IDENTICAL whether the redisplay caches
;;;; (the per-window drawing-object cache and the line-fingerprint cache in
;;;; src/display/physical-line.lisp) are live or force-invalidated every frame.
;;;;
;;;; MECHANISM.  Two independent windows over two buffers with identical content
;;;; are driven in lockstep through the same script:
;;;;   * CACHED window -- redrawn with FORCE = NIL and never marked
;;;;     need-to-redraw, so it relies purely on the fingerprint/object caches to
;;;;     detect content changes (a strictly harder test than production, which
;;;;     force-clears the caches on the current window after every command);
;;;;   * FRESH window -- redrawn with FORCE = T, which clears both caches every
;;;;     frame, so it always emits a full, ground-truth render.
;;;; The recording interface paints each render-line into a PERSISTENT per-view
;;;; grid (modelling the SDL2 persistent texture), so a frame the cache skips
;;;; keeps the previously drawn row.  After every step the two persistent grids
;;;; must be equal; a stale/ghosted row (the exact failure an unsound cache
;;;; produces on a persistent-texture frontend) makes them diverge.
;;;;
;;;; FOLDED-IN display-cache.lisp invariants (fixed cases): an attribute mutated
;;;; in place (the SET-ATTRIBUTE / shared-cursor hazard the line fingerprint must
;;;; catch) and the stale-tail hazard after a large deletion whose rows were
;;;; blanked by clear-to-end-of-window and then restored (the
;;;; evict-line-fingerprints-from / remove-drawing-cache-entries-from case).
;;;;
;;;; Codepoint<->string conversion (code-char / char-code) lives here, never in
;;;; a kernel book.  Internal display symbols (redraw-buffer is exported;
;;;; make-window / window-scroll-*-n / set-window-{width,height} are display-layer
;;;; internals reached via lem-core:: exactly as the other white-box suites do).

(defpackage :lem-tests/pbt/redisplay-cache
  (:use :cl
        :rove
        :lem-tests/pbt/harness)
  (:import-from :lem-fake-interface
                :with-recording-interface
                :recording-view-grid
                :recording-frame-alist))
(in-package :lem-tests/pbt/redisplay-cache)

;;; ------------------------------------------------------------------
;;; Panes: a buffer + a standalone (non-current) recording window
;;; ------------------------------------------------------------------

(defstruct (pane (:constructor %make-pane)) buffer window)

(defun make-pane (name width height line-wrap-p)
  (let ((buffer (lem:make-buffer name :temporary t)))
    (setf (lem:variable-value 'lem:line-wrap :buffer buffer) line-wrap-p)
    (let ((window (lem-core::make-window buffer 0 0 width height nil)))
      (%make-pane :buffer buffer :window window))))

(defun pane-view (pane)
  (lem:window-view (pane-window pane)))

(defun pane-char-count (pane)
  (1- (lem:position-at-point (lem:buffer-end-point (pane-buffer pane)))))

(defun clamp-position (pane raw)
  (1+ (mod raw (1+ (pane-char-count pane)))))

(defun render-pane (pane force)
  (let ((window (pane-window pane)))
    (lem-core::redraw-buffer (lem:implementation)
                             (pane-buffer pane)
                             window
                             force)))

(defun resize-pane (pane width height)
  ;; Mirror production window-set-size (src/window/window.lisp): a resize marks
  ;; the window need-to-redraw, which force-clears the caches on the next frame.
  ;; The line fingerprint deliberately does NOT include the view width -- its
  ;; soundness relies on this invalidation, so the test must reproduce it.
  (let ((window (pane-window pane)))
    (lem-core::set-window-width width window)
    (lem-core::set-window-height height window)
    (lem-core::need-to-redraw window)
    (lem-if:set-view-size (lem:implementation) (lem:window-view window) width height)))

(defun apply-op (pane op)
  "Apply data OP to PANE's buffer/window.  Out-of-range positions are clamped;
production ops never signal for clamped requests, so this never rejects."
  (let* ((buffer (pane-buffer pane))
         (point (lem:buffer-point buffer))
         (window (pane-window pane)))
    (ecase (first op)
      (:insert
       (lem:move-to-position point (clamp-position pane (second op)))
       (lem:insert-string point (third op)))
      (:delete
       (lem:move-to-position point (clamp-position pane (second op)))
       (lem:delete-character point (third op)))
      (:scroll
       ;; Raw view-point moves (no need-to-redraw mark) keep the caches live
       ;; across the scroll -- maximum pressure on the stale-row eviction paths.
       (let ((n (second op)))
         (if (plusp n)
             (lem-core::window-scroll-down-n window n)
             (lem-core::window-scroll-up-n window (- n)))))
      (:resize
       (resize-pane pane (second op) (third op)))
      (:redraw nil))))

;;; ------------------------------------------------------------------
;;; Script generation (data only, shrinkable)
;;; ------------------------------------------------------------------

(defun gen-cache-op ()
  (let ((string-gen (gen-string :max-length 6)))
    (make-generator
     :sample (lambda (rng)
               (ecase (rng-below rng 6)
                 (0 (list :insert (rng-below rng 120)
                          (let ((s (draw string-gen rng)))
                            (if (< (rng-below rng 100) 35)
                                (let ((i (rng-below rng (1+ (length s)))))
                                  (concatenate 'string (subseq s 0 i)
                                               (string #\Newline)
                                               (subseq s i)))
                                s))))
                 (1 (list :delete (rng-below rng 120) (rng-range rng 1 6)))
                 (2 (list :scroll (rng-range rng -3 3)))
                 ;; Width >= 4: a window narrower than the widest glyph (width 2)
                 ;; makes production's wrap-offset scan (map-wrapping-line, goal =
                 ;; body-width - 1) unable to advance under line-wrap -- an
                 ;; infinite loop at window width <= 2 that a real terminal never
                 ;; reaches.  Documented in verified/README.md VK-12.
                 (3 (list :resize (rng-range rng 4 24) (rng-range rng 1 14)))
                 (4 (list :redraw))
                 (5 (list :redraw))))
     :shrink (lambda (op)
               ;; Shrink an :insert's string and any op toward :redraw.
               (case (first op)
                 (:insert
                  (append (loop :for s :in (shrink-string (third op))
                                :collect (list :insert (second op) s))
                          (list (list :redraw))))
                 (:redraw '())
                 (t (list (list :redraw))))))))

(defun gen-cache-script (&key (max-ops 18))
  (gen-list (gen-cache-op) :max-length max-ops))

(defun gen-geometry ()
  (make-generator
   :sample (lambda (rng)
             (list (rng-range rng 4 24)          ; width (>= 4, see gen-cache-op)
                   (rng-range rng 1 14)          ; height
                   (rng-boolean rng)))           ; line-wrap
   :shrink (lambda (g)
             (destructuring-bind (w h wrap) g
               (append (when (> w 4) (list (list 4 h wrap)))
                       (when (> h 1) (list (list w 1 wrap)))
                       (when wrap (list (list w h nil))))))))

;;; ------------------------------------------------------------------
;;; Scenario: run one script, compare the two persistent grids each step
;;; ------------------------------------------------------------------

(defvar *pane-counter* 0)

(defun run-cache-scenario (initial-lines script geometry)
  "Drive SCRIPT against a CACHED and a FRESH pane (identical content/geometry).
Return T iff the persistent grids match after seeding and after every step."
  (destructuring-bind (width height line-wrap-p) geometry
    (let* ((tag (incf *pane-counter*))
           (cached (make-pane (format nil "vk12-cache-c-~D" tag) width height line-wrap-p))
           (fresh (make-pane (format nil "vk12-cache-f-~D" tag) width height line-wrap-p))
           (seed-text (buffer-content->string initial-lines)))
      (flet ((seed (pane)
               (lem:insert-string (lem:buffer-point (pane-buffer pane)) seed-text)
               (lem:move-to-position (lem:buffer-point (pane-buffer pane)) 1))
             (grids-equal-p ()
               (equal (recording-frame-alist (pane-view cached))
                      (recording-frame-alist (pane-view fresh)))))
        (seed cached)
        (seed fresh)
        (render-pane cached nil)
        (render-pane fresh t)
        (unless (grids-equal-p) (return-from run-cache-scenario nil))
        (dolist (op script t)
          (apply-op cached op)
          (apply-op fresh op)
          (render-pane cached nil)
          (render-pane fresh t)
          (unless (grids-equal-p)
            (return-from run-cache-scenario nil)))))))

;;; ------------------------------------------------------------------
;;; Randomized property
;;; ------------------------------------------------------------------

(defparameter *cache-scripts* 40
  "Random scripts per run.  40 scripts * (1 seed + up to 18 steps) * 2 renders
(cached + fresh) is ~600-800 renders here; together with suite 2's ~500 this
compares well over ~1k random frames total, measured a few seconds combined --
far under the ~2-3 min CI budget.")

(deftest cache-soundness-differential
  (with-recording-interface ()
    (let ((*num-tests* *cache-scripts*))
      (for-all ((initial (gen-buffer-content :max-lines 6 :max-line-length 16))
                (script (gen-cache-script))
                (geometry (gen-geometry)))
        (run-cache-scenario initial script geometry)))))

;;; ------------------------------------------------------------------
;;; Fixed cases folding in the display-cache.lisp invariants
;;; ------------------------------------------------------------------

(defun first-line-fingerprint (window)
  "compute-line-fingerprint of WINDOW's first logical line (built the real way,
via create-logical-line inside do-logical-line)."
  (let ((result nil) (i 0))
    (lem-core::do-logical-line (logical-line window)
      (when (zerop i)
        (setf result (lem-core::compute-line-fingerprint logical-line 0 0)))
      (incf i))
    result))

(deftest cache-soundness-attribute-mutation
  ;; Folds tests/display-cache.lisp's fingerprint invariant end to end, through
  ;; the real overlay -> create-logical-line path: an attribute recoloured IN
  ;; PLACE (same identity, changed content -- as color-theme.lisp and the
  ;; vi/skk cursor-recolour paths do) must change compute-line-fingerprint, so
  ;; the fingerprint gate re-derives the line.
  ;;
  ;; The downstream drawing-object cache is REFERENCE based (drawing-object-equal
  ;; -> attribute-equal), so it cannot by itself observe an in-place mutation:
  ;; the cached object and the freshly built object share the one mutated
  ;; attribute, hence compare equal.  Production closes this by pairing a
  ;; recolour with need-to-redraw (which force-clears both caches); that residue
  ;; is documented precisely in verified/README.md VK-12.  This test asserts the
  ;; fingerprint invariant that holds, then that the production-faithful recolour
  ;; redraw (need-to-redraw) yields identical cached/fresh frames carrying the
  ;; new colour.
  (with-recording-interface ()
    (let* ((attribute (lem:make-attribute :foreground "#FF0000" :background "#000000"))
           (cached (make-pane "vk12-attr-cached" 40 8 nil))
           (fresh (make-pane "vk12-attr-fresh" 40 8 nil)))
      (flet ((setup (pane)
               (let ((buffer (pane-buffer pane)))
                 (lem:insert-string (lem:buffer-point buffer)
                                    (format nil "alpha~%beta~%gamma"))
                 (lem:move-to-position (lem:buffer-point buffer) 1)
                 ;; Overlay the shared attribute across the first line.
                 (lem:with-point ((start (lem:buffer-start-point buffer))
                                  (end (lem:buffer-start-point buffer)))
                   (lem:line-end end)
                   (lem:make-overlay start end attribute))))
             (grids-equal-p ()
               (equal (recording-frame-alist (pane-view cached))
                      (recording-frame-alist (pane-view fresh)))))
        (setup cached)
        (setup fresh)
        (render-pane cached nil)
        (render-pane fresh t)
        (ok (grids-equal-p) "matches before mutation")
        ;; (a) The display-cache fingerprint invariant, through the real path.
        (let ((fingerprint-before (first-line-fingerprint (pane-window cached))))
          (lem:set-attribute attribute :background "#00FF00" :bold t)
          (ok (not (eql fingerprint-before (first-line-fingerprint (pane-window cached))))
              "line fingerprint tracks the in-place attribute mutation"))
        ;; (b) A production-faithful recolour redraw (need-to-redraw, as
        ;; color-theme.lisp sets) updates the frame identically on both panes.
        (lem-core::need-to-redraw (pane-window cached))
        (render-pane cached nil)
        (render-pane fresh t)
        (ok (grids-equal-p) "recolour redraw yields identical frames")))))

(deftest cache-soundness-stale-tail
  ;; The stale-tail hazard: a large deletion blanks the window's lower rows via
  ;; clear-to-end-of-window (evicting fingerprint + drawing-cache entries for
  ;; those rows); re-inserting identical content must NOT let a later frame match
  ;; a stale entry and skip the render, which on a persistent-texture frontend
  ;; would leave the row blank.  Exercised end to end: fill, render, delete the
  ;; tail, render, restore identical tail, render -- comparing to a forced full
  ;; render throughout.
  (with-recording-interface ()
    (let* ((cached (make-pane "vk12-tail-cached" 30 12 nil))
           (fresh (make-pane "vk12-tail-fresh" 30 12 nil))
           (body (format nil "~{line-~2,'0D~^~%~}" (loop :for i :below 10 :collect i)))
           (tail (format nil "~%tail-a~%tail-b~%tail-c")))
      (flet ((op-both (thunk)
               (funcall thunk cached)
               (funcall thunk fresh)
               (render-pane cached nil)
               (render-pane fresh t))
             (grids-equal-p ()
               (equal (recording-frame-alist (pane-view cached))
                      (recording-frame-alist (pane-view fresh)))))
        ;; Fill with body + tail.
        (op-both (lambda (p)
                   (lem:insert-string (lem:buffer-point (pane-buffer p))
                                      (concatenate 'string body tail))
                   (lem:move-to-position (lem:buffer-point (pane-buffer p)) 1)))
        (ok (grids-equal-p) "matches when full")
        ;; Delete the tail (blank the lower rows).
        (op-both (lambda (p)
                   (let ((point (lem:buffer-point (pane-buffer p))))
                     (lem:move-to-position point (1+ (length body)))
                     (lem:delete-character point (length tail)))))
        (ok (grids-equal-p) "matches after deleting the tail")
        ;; Re-insert the identical tail (grow back into the blanked rows).
        (op-both (lambda (p)
                   (let ((point (lem:buffer-point (pane-buffer p))))
                     (lem:move-to-position point (1+ (length body)))
                     (lem:insert-string point tail))))
        (ok (grids-equal-p)
            "restored tail re-renders (no stale fingerprint/object cache hit)")))))
