;;;; tests/pbt/screen-projection.lisp -- SPEC-VK VK-12 suite 2: screen-matches-
;;;; buffer projection (PBT, no ACL2 book -- see SPEC-VK VK-12).
;;;;
;;;; PROPERTY ("what you see is what's in the buffer").  For a random buffer
;;;; rendered through the recording fake interface, the concatenated visible text
;;;; of the rendered rows -- tabs expanded, control chars replaced, zero-width
;;;; chars shown as the middle dot, wrap-continuation markers stripped -- equals
;;;; the buffer's window-region text under that same projection, with the
;;;; VERIFIED width/layout kernel (verified/width.lisp k-char-width via
;;;; lem:string-width/char-width, and verified/layout.lisp k-wrap's certified
;;;; row-width bound) as the oracle for column layout and wrapping.
;;;;
;;;; The windows are STANDALONE and non-current, so no cursor overlay perturbs
;;;; the projection; a separate deterministic-geometry test drives the CURRENT
;;;; window to check cursor screen-column consistency against k-string-width.
;;;;
;;;; DOCUMENTED COVERAGE BOUNDARY (verified/README.md VK-12):
;;;;   * Production `expand-tab' (src/display/logical-line.lisp) computes tab
;;;;     stops over the CHARACTER INDEX, while the width kernel's tab-stop law is
;;;;     over the DISPLAY COLUMN; the two agree exactly on printable-ASCII runs
;;;;     (index = column).  The tab-projection test therefore uses printable
;;;;     ASCII and derives the expansion from the kernel (lem:char-width); raw
;;;;     tabs are excluded from the mixed-width (wide/control/zero-width) lines,
;;;;     where the two tab models diverge -- a production quirk, not a kernel
;;;;     property, recorded rather than papered over.
;;;;   * Floating windows / SDL2 surface-metric per-char widths and multi-cursor
;;;;     rendering are out of scope for fake-interface (the ncurses monospace
;;;;     model is what this suite drives), matching the VK-10/VK-11 non-goals.
;;;;
;;;; Codepoint<->string conversion lives here, never in a kernel book.  Internal
;;;; display symbols (char-type, make-window, redraw-buffer) are reached via
;;;; lem-core:: as the other white-box suites do.

(defpackage :lem-tests/pbt/screen-projection
  (:use :cl
        :rove
        :lem-tests/pbt/harness)
  (:import-from :lem-fake-interface
                :with-recording-interface
                :recording-frame-alist
                :recording-cells-text
                :recording-cells-width))
(in-package :lem-tests/pbt/screen-projection)

;;; ------------------------------------------------------------------
;;; Character pools (excluding TAB 9, NEWLINE 10, CR 13, and the wrap
;;; marker #\\ 92, which would be indistinguishable from a continuation
;;; marker in the wrap test)
;;; ------------------------------------------------------------------
;;;
;;; DELIBERATELY EXCLUDED: bare combining marks (e.g. U+0300, char-type :cjk
;;; with display width 0).  A leading run of display-width-0 objects sits at
;;; column 0 with obj-end = 0 <= start-x = 0, so clip-objects-to-display-range
;;; DROPS it (production behavior, shared by the certified `k-clip': the first
;;; cond clause skips objects entirely left of the range).  Reproducing that at
;;; the char level would mean re-implementing production's char-type run
;;; splitting and clipping, so the projection oracle instead uses only
;;; positive-width glyphs (the ZERO-WIDTH pool renders as the width-1 middle
;;; dot, not width 0).  Combining-mark WIDTH is already certified and pinned by
;;; VK-10 (verified/width.lisp k-zero-code-p, tests/pbt/width-conformance.lisp).

