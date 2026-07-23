(in-package :lem-core)

;; A mode may provide a non-destructive line-visibility predicate.  Keeping
;; this at the display/movement layer lets parsers and structural commands
;; continue to address the real buffer while outline-like modes hide rows.
(define-editor-variable line-hidden-function nil)

(defun line-hidden-p (point)
  (alexandria:when-let
      ((function (variable-value 'line-hidden-function :default point)))
    (not (null (funcall function point)))))

(defun move-to-next-visible-line (point &optional (n 1))
  "Move POINT forward by N non-hidden logical lines."
  (check-type n (integer 0 *))
  (with-point ((candidate point))
    (dotimes (_ n)
      (loop
        (unless (line-offset candidate 1)
          (return-from move-to-next-visible-line nil))
        (unless (line-hidden-p candidate)
          (return))))
    (move-point point candidate)))

(defun move-to-previous-visible-line (point &optional (n 1))
  "Move POINT backward by N non-hidden logical lines."
  (check-type n (integer 0 *))
  (with-point ((candidate point))
    (dotimes (_ n)
      (loop
        (unless (line-offset candidate -1)
          (return-from move-to-previous-visible-line nil))
        (unless (line-hidden-p candidate)
          (return))))
    (move-point point candidate)))

(defun count-visible-lines (start-point end-point)
  "Return the number of visible logical-line steps between two points."
  (assert (eq (point-buffer start-point) (point-buffer end-point)))
  (with-point ((start start-point)
               (end end-point))
    (when (point< end start)
      (rotatef start end))
    (line-start start)
    (line-start end)
    (loop :with count := 0
          :until (same-line-p start end)
          :do (unless (line-offset start 1)
                (return count))
              (unless (line-hidden-p start)
                (incf count))
          :finally (return count))))

(defun window-recenter (window &key line from-bottom)
  "Recenter WINDOW to the given LINE number.
LINE must be NIL or a positive number.
If LINE is NIL, recenter to the middle of the WINDOW.
Otherwise, recenter to the nth LINE (starting at 0), counted from the top.
If FROM-BOTTOM is T, start counting from the bottom."
  (check-type line (or null integer))
  (check-type from-bottom boolean)
  (setq line (cond ((null line)
                    (floor (window-height-without-modeline window) 2))
                   (from-bottom
                    (- (window-height-without-modeline window) line 1))
                   (t line)))
  (unless (= line (window-cursor-y window))
    (line-start
     (move-point (window-view-point window)
                 (window-buffer-point window)))
    (let ((n (- (window-cursor-y window) line)))
      (window-scroll window n)
      n)))

(defun window-recenter-top-bottom (window)
  "In first call recenter WINDOW to the middle line.
If cursor is already in the middle of WINDOW then move cursor in the top position.
If cursor is on top then move move WINDOW to the bottom."
  (let* ((line (window-cursor-y window))
         (window-height (window-height-without-modeline window))
         (middle (floor window-height 2))
         (scrolloff (min (floor (/ (window-height window) 2)) 0))
         (top 0))
    (cond
      ((= line middle) (window-recenter window :line scrolloff :from-bottom nil))
      ((= line top) (window-recenter window :line scrolloff :from-bottom t))
      (t (window-recenter window :line nil :from-bottom nil)))))

(declaim (inline line-wrap-whitespace-p))
(defun line-wrap-whitespace-p (character)
  (or (char= character #\Space)
      (char= character #\Tab)))

(defun wrapping-line-break-index (string width
                                  &key
                                    (start 0)
                                    (tab-size +default-tab-size+)
                                    word-boundary-p)
  "Return the next display-row boundary in STRING after START.
When WORD-BOUNDARY-P is true, prefer the end of the last complete space or
tab run that fits.  A word wider than WIDTH still uses the exact display-width
boundary.  The second value is true only when a word boundary was selected."
  (let ((hard-boundary
          (wide-index string width :start start :tab-size tab-size)))
    (unless (and hard-boundary word-boundary-p)
      (return-from wrapping-line-break-index hard-boundary))
    (let ((seen-content-p nil)
          (in-whitespace-p nil)
          (word-boundary nil))
      (loop :for index :from start :below hard-boundary
            :for character := (schar string index)
            :do (cond ((line-wrap-whitespace-p character)
                       (when seen-content-p
                         (setf in-whitespace-p t)))
                      (t
                       (when in-whitespace-p
                         (setf word-boundary index
                               in-whitespace-p nil))
                       (setf seen-content-p t))))
      (when in-whitespace-p
        (setf word-boundary hard-boundary))
      (if word-boundary
          (values word-boundary t)
          hard-boundary))))

(defun wrapping-line-start-index (window string charpos)
  (let ((tab-size (variable-value 'tab-width :default (window-buffer window)))
        (word-boundary-p
          (variable-value 'line-wrap-at-word-boundary
                          :default (window-buffer window)))
        (width (1- (window-body-width window))))
    (loop :with start := 0
          :for next := (wrapping-line-break-index
                        string width
                        :start start
                        :tab-size tab-size
                        :word-boundary-p word-boundary-p)
          :while (and next (<= next charpos))
          :do (setf start next)
          :finally (return start))))

(defun %calc-window-cursor-x (point window)
  "Return (values cur-x next). the 'next' is a flag if the cursor goes to
next line because it is at the end of width."
  (unless (variable-value 'line-wrap :default (window-buffer window))
    (return-from %calc-window-cursor-x (values (point-column point) nil)))
  (let* ((tab-size (variable-value 'tab-width :default (window-buffer window)))
         (charpos (point-charpos point))
         (line    (line-string point))
         (width   (1- (window-body-width window)))
         (start   (wrapping-line-start-index window line charpos))
         (cur-x   (string-width line
                                :start start
                                :end charpos
                                :tab-size tab-size))
         (next-x  (if (< charpos (length line))
                      (char-width (schar line charpos)
                                  cur-x
                                  :tab-size tab-size)
                      (1+ cur-x))))
    (if (< width next-x)
        (values 0     t)
        (values cur-x nil))))

(defun window-cursor-x (window)
  (multiple-value-bind (x next)
      (%calc-window-cursor-x (window-buffer-point window) window)
    (declare (ignore next))
    x))

(defun cursor-goto-next-line-p (point window)
  "Check if the cursor goes to next line because it is at the end of width."
  (multiple-value-bind (x next)
      (%calc-window-cursor-x point window)
    (declare (ignore x))
    next))

(defun map-wrapping-line (window string fn)
  (let ((tab-size (variable-value 'tab-width :default (window-buffer window)))
        (word-boundary-p
          (variable-value 'line-wrap-at-word-boundary
                          :default (window-buffer window))))
    (loop :with start := 0
          :and width := (1- (window-body-width window))
          :for i := (wrapping-line-break-index
                     string width
                     :start start
                     :tab-size tab-size
                     :word-boundary-p word-boundary-p)
          :while i
          :do ;; A glyph at START alone can exceed the width goal (goal <= 1
              ;; with a width-2 glyph), making wide-index return its own start
              ;; index; advancing by at least one char keeps the scan
              ;; terminating (pre-VK-4 this looped forever). NOTE: in this
              ;; blocked regime (body-width 1-2) the scan and the renderer
              ;; deliberately diverge: the scan advances one char per row so
              ;; wrapping-offset/cursor-y stay finite, while the certified
              ;; k-wrap (k-wrap-row-blocked) never places the oversized glyph
              ;; and emits marker-only rows to the height budget. Row counts
              ;; disagree only in 1-2-column windows -- unreachable on real
              ;; terminals; the render side is pinned by
              ;; projection-wrap-blocked-narrow.
              (when (<= i start)
                (setq i (1+ start))
                (when (<= (length string) i)
                  (return)))
              (funcall fn i)
              (setq start i))))

(defun window-wrapping-offset (window start-point end-point)
  (unless (variable-value 'line-wrap :default (window-buffer window))
    (return-from window-wrapping-offset 0))
  (let ((offset 0))
    (labels ((inc (arg)
               (declare (ignore arg))
               (incf offset)))
      (with-point ((line start-point))
        (line-start line)
        (map-region start-point
                  end-point
                  (lambda (string lastp)
                    (declare (ignore lastp))
                    (unless (line-hidden-p line)
                      (map-wrapping-line window string #'inc))
                    (line-offset line 1))))
      offset)))

(defun window-cursor-y-not-wrapping (window)
  (count-visible-lines (window-buffer-point window)
                       (window-view-point window)))

(defun window-cursor-y (window)
  (if (point< (window-buffer-point window)
              (window-view-point window))
      ;; return minus number
      (- (+ (window-cursor-y-not-wrapping window)
            (window-wrapping-offset window
                                    (backward-line-wrap
                                     (copy-point (window-buffer-point window)
                                                 :temporary)
                                     window t)
                                    (window-view-point window))
            (if (cursor-goto-next-line-p (window-view-point window) window)
                1 0)))
      ;; return zero or plus number
      (+ (window-cursor-y-not-wrapping window)
         (window-wrapping-offset window
                                 (window-view-point window)
                                 (window-buffer-point window))
         (if (and (point< (window-view-point window)
                          (window-buffer-point window))
                  (cursor-goto-next-line-p (window-buffer-point window) window))
             1 0))))

(defun forward-line-wrap (point window)
  (assert (eq (point-buffer point) (window-buffer window)))
  (when (variable-value 'line-wrap :default (point-buffer point))
    (map-wrapping-line window
                       (line-string point)
                       (lambda (i)
                         (when (< (point-charpos point) i)
                           (line-offset point 0 i)
                           (return-from forward-line-wrap point))))))

(defun backward-line-wrap-1 (point window contain-same-line-p)
  (if (and contain-same-line-p (start-line-p point))
      point
      (let (previous-charpos)
        (map-wrapping-line window
                           (line-string point)
                           (lambda (i)
                             (cond ((and contain-same-line-p (= i (point-charpos point)))
                                    (line-offset point 0 i)
                                    (return-from backward-line-wrap-1 point))
                                   ((< i (point-charpos point))
                                    (setf previous-charpos i))
                                   (previous-charpos
                                    (line-offset point 0 previous-charpos)
                                    (return-from backward-line-wrap-1 point))
                                   ((or contain-same-line-p (= i (point-charpos point)))
                                    (line-start point)
                                    (return-from backward-line-wrap-1 point)))))
        (cond (previous-charpos
               (line-offset point 0 previous-charpos))
              (contain-same-line-p
               (line-start point))))))

(defun backward-line-wrap (point window contain-same-line-p)
  (assert (eq (point-buffer point) (window-buffer window)))
  (cond ((variable-value 'line-wrap :default (point-buffer point))
         (backward-line-wrap-1 point window contain-same-line-p))
        (contain-same-line-p
         (line-start point))))

(defun move-to-next-virtual-line-1 (point window)
  (assert (eq (point-buffer point) (window-buffer window)))
  (or (forward-line-wrap point window)
      (move-to-next-visible-line point)))

(defun move-to-previous-virtual-line-1 (point window)
  (assert (eq (point-buffer point) (window-buffer window)))
  (backward-line-wrap point window t)
  (or (backward-line-wrap point window nil)
      (progn
        (and (move-to-previous-visible-line point)
             (line-end point)
             (backward-line-wrap point window t)))))

(defun move-to-next-virtual-line-n (point window n)
  (assert (eq (point-buffer point) (window-buffer window)))
  (when (<= n 0)
    (return-from move-to-next-virtual-line-n point))
  (unless (variable-value 'line-wrap :default (point-buffer point))
    (return-from move-to-next-virtual-line-n
      (move-to-next-visible-line point n)))
  (loop :with n1 := n
        :do (map-wrapping-line
             window
             (line-string point)
             (lambda (i)
               (when (< (point-charpos point) i)
                 (decf n1)
                 (when (<= n1 0)
                   ;; cursor-x offset is recovered by cursor-saved-column
                   (line-offset point 0 i)
                   (return-from move-to-next-virtual-line-n point)))))
            ;; go to next line
            (unless (move-to-next-visible-line point)
              (return-from move-to-next-virtual-line-n nil))
            (decf n1)
            (when (<= n1 0)
              (return-from move-to-next-virtual-line-n point))))

(defun move-to-previous-virtual-line-n (point window n)
  (assert (eq (point-buffer point) (window-buffer window)))
  (when (<= n 0)
    (return-from move-to-previous-virtual-line-n point))
  (unless (variable-value 'line-wrap :default (point-buffer point))
    (return-from move-to-previous-virtual-line-n
      (move-to-previous-visible-line point n)))
  (let ((pos-ring  (make-array (1+ n))) ; ring buffer of wrapping position
        (pos-size  (1+ n))
        (pos-count 0)
        (pos-next  0)
        (pos-last  0))
    (flet ((pos-ring-push (pos)
             (setf (aref pos-ring pos-next) pos)
             (incf pos-next)
             (when (>= pos-next pos-size) (setf pos-next 0))
             (incf pos-count)
             (when (> pos-count pos-size)
               (setf pos-count pos-size)
               (incf pos-last)
               (when (>= pos-last pos-size) (setf pos-last 0)))))
      (loop :with n1 := n
            :with first-line := t
            :do (block outer
                  (pos-ring-push 0)
                  (map-wrapping-line
                   window
                   (line-string point)
                   (lambda (i)
                     (when (and first-line
                                (< (point-charpos point) i))
                       (return-from outer))
                     (pos-ring-push i))))
                (when (>= pos-count (1+ n1))
                  ;; cursor-x offset is recovered by cursor-saved-column
                  (line-offset point 0 (aref pos-ring pos-last))
                  (return-from move-to-previous-virtual-line-n point))
                ;; go to previous line
                (unless (move-to-previous-visible-line point)
                  (return-from move-to-previous-virtual-line-n nil))
                (setf first-line nil)
                (decf n1 pos-count)
                (setf pos-size  (1+ n1)) ; shrink ring-buffer
                (setf pos-count 0)
                (setf pos-next  0)
                (setf pos-last  0)))))

(defun move-to-next-virtual-line (point &optional n (window (current-window)))
  (unless n (setf n 1))
  (unless (zerop n)

    ;; workaround for cursor movement problem
    (when (and *use-cursor-movement-workaround*
               (eq point (window-buffer-point window))
               (variable-value 'line-wrap :default (point-buffer point))
               (numberp (cursor-saved-column point))
               (>= (cursor-saved-column point) (- (window-body-width window) 3)))
      (setf (cursor-saved-column point) 0))

    (if *use-new-vertical-move-function*
        (if (plusp n)
            (move-to-next-virtual-line-n point window n)
            (move-to-previous-virtual-line-n point window (- n)))
        (multiple-value-bind (n f)
            (if (plusp n)
                (values n #'move-to-next-virtual-line-1)
                (values (- n) #'move-to-previous-virtual-line-1))
          (loop :repeat n
                :do (unless (funcall f point window)
                      (return-from move-to-next-virtual-line nil)))
          point))))

(defun move-to-previous-virtual-line (point &optional n (window (current-window)))
  (move-to-next-virtual-line point (if n (- n) -1) window))

(defun point-virtual-line-column (point &optional (window (current-window)))
  (if (variable-value 'line-wrap :default (point-buffer point))
      (let ((column (point-column point)))
        (with-point ((start point))
          (backward-line-wrap start window t)
          (- column (point-column start))))
      (point-column point)))

(defun move-to-virtual-line-column (point column &optional (window (current-window)))
  (backward-line-wrap point window t)
  (let* ((line (line-string point))
         (start (point-charpos point))
         (tab-size
           (variable-value 'tab-width :default (point-buffer point)))
         (index (wide-index
                 line
                 column
                 :start start
                 :tab-size tab-size))
         (remaining-width
           (string-width line
                         :start start
                         :tab-size tab-size)))
    (line-offset point 0 (or index (length line)))
    ;; Preserve the old success contract for mouse hit testing: reaching the
    ;; exact EOL succeeds, but a column beyond the text returns NIL.
    (and (<= column remaining-width) point)))

(defun window-scroll-down (window)
  (move-to-next-virtual-line (window-view-point window) 1 window))

(defun window-scroll-up (window)
  (move-to-previous-virtual-line (window-view-point window) 1 window))

(defun window-scroll-down-n (window n)
  (move-to-next-virtual-line (window-view-point window) n window))

(defun window-scroll-up-n (window n)
  (move-to-previous-virtual-line (window-view-point window) n window))

(defun window-scroll (window n)
  (need-to-redraw window)
  (prog1 (if *use-new-vertical-move-function*
             (if (plusp n)
                 (window-scroll-down-n window n)
                 (window-scroll-up-n window (- n)))
             (dotimes (_ (abs n))
               (if (plusp n)
                   (window-scroll-down window)
                   (window-scroll-up window))))
    (run-hooks *window-scroll-functions* window)))
