;;;; Visible target selection: Evil's Avy motions.
;;;;
;;;; Avy is distinct from evil-snipe: Snipe is a directional operator motion,
;;;; while Avy labels every candidate in one or more visible windows.  Labels
;;;; live in borderless floating windows, so source buffers, undo histories,
;;;; text properties, and modified flags are never touched.

(in-package :lem-yath)

(define-attribute lem-yath-avy-lead-attribute
  (t :foreground "#ffffff" :background "#7a6100" :bold t))

;; These are the uncustomized values in the current Emacs Avy package.  DEFVAR
;; intentionally preserves user changes across direct configuration reloads.
(defvar *avy-keys* '(#\a #\s #\d #\f #\g #\h #\j #\k #\l))
(defvar *avy-case-fold-search* t)
(defvar *avy-single-candidate-jump* t)

(defvar *avy-label-windows* nil)
(defvar *avy-label-buffers* nil)
(defvar *avy-session-active* nil)
(defvar *avy-last-visible-labels* nil)
(defvar *avy-window-size-changed* nil)

(defstruct avy-candidate
  point
  window
  screen-x
  screen-y
  target-width)

(defun avy-session-active-p ()
  *avy-session-active*)

(defun avy-note-window-size-change (&rest arguments)
  "Mark an active selector stale without unwinding Lem's resize operation."
  (declare (ignore arguments))
  (when *avy-session-active*
    (setf *avy-window-size-changed* t)))

(defun read-avy-key ()
  "Read one key, aborting if a completed resize made the labels stale."
  (let ((key (read-key)))
    (when *avy-window-size-changed*
      (error 'editor-abort))
    key))

(defun clear-avy-labels (&key redraw)
  "Delete every display-only label owned by the active Avy selection."
  (dolist (window *avy-label-windows*)
    (unless (deleted-window-p window)
      (ignore-errors (delete-window window))))
  (dolist (buffer *avy-label-buffers*)
    (ignore-errors (delete-buffer buffer)))
  (setf *avy-label-windows* nil
        *avy-label-buffers* nil)
  (when (and redraw lem-core::*in-the-editor*)
    (redraw-display :force t)))

(defun avy-current-window-only-p ()
  "Whether Evil restricts Avy to the selected window in the current state."
  (or (lem-vi-mode/visual:visual-p)
      (typep (lem-vi-mode/core:current-state)
             'lem-vi-mode/states:operator)))

(defun avy-source-windows (&key flip-scope)
  "Return Emacs-Avy-ordered text windows for this invocation."
  (let* ((frame (current-frame))
         (side-windows
           (remove nil
                   (list (lem-core::frame-leftside-window frame)
                         (lem-core::frame-rightside-window frame)
                         (lem-core::frame-bottomside-window frame))))
         (frame-windows (append (window-list frame) side-windows))
         (current-only (or (avy-current-window-only-p) flip-scope))
         (current (current-window))
         (windows (if current-only
                      (list current)
                      (cons current
                            (remove current frame-windows :test #'eq)))))
    (remove-if-not
     (lambda (window)
       (and (not (deleted-window-p window))
            (or (not (floating-window-p window))
                (side-window-p window))
            (typep (window-buffer window) 'lem-core::text-buffer)))
     windows)))

(defun avy-normalize-view-point (point)
  "Match the hidden-line normalization used by the patched Lem renderer."
  (when (lem-core::line-hidden-p point)
    (unless (lem-core::move-to-next-visible-line point)
      (lem-core::move-to-previous-visible-line point)))
  point)

(defun avy-visible-rows (window)
  "Return (Y START END) for every displayed body row in WINDOW."
  (let* ((height (lem-core::window-height-without-modeline window))
         (start (avy-normalize-view-point
                 (copy-point (window-view-point window) :temporary)))
         (rows nil))
    (loop :for y :from 0 :below height
          :do (let ((end (copy-point start :temporary)))
                (unless (move-to-next-virtual-line end 1 window)
                  (buffer-end end))
                (push (list y
                            (copy-point start :temporary)
                            (copy-point end :temporary))
                      rows)
                (when (or (point= start end)
                          (end-buffer-p start))
                  (return))
                (move-point start end)))
    (nreverse rows)))

(defun avy-horizontal-scroll (window)
  (if (variable-value 'line-wrap :default (window-buffer window))
      0
      (lem-core::horizontal-scroll-start window)))

(defun avy-display-column (point window)
  "Return POINT's displayed body column in its visible row."
  ;; Lem expands tabs against the logical line before dividing drawing objects
  ;; into physical rows.  POINT-VIRTUAL-LINE-COLUMN preserves those absolute
  ;; tab stops, unlike %CALC-WINDOW-CURSOR-X's per-row reset.
  (point-virtual-line-column point window))

(defun avy-target-cell-width (point)
  (let ((character (character-at point)))
    (if (or (null character) (char= character #\newline))
        1
        (let ((column (point-column point))
              (tab-width (variable-value 'tab-width :default point)))
          (max 1
               (- (char-width character column :tab-size tab-width)
                  column))))))

(defun avy-candidate-at (point window row &key clamp-left)
  "Make a candidate when POINT occupies a visible cell in WINDOW at ROW."
  (let* ((left (window-left-width window))
         (column (- (avy-display-column point window)
                    (avy-horizontal-scroll window)))
         (relative-x (+ left column))
         (relative-x (if clamp-left (max left relative-x) relative-x)))
    (when (<= left relative-x (1- (window-width window)))
      (make-avy-candidate
       :point (copy-point point :temporary)
       :window window
       :screen-x (+ (window-x window) relative-x)
       :screen-y (+ (window-y window) row)
       :target-width (avy-target-cell-width point)))))

(defun avy-point-visible-p (point)
  (not (lem-core::line-hidden-p point)))

(defun avy-character-equal-p (left right)
  (and (characterp left)
       (if *avy-case-fold-search*
           (char-equal left right)
           (char= left right))))

(defun avy-collect-row-matches (window row start end predicate)
  (with-point ((point start))
    (loop :with candidates := nil
          :while (point< point end)
          :do (when (and (avy-point-visible-p point)
                         (funcall predicate point))
                (alexandria:when-let
                    ((candidate (avy-candidate-at point window row)))
                  (push candidate candidates)))
              (unless (character-offset point 1)
                (return))
          :finally (return (nreverse candidates)))))

(defun avy-line-candidates (windows)
  "Collect visible logical or wrapped row starts in window/display order."
  (loop :for window :in windows
        :append
        (loop :for entry :in (avy-visible-rows window)
              :for row := (first entry)
              :for start := (second entry)
              :for candidate :=
                (unless (end-buffer-p start)
                  (avy-candidate-at start window row :clamp-left t))
              :when candidate
                :collect candidate)))

(defun avy-character-candidates (windows target)
  (loop :for window :in windows
        :append
        (loop :for (row start end) :in (avy-visible-rows window)
              :append
              (avy-collect-row-matches
               window row start end
               (lambda (point)
                 (avy-character-equal-p (character-at point) target))))))

(defun avy-ascii-punctuation-p (character)
  (let ((code (char-code character)))
    (or (<= (char-code #\!) code (char-code #\/))
        (<= (char-code #\:) code (char-code #\@))
        (<= (char-code #\[) code (char-code #\`))
        (<= (char-code #\{) code (char-code #\~)))))

(defun avy-symbol-start-p (point target)
  (let ((character (character-at point)))
    (and (avy-character-equal-p character target)
         (or (avy-ascii-punctuation-p target)
             (<= (char-code target) 26)
             (lem/buffer/internal:with-point-syntax point
               (and (syntax-symbol-char-p character)
                    (not (syntax-symbol-char-p
                          (character-at point -1)))))))))

(defun avy-symbol-candidates (windows target)
  (loop :for window :in windows
        :append
        (loop :for (row start end) :in (avy-visible-rows window)
              :append
              (avy-collect-row-matches
               window row start end
               (lambda (point)
                 (avy-symbol-start-p point target))))))

(defun avy-order-character-candidates (candidates origin)
  "Apply Avy's command-specific closest-position ordering."
  (stable-sort
   (copy-list candidates)
   #'<
   :key (lambda (candidate)
          (abs (- (position-at-point (avy-candidate-point candidate))
                  (position-at-point origin))))))

(defun avy-largest-power-not-greater-than (base number)
  (loop :with power := 1
        :while (<= (* power base) number)
        :do (setf power (* power base))
        :finally (return power)))

(defun avy-subdivisions (number base)
  "Distribute NUMBER leaves exactly like Avy's balanced BASE-way tree."
  (let* ((x2 (avy-largest-power-not-greater-than base number))
         (x1 (floor x2 base))
         (n2 (floor (- number x2) (- x2 x1)))
         (n1 (- base n2 1))
         (middle (- number (* n1 x1) (* n2 x2))))
    (append (make-list n1 :initial-element x1)
            (list middle)
            (make-list n2 :initial-element x2))))

(defun avy-take (list count)
  (loop :repeat count
        :for item :in list
        :collect item))

(defun avy-balanced-tree (candidates)
  "Return an alist whose edges are *AVY-KEYS* and leaves are candidates."
  (let ((count (length candidates))
        (base (length *avy-keys*)))
    (when (< base 2)
      (editor-error "Avy needs at least two label keys"))
    (if (< count base)
        (loop :for key :in *avy-keys*
              :for candidate :in candidates
              :collect (cons key candidate))
        (loop :with remaining := candidates
              :for key :in *avy-keys*
              :for size :in (avy-subdivisions count base)
              :for group := (avy-take remaining size)
              :do (setf remaining (nthcdr size remaining))
              :collect
              (cons key
                    (if (= size 1)
                        (first group)
                        (avy-balanced-tree group)))))))

(defun avy-tree-labels (tree &optional path)
  "Return (LABEL . CANDIDATE) pairs for the current TREE."
  (loop :for (key . child) :in tree
        :for child-path := (cons key path)
        :append
        (if (avy-candidate-p child)
            (list (cons (coerce (reverse child-path) 'string) child))
            (avy-tree-labels child child-path))))

(defun avy-label-text (label candidate available-width)
  (let* ((width (max (length label)
                     (avy-candidate-target-width candidate)))
         (text (concatenate
                'string label
                (make-string (- width (length label))
                             :initial-element #\space))))
    (subseq text 0 (min available-width (length text)))))

(defun avy-make-label-buffer (texts)
  "Return one shared label buffer and the start point for each string."
  (let ((buffer (make-buffer nil :temporary t :enable-undo-p nil)))
    (push buffer *avy-label-buffers*)
    (setf (variable-value 'line-wrap :buffer buffer) nil)
    (insert-string (buffer-point buffer)
                   (format nil "~{~A~^~%~}" texts))
    (with-point ((start (buffer-start-point buffer))
                 (end (buffer-end-point buffer)))
      (put-text-property start end :attribute
                         'lem-yath-avy-lead-attribute))
    (buffer-unmark buffer)
    (buffer-start (buffer-point buffer))
    (values
     buffer
     (with-point ((point (buffer-start-point buffer)))
       (loop :for tail :on texts
             :collect (copy-point point :temporary)
             :do (when (rest tail)
                   (line-offset point 1)))))))

(defun avy-label-spec (entry)
  "Return (TEXT CANDIDATE) clipped to the candidate's source window."
  (let* ((label (car entry))
         (candidate (cdr entry))
         (x (avy-candidate-screen-x candidate))
         (right (+ (window-x (avy-candidate-window candidate))
                   (window-width (avy-candidate-window candidate))))
         (available-width (- right x)))
    (when (plusp available-width)
      (list (avy-label-text label candidate available-width)
            candidate))))

(defun avy-display-label (text candidate buffer line-start)
  (let* ((x (avy-candidate-screen-x candidate))
         (window
           (make-instance
            'lem:floating-window
            :buffer buffer
            :x x
            :y (avy-candidate-screen-y candidate)
            :width (length text)
            :height 1
            :use-modeline-p nil
            :cursor-invisible t
            :clickable nil
            :background-color "#7a6100")))
    ;; MAKE-INSTANCE registers the floating window immediately.  Own it before
    ;; any later setup so UNWIND-PROTECT can clean up a partial construction.
    (push window *avy-label-windows*)
    ;; Each view into the shared buffer starts on its own one-line label.
    (delete-point (window-view-point window))
    (lem-core::set-window-view-point
     (copy-point line-start :right-inserting)
     window)))

(defun avy-label-screen-order (left right)
  (let ((left-candidate (cdr left))
        (right-candidate (cdr right)))
    (or (< (avy-candidate-screen-y left-candidate)
           (avy-candidate-screen-y right-candidate))
        (and (= (avy-candidate-screen-y left-candidate)
                (avy-candidate-screen-y right-candidate))
             (< (avy-candidate-screen-x left-candidate)
                (avy-candidate-screen-x right-candidate))))))

(defun avy-show-tree (tree)
  (clear-avy-labels :redraw nil)
  (let ((labels (avy-tree-labels tree)))
    (setf *avy-last-visible-labels*
          (mapcar
           (lambda (entry)
             (let ((candidate (cdr entry)))
               (list (car entry)
                     (position-at-point (avy-candidate-point candidate))
                     (buffer-name
                      (point-buffer (avy-candidate-point candidate)))
                     (avy-candidate-screen-x candidate)
                     (avy-candidate-screen-y candidate))))
           labels))
    ;; Later ncurses floating windows sit above earlier ones.  Drawing from
    ;; left to right keeps every target's first label cell observable when two
    ;; full paths overlap.
    (let* ((ordered (stable-sort (copy-list labels)
                                 #'avy-label-screen-order))
           (specs (remove nil (mapcar #'avy-label-spec ordered))))
      (when specs
        (multiple-value-bind (buffer line-starts)
            (avy-make-label-buffer (mapcar #'first specs))
          (loop :for (text candidate) :in specs
                :for line-start :in line-starts
                :do (avy-display-label text candidate buffer line-start))))))
  (redraw-display :force t))

(defun avy-abort-key-p (key)
  (or (abort-key-p key)
      (match-key key :ctrl t :sym "g")
      (match-key key :sym "Escape")))

(defun read-avy-target-character ()
  "Read the character argument for character/symbol Avy motions."
  (unwind-protect
      (progn
        (show-message "char: " :timeout nil)
        (redraw-display)
        (let ((key (read-avy-key)))
          (cond ((avy-abort-key-p key)
                 (error 'editor-abort))
                ((match-key key :sym "Return")
                 #\newline)
                ((key-to-char key))
                (t
                 (editor-error "Expected an Avy character")))))
    (clear-message)))

(defun avy-invalid-key-message (key)
  (let ((character (key-to-char key)))
    (show-message
     (format nil "No such candidate: ~A, hit Escape to quit"
             (or character key))
     :timeout nil)))

(defun read-avy-line-number (initial-digit)
  "Read an absolute line without entering Lem's nested prompt Vi state."
  (loop :with digits := (princ-to-string initial-digit)
        :do (show-message (format nil "Goto line: ~a" digits) :timeout nil)
            (redraw-display)
            (let* ((key (read-avy-key))
                   (character (key-to-char key)))
              (cond ((avy-abort-key-p key)
                     (error 'editor-abort))
                    ((match-key key :sym "Return")
                     (when (plusp (length digits))
                       (return (parse-integer digits))))
                    ((and character (digit-char-p character))
                     (setf digits
                           (concatenate 'string digits (string character))))
                    ((or (match-key key :sym "Backspace")
                         (match-key key :sym "Delete"))
                     (when (plusp (length digits))
                       (setf digits (subseq digits 0 (1- (length digits))))))))))

(defun avy-read-selection (candidates &key line-command-p)
  "Select a candidate, or return an absolute line fallback as a second value."
  (cond
    ((null candidates)
     (message "zero candidates")
     (values nil :zero))
    ((and *avy-single-candidate-jump*
          (null (rest candidates)))
     (values (first candidates) :candidate))
    (t
     (loop :with tree := (avy-balanced-tree candidates)
           :do (avy-show-tree tree)
               (let* ((key (read-avy-key))
                      (character (key-to-char key))
                      (branch (and character
                                   (assoc character tree :test #'char=))))
                 (clear-avy-labels :redraw nil)
                 (cond
                   ((avy-abort-key-p key)
                    (error 'editor-abort))
                   (branch
                    (let ((child (cdr branch)))
                      (if (avy-candidate-p child)
                          (return (values child :candidate))
                          (setf tree child))))
                   ((and line-command-p
                         character
                         (digit-char-p character))
                    (return
                      (values
                       (read-avy-line-number
                        (digit-char-p character))
                       :goto-line)))
                   (t
                    (avy-invalid-key-message key))))))))

(defun avy-jump-to-candidate (candidate)
  (let ((window (avy-candidate-window candidate)))
    (switch-to-window window)
    (move-point (current-point) (avy-candidate-point candidate))
    (window-see window)
    candidate))

(defun perform-avy-jump (kind &key flip-scope)
  "Run the configured Avy selector KIND and move to its chosen target."
  (lem/transient::hide-transient)
  (clear-avy-labels :redraw nil)
  (let ((*avy-session-active* t)
        (*avy-window-size-changed* nil)
        (*window-size-change-functions*
          (copy-list *window-size-change-functions*)))
    (add-hook *window-size-change-functions*
              'avy-note-window-size-change
              1000)
    (unwind-protect
        (let* ((windows (avy-source-windows :flip-scope flip-scope))
               (target (unless (eq kind :line)
                         (read-avy-target-character)))
               (origin (copy-point (current-point) :temporary))
               (candidates
                 (ecase kind
                   (:line (avy-line-candidates windows))
                   (:character
                    (avy-order-character-candidates
                     (avy-character-candidates windows target)
                     origin))
                   (:symbol
                    (avy-symbol-candidates windows target)))))
          (multiple-value-bind (selection result)
              (avy-read-selection candidates
                                  :line-command-p (eq kind :line))
            (ecase result
              (:candidate
               (clear-message)
               (avy-jump-to-candidate selection))
              (:goto-line
               (clear-message)
               (goto-line selection))
              (:zero nil))))
      (clear-avy-labels :redraw t))))

(lem-vi-mode:define-motion lem-yath-avy-goto-line (&optional (n 1)) (:universal)
    (:type :line :jump t :repeat nil)
  (let ((raw-prefix (universal-argument-of-this-command)))
    (if (and raw-prefix (not (member n '(1 4))))
        (goto-line n)
        (perform-avy-jump :line :flip-scope (and raw-prefix (= n 4))))))

(lem-vi-mode:define-motion lem-yath-avy-goto-char (&optional (n 1)) (:universal)
    (:type :inclusive :jump t :repeat nil)
  (perform-avy-jump :character
                    :flip-scope (and n
                                     (not (null
                                           (universal-argument-of-this-command))))))

(lem-vi-mode:define-motion lem-yath-avy-goto-symbol-1 (&optional (n 1)) (:universal)
    (:type :exclusive :jump t :repeat nil)
  (perform-avy-jump :symbol
                    :flip-scope (and n
                                     (not (null
                                           (universal-argument-of-this-command))))))

;; A direct LOAD while developing must never retain stale floating labels.
(clear-avy-labels :redraw nil)