(defparameter *middle-dot* (code-char #xB7)
  "The glyph make-object-with-type substitutes for a :zero-width char.")

(defparameter *ascii-pool*
  (coerce (loop :for c :from 32 :to 126 :unless (= c 92) :collect c) 'vector))
(defparameter *control-pool*
  (coerce (append (loop :for c :from 1 :to 8 :collect c)
                  (list 11 12)
                  (loop :for c :from 14 :to 31 :collect c)
                  (list 127))
          'vector))
(defparameter *zero-width-pool* #(#x200B #x200C #x200D #xFE0F #xFEFF))
(defparameter *cjk-pool* #(#x4E2D #x56FD #x3042 #xAC00))
(defparameter *emoji-pool* #(#x1F600 #x1F468 #x1F308))

(defun random-mixed-char (rng)
  "One codepoint from the mixed repertoire (narrow ASCII, control, zero-width
joiner/selector shown as the middle dot, wide CJK, emoji), weighted toward
printable ASCII.  Every glyph here has display width >= 1 (see the pool note)."
  (let ((r (rng-below rng 100)))
    (code-char
     (cond ((< r 50) (rng-element rng *ascii-pool*))
           ((< r 64) (rng-element rng *control-pool*))
           ((< r 78) (rng-element rng *zero-width-pool*))
           ((< r 90) (rng-element rng *cjk-pool*))
           (t (rng-element rng *emoji-pool*))))))

(defun gen-mixed-line (&key (max-length 16))
  (make-generator
   :sample (lambda (rng)
             (with-output-to-string (out)
               (dotimes (i (rng-below rng (1+ max-length)))
                 (write-char (random-mixed-char rng) out))))
   :shrink #'lem-tests/pbt/harness::shrink-string))

(defun gen-mixed-lines (&key (max-lines 6) (max-length 16))
  (make-generator
   :sample (lambda (rng)
             (loop :repeat (rng-range rng 1 max-lines)
                   :collect (draw (gen-mixed-line :max-length max-length) rng)))
   :shrink (lambda (lines) (lem-tests/pbt/harness::shrink-list lines #'lem-tests/pbt/harness::shrink-string))))

;;; ------------------------------------------------------------------
;;; Projection oracle
;;; ------------------------------------------------------------------

(defun project-line (line)
  "Kernel-consistent glyph projection of a tab-free LINE: control chars become
their ^X / \\N replacement, :zero-width chars the middle dot, everything else
(narrow, wide, combining) itself -- exactly make-object-with-type's resolution."
  (with-output-to-string (out)
    (loop :for ch :across line
          :do (case (lem-core::char-type ch)
                (:control (write-string (lem:control-char ch) out))
                (:zero-width (write-char *middle-dot* out))
                (t (write-char ch out))))))

(defun project-tabs (line)
  "Tab expansion of a printable-ASCII LINE derived from the width kernel: a tab
advances to the next stop given by lem:char-width (k-char-width's TAB branch)."
  (with-output-to-string (out)
    (loop :with col := 0
          :for ch :across line
          :do (if (char= ch #\Tab)
                  (let ((next (lem:char-width ch col)))
                    (loop :repeat (- next col) :do (write-char #\Space out))
                    (setf col next))
                  (progn (write-char ch out)
                         (setf col (lem:char-width ch col)))))))

;;; ------------------------------------------------------------------
;;; Rendering a standalone (non-current) window
;;; ------------------------------------------------------------------

(defvar *proj-counter* 0)

(defun render-lines (lines view-width view-height line-wrap-p)
  "Insert LINES into a fresh temporary buffer, render a standalone window of the
given geometry with the caches force-cleared (ground-truth full render), and
return the recorded frame as a Y-sorted list of (Y . CELLS)."
  (let ((buffer (lem:make-buffer (format nil "vk12-proj-~D" (incf *proj-counter*))
                                 :temporary t)))
    (setf (lem:variable-value 'lem:line-wrap :buffer buffer) line-wrap-p)
    (lem:insert-string (lem:buffer-point buffer) (buffer-content->string lines))
    (let ((window (lem-core::make-window buffer 0 0 view-width view-height nil)))
      (lem-core::redraw-buffer (lem:implementation) buffer window t)
      (recording-frame-alist (lem:window-view window)))))

;;; ------------------------------------------------------------------
;;; 1. No-wrap projection: each logical line renders to one row whose text is
;;;    the line's projection.
;;; ------------------------------------------------------------------

(defparameter *projection-tests* 120
  "Random buffers per projection property.  Each is one full-frame render; four
properties * ~120 renders ~= 480 frames, and with suite 1 the two VK-12 suites
compare well over ~1k random frames total, measured a few seconds combined (CI
budget is ~2-3 min).")

(deftest projection-no-wrap
  (with-recording-interface ()
    (let ((*num-tests* *projection-tests*))
      (for-all ((raw-lines (gen-mixed-lines)))
        ;; An empty lines list is one empty buffer line (buffer-content->string
        ;; of NIL is "", which the buffer holds as a single empty line).
        (let* ((lines (or raw-lines (list "")))
               (projected (mapcar #'project-line lines))
               (max-width (reduce #'max projected
                                  :key (lambda (s) (lem:string-width s))
                                  :initial-value 1))
               ;; Wide enough that no line horizontally clips or scrolls.
               (view-width (+ 2 max-width))
               (view-height (+ 1 (length lines)))
               (rows (render-lines lines view-width view-height nil)))
          (and (= (length rows) (length lines))
               (loop :for (y . cells) :in rows
                     :for expected :in projected
                     :always (and (string= (recording-cells-text cells) expected)
                                  (= (recording-cells-width cells)
                                     (lem:string-width expected))))))))))

;;; ------------------------------------------------------------------
;;; 2. Tab projection (printable ASCII; kernel tab stops).
;;; ------------------------------------------------------------------

(defun gen-ascii-tab-line (&key (max-length 20))
  (make-generator
   :sample (lambda (rng)
             (with-output-to-string (out)
               (dotimes (i (rng-below rng (1+ max-length)))
                 (write-char (if (< (rng-below rng 100) 25)
                                 #\Tab
                                 (code-char (rng-element rng *ascii-pool*)))
                             out))))
   :shrink #'lem-tests/pbt/harness::shrink-string))

(deftest projection-tabs
  (with-recording-interface ()
    (let ((*num-tests* *projection-tests*))
      (for-all ((lines (gen-list (gen-ascii-tab-line) :min-length 1 :max-length 6)))
        (let* ((projected (mapcar #'project-tabs lines))
               (max-width (reduce #'max projected :key #'length :initial-value 1))
               (view-width (+ 2 max-width))
               (view-height (+ 1 (length lines)))
               (rows (render-lines lines view-width view-height nil)))
          (and (= (length rows) (length lines))
               (loop :for (y . cells) :in rows
                     :for expected :in projected
                     :always (string= (recording-cells-text cells) expected))))))))

;;; ------------------------------------------------------------------
;;; 3. Wrap: content preservation + the certified row-width bound, on screen.
;;;    A single logical line wraps into physical rows; concatenating their text
;;;    (markers stripped) reproduces the projection, and every row's content is
;;;    strictly narrower than the view (k-wrap-rows-all-lt, ncurses zero-opaque).
;;; ------------------------------------------------------------------

(defun gen-wrap-line (&key (max-length 40))
  ;; Same repertoire as gen-mixed-line: every codepoint has display width <= 2,
  ;; and with view-width >= 3 no single codepoint is ever at least as wide as
  ;; the view, so nothing is dropped.  Width 3 is the SEMANTIC floor for this
  ;; property, not a scan-termination workaround: at view-width <= 2 a width-2
  ;; glyph is never placed at all (the certified k-wrap-row-blocked stall) and
  ;; content preservation on screen legitimately fails -- that regime is pinned
  ;; by projection-wrap-blocked-narrow below.
  (gen-mixed-line :max-length max-length))

(defun strip-row-markers (rows wrap-char)
  "Return the per-row content texts of the physical ROWS with wrap-continuation
markers removed.  separate-objects-by-width appends the single wrap-line-char
marker to EVERY wrapped row -- i.e. every physical row except the LAST (the
final row of the logical line carries no marker).  The marker is often
destructively FUSED onto the preceding text object by the cache's in-place
reduce-objects merge, so it is stripped as a single trailing character rather
than as a whole cell.  Stripping by POSITION (all rows but the last) is required
because control replacements legitimately contain #\\ (e.g. U+001C -> \"^\\\",
the private-use range -> \"\\N\"), so a trailing #\\ is NOT reliably a marker."
  (let ((n (length rows)))
    (loop :for entry :in rows
          :for i :from 0
          :for text := (recording-cells-text (cdr entry))
          :collect (if (and (< i (1- n))          ; not the final row -> has marker
                            (plusp (length text))
                            (char= (char text (1- (length text))) wrap-char))
                       (subseq text 0 (1- (length text)))
                       text))))

(deftest projection-wrap-content-preserved
  (with-recording-interface ()
    (let ((*num-tests* *projection-tests*)
          (wrap-char (lem:variable-value 'lem:wrap-line-character
                                         :default (lem:current-buffer))))
      (for-all ((line (gen-wrap-line))
                (view-width (gen-integer :min 3 :max 12)))
        (let* ((expected (project-line line))
               ;; Tall enough that every physical row fits (no height cutoff).
               (rows (render-lines (list line) view-width 400 t))
               (contents (strip-row-markers rows wrap-char))
               (rendered (apply #'concatenate 'string contents)))
          (and (string= rendered expected)
               ;; Certified row-width bound surfaced on the real screen: each
               ;; row's CONTENT (marker excluded) is strictly narrower than the
               ;; view (k-wrap-rows-all-lt, the ncurses zero-opaque corollary).
               (every (lambda (content) (< (lem:string-width content) view-width))
                      contents)))))))

;;; ------------------------------------------------------------------
;;; 3b. Narrow views (width 1-2): the certified blocked-stall regime.
;;;     A glyph at least as wide as the view is NEVER placed (verified
;;;     k-wrap-row-blocked): rows carry one glyph each up to the first
;;;     blocking glyph, then only wrap markers until the height budget runs
;;;     out.  Reachable at all since the VK-4 fix of the map-wrapping-line
;;;     width<=2 infinite loop (this test renders where production used to
;;;     hang on the scroll/cursor-y scan).
;;; ------------------------------------------------------------------

(defun narrow-safe-char-p (ch wrap-char)
  "Exclude chars whose projection contains the wrap-marker glyph (e.g. U+001C
-> \"^\\\"), which would be indistinguishable from a stripped marker."
  (not (find wrap-char (project-line (string ch)))))

(defun blocked-prefix (projected view-width)
  "Values: the longest prefix of PROJECTED whose glyphs each fit a row of
VIEW-WIDTH columns, and whether a blocking glyph (width >= view-width, never
placed per k-wrap-row-blocked) cut the prefix short."
  (loop :for i :from 0 :below (length projected)
        :when (<= view-width (lem:char-width (char projected i) 0))
        :return (values (subseq projected 0 i) t)
        :finally (return (values projected nil))))

(deftest projection-wrap-blocked-narrow
  (with-recording-interface ()
    (let ((*num-tests* *projection-tests*)
          (wrap-char (lem:variable-value 'lem:wrap-line-character
                                         :default (lem:current-buffer)))
          (view-height 30))
      (for-all ((raw-line (gen-mixed-line :max-length 12))
                (view-width (gen-integer :min 1 :max 2)))
        (let ((line (remove-if-not (lambda (ch) (narrow-safe-char-p ch wrap-char))
                                   raw-line)))
          (multiple-value-bind (prefix blocked-p)
              (blocked-prefix (project-line line) view-width)
            ;; At these widths every placed row holds exactly ONE glyph (a
            ;; second width->=1 glyph always reaches the view width), so the
            ;; prefix length is also the number of content rows.
            (let* ((rows (render-lines (list line) view-width view-height t))
                   (texts (loop :for (y . cells) :in rows
                                :collect (remove wrap-char
                                                 (recording-cells-text cells)))))
              (and (= (length rows)
                      (if blocked-p view-height (max 1 (length prefix))))
                   (string= (apply #'concatenate 'string texts) prefix)
                   ;; Certified row bound on screen: marker-stripped content
                   ;; strictly narrower than the view (k-wrap-rows-all-lt).
                   (every (lambda (content)
                            (< (lem:string-width content) view-width))
                          texts)))))))))

;;; ------------------------------------------------------------------
;;; 4. Cursor screen-column consistency (CURRENT window, no wrap).
;;;    The cursor object's screen column equals k-string-width of the line
;;;    prefix before it.  ASCII + wide CJK only, so every prefix width is a
;;;    clean kernel fold with no tab/zero-width column subtleties.
;;; ------------------------------------------------------------------

(defun gen-cursor-line (&key (max-length 18))
  (make-generator
   :sample (lambda (rng)
             (with-output-to-string (out)
               (dotimes (i (rng-below rng (1+ max-length)))
                 (write-char (if (< (rng-below rng 100) 70)
                                 (code-char (rng-element rng *ascii-pool*))
                                 (code-char (rng-element rng *cjk-pool*)))
                             out))))
   :shrink #'lem-tests/pbt/harness::shrink-string))

(deftest projection-cursor-position
  (with-recording-interface ()
    (let ((buffer (lem:current-buffer))
          (window (lem:current-window))
          (*num-tests* *projection-tests*))
      (setf (lem:variable-value 'lem:line-wrap :buffer buffer) nil)
      (for-all ((line (gen-cursor-line))
                (raw-pos (gen-integer :min 0 :max 200)))
        (lem:erase-buffer buffer)
        (lem:insert-string (lem:buffer-point buffer) line)
        (let* ((n (length line))
               (pos (mod raw-pos (1+ n))))
          (lem:move-to-position (lem:buffer-point buffer) (1+ pos))
          (lem-core::redraw-buffer (lem:implementation) buffer window t)
          (let ((cursor (lem-fake-interface:recording-view-cursor
                         (lem:window-view window)))
                (expected-col (lem:string-width (subseq line 0 pos))))
            (and cursor
                 (= (car cursor) expected-col)
                 (= (cdr cursor) 0))))))))
