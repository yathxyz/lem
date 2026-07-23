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

;; Keep this in the same order as the pinned Avy 20241101.1357 default.
(defvar *avy-dispatch-alist*
  '((#\x . :kill-move)
    (#\X . :kill-stay)
    (#\t . :teleport)
    (#\m . :mark)
    (#\n . :copy)
    (#\y . :yank)
    (#\Y . :yank-line)
    (#\i . :ispell)
    (#\z . :zap-to-char)))

(defvar *avy-action* :goto)

(defparameter *avy-spell-dictionary* "en_US")
(defparameter *avy-spell-timeout-seconds* 2)
(defparameter *avy-spell-word-limit* 256)
(defparameter *avy-spell-output-limit* (* 64 1024))
(defparameter *avy-spell-suggestion-limit* 64)

;; Emacs keeps `a' decisions in the live Ispell session and sends `i'
;; decisions to Aspell's personal dictionary.  Lem deliberately runs bounded
;; one-shot Aspell processes, so retain the former explicitly between calls.
(defvar *avy-spell-session-words* (make-hash-table :test #'equal))
(defvar *avy-spell-prompt-decision* nil)
(defvar *avy-spell-prompt-suggestions* nil)

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

(defun avy-action-name (action)
  (ecase action
    (:kill-move "kill-move")
    (:kill-stay "kill-stay")
    (:teleport "teleport")
    (:mark "mark")
    (:copy "copy")
    (:yank "yank")
    (:yank-line "yank-line")
    (:ispell "ispell")
    (:zap-to-char "zap-to-char")))

(defun avy-show-dispatch-help ()
  (show-message
   (format nil "~{~c: ~a~^ ~}"
           (loop :for (key . action) :in *avy-dispatch-alist*
                 :append (list key (avy-action-name action))))
   :timeout nil))

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
     (loop :with root-tree := (avy-balanced-tree candidates)
           :with tree := root-tree
           :with pending-key := nil
           :do (unless pending-key
                 (avy-show-tree tree))
               (let* ((key (if pending-key
                               (prog1 pending-key
                                 (setf pending-key nil)
                                 (clear-message))
                               (read-avy-key)))
                      (character (key-to-char key))
                      (branch (and character
                                   (assoc character tree :test #'char=)))
                      (dispatch (and character
                                     (assoc character *avy-dispatch-alist*
                                            :test #'char=))))
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
                   (dispatch
                    (setf *avy-action* (cdr dispatch)
                          tree root-tree))
                   ((and character (char= character #\?))
                    (avy-show-dispatch-help)
                    (redraw-display)
                    (setf tree root-tree
                          pending-key (read-avy-key)))
                   (t
                    (avy-invalid-key-message key))))))))

(defun avy-jump-to-candidate (candidate)
  (let ((window (avy-candidate-window candidate)))
    (switch-to-window window)
    (move-point (current-point) (avy-candidate-point candidate))
    (window-see window)
    candidate))

(defun avy-item-end (candidate kind)
  "Return the exclusive end of Avy's item at CANDIDATE for KIND."
  (with-point ((end (avy-candidate-point candidate)))
    (if (eq kind :line)
        (line-end end)
        (or (form-offset end 1)
            (editor-error "No expression at the selected Avy target")))
    (copy-point end :temporary)))

(defun avy-item-text (candidate kind)
  (points-to-string (avy-candidate-point candidate)
                    (avy-item-end candidate kind)))

(defun avy-return-to-origin (window point)
  (switch-to-window window)
  (move-point (current-point) point)
  (window-see window))

(defun avy-kill-item (candidate kind &key stay)
  (let* ((start (avy-candidate-point candidate))
         (end (avy-item-end candidate kind))
         (text (points-to-string start end)))
    (avy-jump-to-candidate candidate)
    (kill-region (current-point) end)
    (when stay
      (just-one-space))
    (message "Killed: ~a" text)
    text))

(defun avy-spell-program (environment-variable executable)
  "Resolve a packaged spell helper before consulting the mutable PATH."
  (or (alexandria:when-let ((configured (uiop:getenv environment-variable)))
        (unless (zerop (length configured))
          (uiop:probe-file* configured)))
      (executable-find executable)))

(defun avy-spell-command ()
  (let ((aspell (avy-spell-program "LEM_YATH_ASPELL_PROGRAM" "aspell"))
        (timeout (avy-spell-program "LEM_YATH_TIMEOUT_PROGRAM" "timeout")))
    (unless aspell
      (editor-error "Avy spell correction needs Aspell"))
    (unless timeout
      (editor-error "Avy spell correction needs GNU timeout"))
    (list (uiop:native-namestring timeout)
          "--signal=TERM"
          "--kill-after=1"
          (princ-to-string *avy-spell-timeout-seconds*)
          (uiop:native-namestring aspell)
          "-a"
          "-d"
          *avy-spell-dictionary*
          "--encoding=utf-8")))

(defun avy-spell-valid-word-p (word)
  (and (plusp (length word))
       (<= (length word) *avy-spell-word-limit*)
       (every (lambda (character)
                (and (graphic-char-p character)
                     (not (find character '(#\Newline #\Return)))))
              word)))

(defun avy-spell-parse-suggestions (line)
  (alexandria:when-let ((colon (position #\: line)))
    (let ((suggestions
            (remove-if
             (lambda (suggestion) (zerop (length suggestion)))
             (mapcar
              (lambda (suggestion)
                (string-trim '(#\Space #\Tab) suggestion))
              (uiop:split-string
               (subseq line (1+ colon)) :separator '(#\,))))))
      (subseq (remove-duplicates suggestions :test #'equal)
              0 (min (length suggestions)
                     *avy-spell-suggestion-limit*)))))

(defun avy-spell-suggestions (word)
  "Return Aspell status and bounded suggestions for WORD."
  (unless (avy-spell-valid-word-p word)
    (editor-error "Aspell word is empty, non-printing, or too long"))
  (when (gethash word *avy-spell-session-words*)
    (return-from avy-spell-suggestions (values :correct nil)))
  (multiple-value-bind (stdout stderr status)
      (with-input-from-string (input (format nil "^~a~%" word))
        (uiop:run-program
         (avy-spell-command)
         :input input
         :output :string
         :error-output :string
         :ignore-error-status t))
    (unless (zerop status)
      (editor-error "Aspell exited ~d~@[ — ~a~]"
                    status
                    (let ((summary
                            (string-trim
                             '(#\Space #\Tab #\Newline #\Return)
                             (or stderr ""))))
                      (unless (zerop (length summary))
                        (subseq summary 0 (min 200 (length summary)))))))
    (when (> (length stdout) *avy-spell-output-limit*)
      (editor-error "Aspell produced more than ~d characters"
                    *avy-spell-output-limit*))
    (let ((result
            (find-if
             (lambda (line)
               (and (plusp (length line))
                    (find (char line 0) "*+-&?#" :test #'char=)))
             (uiop:split-string stdout :separator '(#\Newline)))))
      (unless result
        (editor-error "Aspell returned no result for ~s" word))
      (case (char result 0)
        ((#\* #\+ #\-)
         (values :correct nil))
        ((#\& #\?)
         (values :misspelled (avy-spell-parse-suggestions result)))
        (#\#
         (values :misspelled nil))
        (otherwise
         (editor-error "Unsupported Aspell response: ~s" result))))))

(defun avy-spell-save-personal-word (word)
  "Insert WORD into Aspell's configured personal dictionary and save it."
  (unless (and (avy-spell-valid-word-p word)
               (every #'alpha-char-p word))
    (editor-error "A personal spelling must contain only letters"))
  (multiple-value-bind (stdout stderr status)
      (with-input-from-string (input (format nil "*~a~%#~%" word))
        (uiop:run-program
         (avy-spell-command)
         :input input
         :output :string
         :error-output :string
         :ignore-error-status t))
    (unless (zerop status)
      (editor-error "Aspell could not save the personal dictionary~@[ — ~a~]"
                    (let ((summary
                            (string-trim
                             '(#\Space #\Tab #\Newline #\Return)
                             (or stderr ""))))
                      (unless (zerop (length summary))
                        (subseq summary 0 (min 200 (length summary)))))))
    (when (> (length stdout) *avy-spell-output-limit*)
      (editor-error "Aspell produced more than ~d characters"
                    *avy-spell-output-limit*)))
  ;; Avoid another subprocess in this Lem session after a successful save.
  (setf (gethash word *avy-spell-session-words*) t)
  t)

(defun avy-spell-letter-p (character)
  (and (characterp character) (alpha-char-p character)))

(defun avy-spell-word-range (point)
  "Return the alphabetic word at or preceding POINT."
  (with-point ((cursor point))
    (unless (avy-spell-letter-p (character-at cursor))
      (loop :while (and (not (start-buffer-p cursor))
                        (not (avy-spell-letter-p (character-at cursor -1))))
            :do (character-offset cursor -1))
      (when (avy-spell-letter-p (character-at cursor -1))
        (character-offset cursor -1)))
    (when (avy-spell-letter-p (character-at cursor))
      (with-point ((start cursor)
                   (end cursor))
        (loop :while (avy-spell-letter-p (character-at start -1))
              :do (character-offset start -1))
        (loop :while (avy-spell-letter-p (character-at end))
              :do (character-offset end 1))
        (values (copy-point start :temporary)
                (copy-point end :temporary))))))

(defun avy-spell-preflight-range (start end)
  (unless lem/buffer/internal:*inhibit-read-only*
    (lem/buffer/internal::check-read-only-buffer (point-buffer start))
    (lem/buffer/internal::check-read-only-at-point
     start (count-characters start end))
    (lem/buffer/internal::check-read-only-at-point start 0)
    (lem/buffer/internal::check-read-only-at-point end 0)))

(defun call-with-avy-spell-prompt-state (function)
  "Call FUNCTION without leaking Lem's temporary Vi prompt state."
  (let ((buffer (current-buffer))
        (state (ignore-errors (lem-vi-mode/core:current-state))))
    (unwind-protect
         (funcall function)
      (when (and state (not (deleted-buffer-p buffer)))
        (setf (lem-vi-mode/core:buffer-state buffer) state)
        (when (eq buffer (current-buffer))
          (setf (lem-vi-mode/core:current-state) state))))))

(defun avy-spell-finish-prompt (decision)
  "Finish the active correction prompt with DECISION."
  (setf *avy-spell-prompt-decision* decision)
  (lem/prompt-window::prompt-execute))

(define-command avy-spell-prompt-keep () ()
  (avy-spell-finish-prompt :keep))

(define-command avy-spell-prompt-accept-session () ()
  (avy-spell-finish-prompt :session))

(define-command avy-spell-prompt-add-personal () ()
  (avy-spell-finish-prompt :personal))

(define-command avy-spell-prompt-manual-replacement () ()
  (avy-spell-finish-prompt :manual))

(define-command avy-spell-prompt-numbered-suggestion () ()
  (let* ((name (lem-core::keyseq-to-string (last-read-key-sequence)))
         (index (and (= 1 (length name))
                     (digit-char-p (char name 0)))))
    (alexandria:if-let ((suggestion
                         (and index
                              (nth index *avy-spell-prompt-suggestions*))))
      (avy-spell-finish-prompt suggestion)
      (message "No spelling suggestion is assigned to ~a" name))))

(defparameter *avy-spell-prompt-keymap*
  (let ((keymap (make-keymap :description "Ispell correction prompt")))
    (define-key keymap "Space" 'avy-spell-prompt-keep)
    (define-key keymap "a" 'avy-spell-prompt-accept-session)
    (define-key keymap "i" 'avy-spell-prompt-add-personal)
    (define-key keymap "r" 'avy-spell-prompt-manual-replacement)
    (dotimes (index 10)
      (define-key keymap (princ-to-string index)
        'avy-spell-prompt-numbered-suggestion))
    keymap))

(defun avy-spell-prompt-replacement (word suggestions)
  "Read an Emacs-Ispell decision for WORD and return action and replacement."
  (let ((*avy-spell-prompt-decision* nil)
        (*avy-spell-prompt-suggestions* suggestions))
    (let ((input
            (call-with-avy-spell-prompt-state
             (lambda ()
               (let ((choices
                       (cons word (remove word suggestions :test #'equal))))
                 (prompt-for-string
                  (format nil
                          "Correct ~a [SPC once; a session; i personal; r edit]: "
                          word)
                  :completion-function
                  (lambda (query)
                    (let ((matches
                            (prescient-filter query choices :rank-p nil)))
                      ;; Preserve Aspell's order for partial queries, but do
                      ;; not let the no-change choice shadow an exact answer.
                      (alexandria:if-let ((exact
                                            (find query matches
                                                  :test #'string=)))
                        (cons exact (remove exact matches :test #'eq))
                        matches)))
                  :special-keymap *avy-spell-prompt-keymap*))))))
      (cond
        ((stringp *avy-spell-prompt-decision*)
         (values :replace *avy-spell-prompt-decision*))
        ((eq *avy-spell-prompt-decision* :manual)
         (let ((replacement
                 (call-with-avy-spell-prompt-state
                  (lambda ()
                    (prompt-for-string
                     (format nil "Replacement for ~a: " word))))))
           (unless (avy-spell-valid-word-p replacement)
             (editor-error
              "Spell replacement is empty, non-printing, or too long"))
           (values :replace replacement)))
        (*avy-spell-prompt-decision*
         (values *avy-spell-prompt-decision* nil))
        (t
         (unless (avy-spell-valid-word-p input)
           (editor-error
            "Spell replacement is empty, non-printing, or too long"))
         (values (if (equal input word) :keep :replace) input))))))

(defun avy-spell-correct-one (start end)
  "Offer a correction for START..END; return replacement and decision."
  (let ((word (points-to-string start end)))
    (multiple-value-bind (status suggestions)
        (avy-spell-suggestions word)
      (ecase status
        (:correct (values nil :correct))
        (:misspelled
         (multiple-value-bind (decision replacement)
             (avy-spell-prompt-replacement word suggestions)
           (ecase decision
             (:keep (values nil :keep))
             (:session
              (setf (gethash word *avy-spell-session-words*) t)
              (values nil :session))
             (:personal
              (avy-spell-save-personal-word word)
              (values nil :personal))
             (:replace
              (if (equal replacement word)
                  (values nil :keep)
                  (progn
                    (avy-spell-preflight-range start end)
                    (delete-between-points start end)
                    (insert-string start replacement)
                    (values replacement :replace)))))))))))

(defun avy-spell-correct-word (point)
  (multiple-value-bind (start end) (avy-spell-word-range point)
    (unless start
      (editor-error "No word at the selected Avy target"))
    (let ((word (points-to-string start end)))
      (multiple-value-bind (replacement decision)
          (avy-spell-correct-one start end)
        (declare (ignore replacement))
        (ecase decision
          (:replace (message "Corrected spelling at Avy target"))
          (:session (message "Accepted spelling for this session: ~a" word))
          (:personal (message "Added spelling to personal dictionary: ~a" word))
          ((:correct :keep) (message "Kept spelling: ~a" word)))))))

(defun avy-spell-correct-line (candidate)
  "Offer corrections for every misspelled word on CANDIDATE's line."
  (with-point ((cursor (avy-candidate-point candidate) :right-inserting)
               (limit (avy-candidate-point candidate) :right-inserting))
    (line-start cursor)
    (line-end limit)
    (loop :with corrections := 0
          :while (point< cursor limit)
          :do (loop :while (and (point< cursor limit)
                                (not (avy-spell-letter-p
                                      (character-at cursor))))
                    :do (character-offset cursor 1))
              (when (point< cursor limit)
                (with-point ((start cursor)
                             (end cursor :right-inserting))
                  (loop :while (and (point< end limit)
                                    (avy-spell-letter-p
                                     (character-at end)))
                        :do (character-offset end 1))
                  (let ((replacement (avy-spell-correct-one start end)))
                    (move-point cursor start)
                    (character-offset
                     cursor
                     (length (or replacement
                                 (points-to-string start end))))
                    (when replacement (incf corrections)))))
          :finally
             (message "Avy corrected ~d word~:p on the selected line"
                      corrections))))

(defun perform-avy-action (action candidate kind origin-window origin-point)
  "Apply ACTION to CANDIDATE, preserving Avy's origin semantics."
  (ecase action
    (:goto
     (avy-jump-to-candidate candidate))
    (:mark
     (avy-jump-to-candidate candidate)
     (set-cursor-mark (current-point) (current-point))
     (move-point (current-point) (avy-item-end candidate kind)))
    (:copy
     (let ((text (avy-item-text candidate kind)))
       (copy-to-clipboard-with-killring text)
       (avy-return-to-origin origin-window origin-point)
       (message "Copied: ~a" text)))
    (:yank
     (let ((text (avy-item-text candidate kind)))
       (copy-to-clipboard-with-killring text)
       (avy-return-to-origin origin-window origin-point)
       (lem-core/commands/edit::yank-string (current-point) text)))
    (:yank-line
     (let ((text (avy-item-text candidate :line)))
       (copy-to-clipboard-with-killring text)
       (avy-return-to-origin origin-window origin-point)
       (lem-core/commands/edit::yank-string (current-point) text)))
    (:kill-move
     (avy-kill-item candidate kind))
    (:kill-stay
     (avy-kill-item candidate kind :stay t)
     (avy-return-to-origin origin-window origin-point))
    (:teleport
     (let ((text (avy-kill-item candidate kind :stay t)))
       (avy-return-to-origin origin-window origin-point)
       (save-excursion
         (lem-core/commands/edit::yank-string (current-point) text))))
    (:zap-to-char
     (unless (eq (point-buffer origin-point)
                 (point-buffer (avy-candidate-point candidate)))
       (editor-error "Avy zap target must be in the current buffer"))
     (avy-jump-to-candidate candidate)
     (kill-region origin-point (current-point)))
    (:ispell
     (if (eq kind :line)
         (avy-spell-correct-line candidate)
         (avy-spell-correct-word (avy-candidate-point candidate))))))

(defun perform-avy-jump (kind &key flip-scope)
  "Run the configured Avy selector KIND and move to its chosen target."
  (lem/transient::hide-transient)
  (clear-avy-labels :redraw nil)
  (let ((*avy-session-active* t)
        (*avy-action* :goto)
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
               (origin-window (current-window))
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
               (perform-avy-action *avy-action* selection kind
                                   origin-window origin))
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
