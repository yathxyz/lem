;;;; Corfu/Cape-style automatic completion for ordinary buffers.
;;;;
;;;; The live Emacs configuration opens Corfu after a three-character prefix
;;;; and 0.2 seconds, displays at most ten rows, and does not cycle at the
;;;; boundaries.  Mode-local Lem completion remains authoritative.  When no
;;;; such provider exists, same-major-mode dabbrev and file-at-point sources
;;;; mirror the configured Cape fallback order.

(in-package :lem-yath)

;; A direct configuration reload must not leave a preview window or a live
;; completion transaction owned by the previous definitions.
(when (and (boundp '*auto-completion-session*)
           (symbol-value '*auto-completion-session*))
  (let ((session (symbol-value '*auto-completion-session*)))
    (if (and (fboundp 'auto-completion-session-context)
             (eq (funcall (symbol-function 'auto-completion-session-context)
                          session)
                 lem/completion-mode::*completion-context*))
        (ignore-errors (lem/completion-mode:completion-end))
        (when (fboundp 'auto-completion-teardown-session)
          (ignore-errors (auto-completion-teardown-session session))))))
(when (fboundp 'auto-completion-cancel-timer)
  (ignore-errors (auto-completion-cancel-timer)))
(when (fboundp 'auto-completion-close-info)
  (ignore-errors (auto-completion-close-info)))

(defparameter *auto-completion-prefix-length* 3)
(defparameter *auto-completion-delay-ms* 200)
(defparameter *auto-completion-max-display-items* 10)

(defvar *auto-completion-timer* nil)
(defvar *auto-completion-generation* 0)
(defvar *auto-completion-context* nil)
(defvar *auto-completion-info-window* nil)
(defvar *auto-completion-info-buffer* nil)
(defvar *auto-completion-info-buffer-owned-p* nil)
(defvar *auto-completion-file-locations* (make-hash-table :test #'eq))

(defstruct auto-completion-session
  context
  buffer
  window
  change-group
  preselect-item
  selected-item
  preview-window
  preview-buffer
  cleaning-p)

(defvar *auto-completion-session* nil)

(defparameter *auto-completion-continue-commands*
  '(lem-core/commands/edit:delete-previous-char
    lem/completion-mode::completion-self-insert
    lem/completion-mode::completion-delete-previous-char
    lem/completion-mode::completion-backward-delete-word
    lem-yath-completion-backward-delete-word
    lem/completion-mode::completion-next-line
    lem/completion-mode::completion-previous-line
    lem/completion-mode::completion-end-of-buffer
    lem/completion-mode::completion-beginning-of-buffer
    lem/completion-mode::completion-narrowing-down-or-next-line
    lem/completion-mode::completion-select
    lem-yath-completion-tab
    lem-yath-completion-return
    lem-yath-completion-previous-history
    lem-yath-completion-next-history
    lem-yath-corfu-next
    lem-yath-corfu-previous
    lem-yath-corfu-first
    lem-yath-corfu-last
    lem-yath-corfu-prompt-beginning
    lem-yath-corfu-prompt-end
    lem-yath-corfu-scroll-forward
    lem-yath-corfu-scroll-backward
    lem-yath-corfu-expand
    lem-yath-corfu-info-location
    lem-yath-corfu-info-documentation
    lem-yath-corfu-info-scroll-forward
    lem-yath-corfu-info-scroll-backward
    lem-yath-corfu-meta-next
    lem-yath-corfu-meta-previous
    lem-yath-corfu-reset
    lem-yath-corfu-quit
    lem-yath-completion-space
    lem-yath-orderless-insert-separator
    lem-yath-act-completion))

(defun auto-completion-symbol-bounds (point)
  (with-point ((start point)
               (cursor point)
               (end point))
    (skip-chars-backward start #'syntax-symbol-char-p)
    (skip-chars-forward end #'syntax-symbol-char-p)
    (values start end (points-to-string start cursor))))

(defun auto-completion-dabbrev-character-p (character)
  "Match the ordinary Emacs syntax constituents used by Cape Dabbrev."
  (or (syntax-symbol-char-p character)
      (find character "/-" :test #'char=)))

(defun auto-completion-dabbrev-bounds (point)
  (with-point ((start point)
               (cursor point)
               (end point))
    (skip-chars-backward start #'auto-completion-dabbrev-character-p)
    (skip-chars-forward end #'auto-completion-dabbrev-character-p)
    (values start end (points-to-string start cursor))))

(defun auto-completion-symbol-prefix-length (point)
  (multiple-value-bind (start end prefix)
      (auto-completion-symbol-bounds point)
    (declare (ignore start end))
    (length prefix)))

(defun auto-completion-file-character-p (character)
  (or (alphanumericp character)
      (find character "-@~/_.${}#%,:" :test #'char=)))

(defun auto-completion-file-context (point)
  "Return file input and its replaceable final-component range at POINT.

Like Cape, require either an explicit `file:' prefix or a slash whose parent
directory already exists."
  (with-point ((bounds-start point)
               (path-start point)
               (replace-start point)
               (cursor point)
               (end point))
    (skip-chars-backward bounds-start #'auto-completion-file-character-p)
    (skip-chars-forward
     end
     (lambda (character)
       (and (auto-completion-file-character-p character)
            (char/= character #\/))))
    (let* ((token (points-to-string bounds-start cursor))
           (explicit-prefix-p
             (and (<= 5 (length token))
                  (string-equal "file:" token :end2 5)))
           (path-offset (if explicit-prefix-p 5 0)))
      (move-point path-start bounds-start)
      (character-offset path-start path-offset)
      (let* ((input (points-to-string path-start cursor))
             (expanded (ignore-errors
                         (expand-file-name input (buffer-directory))))
             (parent (and expanded (directory-namestring expanded)))
             (valid-p
               (or explicit-prefix-p
                   (and (find #\/ input)
                        parent
                        (uiop:directory-exists-p parent)))))
        (when valid-p
          (move-point replace-start cursor)
          (loop :while (point> replace-start path-start)
                :do (character-offset replace-start -1)
                :until (char= (character-at replace-start) #\/))
          (when (and (point< replace-start end)
                     (char= (character-at replace-start) #\/))
            (character-offset replace-start 1))
          (values input replace-start end))))))

(defun auto-completion-file-context-p (point)
  (not (null (nth-value 0 (auto-completion-file-context point)))))

(defun auto-completion-same-mode-buffers (buffer)
  (cons buffer
        (loop :for other :in (buffer-list)
              :unless (eq other buffer)
                :when (eq (buffer-major-mode other)
                          (buffer-major-mode buffer))
                  :collect other)))

(defun auto-completion-dabbrev-line-words (line)
  (loop :with words
        :with length = (length line)
        :for start :from 0 :below length
        :when (auto-completion-dabbrev-character-p (aref line start))
          :do (let ((end start))
                (loop :while (and (< end length)
                                  (auto-completion-dabbrev-character-p
                                   (aref line end)))
                      :do (incf end))
                (push (subseq line start end) words)
                (setf start (1- end)))
        :finally (return (nreverse words))))

(defun auto-completion-dabbrev-buffer-words (buffer)
  (with-current-buffer buffer
    (with-open-stream (stream
                       (make-buffer-input-stream
                        (buffer-start-point buffer)))
      (loop :for line := (read-line stream nil)
            :while line
            :append (auto-completion-dabbrev-line-words line)))))

(defun auto-completion-dabbrev-words (point prefix)
  (let* ((buffer (point-buffer point))
         (words
           (mapcan #'auto-completion-dabbrev-buffer-words
                   (auto-completion-same-mode-buffers buffer))))
    (remove-duplicates
     (remove-if
      (lambda (word)
        (or (string-equal prefix word)
            (not (alexandria:starts-with-subseq
                  prefix word :test #'char-equal))))
      words)
     :test #'string-equal)))

(defun auto-completion-dabbrev-case-replace (prefix word)
  "Apply the configured Cape/Dabbrev case replacement to WORD."
  (if (and (plusp (length prefix))
           (upper-case-p (char prefix 0))
           (alexandria:starts-with-subseq
            prefix word :test #'char-equal))
      (let ((case-source
              ;; Cape prevents a single uppercase character from making the
              ;; whole expansion uppercase by borrowing the candidate's next
              ;; character before classifying the input's case.
              (if (and (= 1 (length prefix)) (> (length word) 1))
                  (concatenate 'string prefix (subseq word 1 2))
                  prefix)))
        (if (find-if #'lower-case-p case-source)
            (concatenate 'string
                         (string-upcase (subseq word 0 1))
                         (subseq word 1))
            (string-upcase word)))
      word))

(defun auto-completion-dabbrev-items
    (point &optional (minimum-length *auto-completion-prefix-length*))
  (multiple-value-bind (start end prefix)
      (auto-completion-dabbrev-bounds point)
    (when (>= (length prefix) minimum-length)
      (stable-sort
       (mapcar
        (lambda (word)
          (let ((replacement
                  (auto-completion-dabbrev-case-replace prefix word)))
            (lem/completion-mode:make-completion-item
             :label replacement
             :filter-text replacement
             :insert-text replacement
             :detail "Dabbrev"
             :start start
             :end end)))
        (auto-completion-dabbrev-words point prefix))
       #'auto-completion-corfu-item-before-p))))

(defun auto-completion-file-items (point)
  (multiple-value-bind (input start end)
      (auto-completion-file-context point)
    (when input
      (clrhash *auto-completion-file-locations*)
      (auto-completion-corfu-order-items
       input
       (stable-sort
        (mapcar
         (lambda (filename)
           (let* ((label (tail-of-pathname filename))
                  (item
                    (lem/completion-mode:make-completion-item
                     :label label
                     :filter-text label
                     :insert-text label
                     :detail "File"
                     :start start
                     :end end)))
             (setf (gethash item *auto-completion-file-locations*) filename)
             item))
         (ignore-errors
           (completion-file input (buffer-directory))))
       #'auto-completion-corfu-item-before-p)
       t))))

(defun auto-completion-item-label (item)
  (lem/completion-mode:completion-item-label item))

(defun auto-completion-corfu-item-before-p (left right)
  "Implement pinned Corfu's default length-then-alphabetical order."
  (let ((left (auto-completion-item-label left))
        (right (auto-completion-item-label right)))
    (or (< (length left) (length right))
        (and (= (length left) (length right))
             (string< left right)))))

(defun auto-completion-move-label-to-front (label items)
  (let ((matches (remove-if-not
                  (lambda (item)
                    (string= label (auto-completion-item-label item)))
                  items)))
    (if matches
        (nconc matches
               (remove-if (lambda (item) (member item matches :test #'eq))
                          items))
        items)))

(defun auto-completion-corfu-order-items (input items &optional file-p)
  "Apply Corfu's exact-candidate and file-directory fronting rules."
  (let ((items (if (and file-p
                        (not (alexandria:ends-with #\/ input)))
                   (auto-completion-move-label-to-front
                    (concatenate 'string input "/") items)
                   items)))
    (auto-completion-move-label-to-front input items)))

(defun auto-completion-orderless-filter-items (input items)
  (auto-completion-corfu-order-items
   input (orderless-filter-completion-items input items)))

(defun auto-completion-input-matches-items-p (input items test)
  (not (null (find input items
                   :test test
                   :key #'auto-completion-item-label))))

(defun auto-completion-case-fold-input-valid-p (input items)
  "Match the configured non-file `completion-ignore-case' behavior."
  (auto-completion-input-matches-items-p input items #'string-equal))

(defun auto-completion-file-input-valid-p (input items)
  "Match Emacs file-table validity on the case-sensitive target filesystem."
  (auto-completion-input-matches-items-p input items #'string=))

(defun auto-completion-primary-spec (&optional (buffer (current-buffer)))
  (variable-value 'lem/language-mode:completion-spec :buffer buffer))

(defun auto-completion-provider
    (&optional (point (current-point)) manual-p)
  (or (auto-completion-primary-spec (point-buffer point))
      (let ((dabbrev-items
              (auto-completion-dabbrev-items
               point (if manual-p 1 *auto-completion-prefix-length*))))
        (if dabbrev-items
            (lem/completion-mode:make-completion-spec
             (lambda (ignored-point)
               (declare (ignore ignored-point))
               dabbrev-items)
             :test-function #'auto-completion-case-fold-input-valid-p)
            (lem/completion-mode:make-completion-spec
             #'auto-completion-file-items
             :test-function #'auto-completion-file-input-valid-p)))))

(defun auto-completion-run-manual ()
  "Start configured mode/Cape completion without the automatic threshold."
  (lem/completion-mode:run-completion
   (auto-completion-provider (current-point) t)
   :narrowing nil
   :max-display-items *auto-completion-max-display-items*
   :cycle nil))

(define-command lem-yath-indent-line-and-complete () ()
  "Indent first, then complete when indentation changed neither text nor point.

This is the effective `tab-always-indent' `complete' path.  Lem's stock
language command only checks point and only invokes the mode-local provider;
the configured Emacs command also observes buffer mutation and reaches the
ordered Cape fallback when the mode provider is absent."
  (let* ((point (current-point))
         (old-position (position-at-point point))
         (old-tick (buffer-modified-tick (current-buffer))))
    (if (variable-value 'calc-indent-function :buffer (current-buffer))
        (let ((charpos (point-charpos point)))
          (handler-case (indent-line point)
            (editor-condition ()
              (line-offset point 0 charpos)))
          (when (and (= old-position (position-at-point point))
                     (= old-tick
                        (buffer-modified-tick (current-buffer))))
            (auto-completion-run-manual)))
        (auto-completion-run-manual))))

;; Preserve every more-specific mode and minor-mode Tab binding.  This only
;; replaces Lem's generic language-mode dispatcher, so Fundamental mode keeps
;; its literal tab behavior and Org, snippets, completion, and NASM retain
;; their own maps.
(define-key lem/language-mode:*language-mode-keymap* "Tab"
  'lem-yath-indent-line-and-complete)

(defun auto-completion-prefix-ready-p (point)
  (if (auto-completion-primary-spec (point-buffer point))
      (>= (auto-completion-symbol-prefix-length point)
          *auto-completion-prefix-length*)
      (or (>= (auto-completion-symbol-prefix-length point)
              *auto-completion-prefix-length*)
          (auto-completion-file-context-p point))))

(defun auto-completion-live-session (&optional context)
  (let ((session *auto-completion-session*))
    (when (and session
               (or (null context)
                   (eq context (auto-completion-session-context session))))
      session)))

(defun auto-completion-session-owned-p ()
  (alexandria:when-let ((session (auto-completion-live-session)))
    (eq (auto-completion-session-context session)
        lem/completion-mode::*completion-context*)))

(defun auto-completion-context-input (context)
  (alexandria:when-let*
      ((start (lem/completion-mode::context-range-start context))
       (end (lem/completion-mode::context-range-end context)))
    (when (and (alive-point-p start)
               (alive-point-p end)
               (eq (point-buffer start) (point-buffer end)))
      (points-to-string start end))))

(defun auto-completion-item-preview-text (item)
  ;; LSP final inserters own snippets and text edits.  Corfu previews the CAPF
  ;; candidate label, not raw snippet syntax or additional edits.
  (if (lem/completion-mode:completion-item-final-insert-action item)
      (lem/completion-mode:completion-item-label item)
      (lem/completion-mode:completion-item-insert-text item)))

(defun auto-completion-valid-prompt-p (context items)
  "Implement Corfu's provider-aware `preselect=valid' prompt rule."
  (alexandria:when-let* ((input (auto-completion-context-input context))
                         (first (first items)))
    (let ((first-label (auto-completion-item-label first)))
      (and (not (string= input first-label))
           (not (and (auto-completion-file-context-p (current-point))
                     (string= (concatenate 'string input "/") first-label)))
           (lem/completion-mode:completion-context-input-valid-p
            context input)))))

(defun auto-completion-popup (session)
  (lem/completion-mode::context-popup-menu
   (auto-completion-session-context session)))

(defun auto-completion-popup-clear-focus (session &optional blur)
  "Select Corfu's real prompt row, optionally blurring prior documentation."
  (alexandria:when-let ((popup (auto-completion-popup session)))
    (if (and blur
             (eq (auto-completion-session-context session)
                 lem/completion-mode::*completion-context*))
        (lem/completion-mode:completion-clear-focus)
        (lem/popup-menu:popup-menu-clear-focus popup))))

(defun auto-completion-popup-show-focus (session)
  (alexandria:when-let ((popup (auto-completion-popup session)))
    (lem/popup-menu:popup-menu-activate-focus popup)))

(defun auto-completion-clear-preview (&optional
                                        (session *auto-completion-session*)
                                        redraw)
  "Delete only SESSION's display-only candidate preview."
  (when session
    (let ((window (auto-completion-session-preview-window session))
          (buffer (auto-completion-session-preview-buffer session)))
      (setf (auto-completion-session-preview-window session) nil
            (auto-completion-session-preview-buffer session) nil)
      (when window
        (ignore-errors
          (unless (deleted-window-p window)
            (delete-window window))))
      (when buffer
        (ignore-errors
          (unless (deleted-buffer-p buffer)
            (delete-buffer buffer))))
      (when (and redraw lem-core::*in-the-editor*)
        (redraw-display :force t)))))

(defun auto-completion-visible-row (point window)
  (loop :for (row start end) :in (avy-visible-rows window)
        :when (and (point<= start point)
                   (or (point< point end)
                       (and (end-buffer-p point) (point= point end))))
          :return (list row start end)))

(defun auto-completion-normalize-preview-text (text start-column)
  "Expand tabs in TEXT against START-COLUMN and reject multiline text."
  (when (find #\newline text)
    (return-from auto-completion-normalize-preview-text nil))
  (let ((column start-column))
    (values
     (with-output-to-string (stream)
       (loop :for character :across text
             :do (cond
                   ((char= character #\tab)
                    (let ((next (char-width
                                 character column
                                 :tab-size
                                 (variable-value 'tab-width
                                                 :default
                                                 (current-buffer)))))
                      (loop :repeat (- next column)
                            :do (write-char #\space stream))
                      (setf column next)))
                   ((or (char= character #\return)
                        (char< character #\space))
                    (write-char #\? stream)
                    (incf column))
                   (t
                    (write-char character stream)
                    (setf column (char-width character column))))))
     (- column start-column))))

(defun auto-completion-drop-display-cells (text cells)
  "Drop CELLS from normalized TEXT without emitting half a wide glyph."
  (if (not (plusp cells))
      text
      (with-output-to-string (stream)
        (loop :with remaining := cells
              :with copying := nil
              :for character :across text
              :for width := (- (char-width character 0) 0)
              :do (cond
                    (copying
                     (write-char character stream))
                    ((<= width remaining)
                     (decf remaining width)
                     (when (zerop remaining)
                       (setf copying t)))
                    (t
                     ;; A terminal cannot expose only half a wide glyph.
                     (loop :repeat (- width remaining)
                           :do (write-char #\space stream))
                     (setf remaining 0
                           copying t)))))))

(defun auto-completion-take-display-cells (text cells)
  "Clip normalized TEXT to at most CELLS terminal cells."
  (with-output-to-string (stream)
    (loop :with column := 0
          :for character :across text
          :for next := (char-width character column)
          :while (<= next cells)
          :do (write-char character stream)
              (setf column next))))

(defun auto-completion-preview-spec (session item)
  "Return preview TEXT, X, Y, and cell WIDTH when it is exactly representable."
  (let* ((window (auto-completion-session-window session))
         (buffer (auto-completion-session-buffer session)))
    (when (and (eq buffer (current-buffer))
               (eq window (current-window))
               (not (deleted-buffer-p buffer))
               (not (deleted-window-p window)))
      (multiple-value-bind (range-start range-end)
          (lem/completion-mode::completion-item-range (current-point) item)
        (when (and (same-line-p range-start range-end)
                   (not (lem-core::line-hidden-p range-start)))
          (alexandria:when-let ((row-entry
                                 (auto-completion-visible-row
                                  range-start window)))
            (let* ((row (first row-entry))
                   (left (window-left-width window))
                   (signed-column
                     (- (avy-display-column range-start window)
                        (avy-horizontal-scroll window)))
                   (relative-x (+ left (max 0 signed-column)))
                   (available (- (window-width window) relative-x))
                   (left-clip (max 0 (- signed-column))))
              (when (plusp available)
                (with-point ((line-end range-start))
                  (line-end line-end)
                  (let* ((replacement
                           (auto-completion-item-preview-text item))
                         (suffix (points-to-string range-end line-end))
                         (combined (concatenate 'string replacement suffix))
                         (start-column (point-column range-start))
                         (old-width (- (point-column line-end) start-column)))
                    (multiple-value-bind (normalized new-width)
                        (auto-completion-normalize-preview-text
                         combined start-column)
                      (when normalized
                        (let* ((wrap-p
                                 (variable-value 'line-wrap :default buffer))
                               (target-width (max old-width new-width)))
                          ;; A one-row float is exact only when neither the old
                          ;; nor replacement remainder reflows to another row.
                          (when (or (not wrap-p)
                                    (and (<= old-width available)
                                         (<= new-width available)))
                            (let* ((visible-target
                                     (min available
                                          (max 0 (- target-width left-clip))))
                                   (visible
                                     (auto-completion-take-display-cells
                                      (auto-completion-drop-display-cells
                                       normalized left-clip)
                                      visible-target))
                                   (visible-width
                                     (lem/common/character:string-width
                                      visible)))
                              (when (plusp visible-target)
                                (values
                                 (concatenate
                                  'string visible
                                  (make-string (- visible-target visible-width)
                                               :initial-element #\space))
                                 (+ (window-x window) relative-x)
                                 (+ (window-y window) row)
                                 visible-target)))))))))))))))))

(defun auto-completion-show-preview (session item)
  (auto-completion-clear-preview session nil)
  (multiple-value-bind (text x y width)
      (auto-completion-preview-spec session item)
    (when text
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p nil))
            (window nil))
        (setf (auto-completion-session-preview-buffer session) buffer)
        (handler-case
            (progn
              (setf (variable-value 'line-wrap :buffer buffer) nil)
              (insert-string (buffer-point buffer) text)
              (buffer-unmark buffer)
              (buffer-start (buffer-point buffer))
              (setf window
                    (make-instance
                     'lem:floating-window
                     :buffer buffer
                     :x x :y y :width width :height 1
                     :use-modeline-p nil
                     :cursor-invisible t
                     :clickable nil
                     :background-color nil)
                    (auto-completion-session-preview-window session) window)
              ;; Preview belongs to source text, below completion/docs popups.
              (let ((frame (current-frame)))
                (setf (lem-core::frame-floating-windows frame)
                      (cons window
                            (delete window
                                    (lem-core::frame-floating-windows frame)
                                    :test #'eq))))
              (redraw-display :force t))
          (error (condition)
            (auto-completion-clear-preview session t)
            (message "Could not display completion preview: ~A" condition)))))))

(defun auto-completion-current-selected-item (session)
  "Return SESSION's selection only while the current popup still owns it."
  (let* ((context (auto-completion-session-context session))
         (popup (lem/completion-mode::context-popup-menu context))
         (item (auto-completion-session-selected-item session)))
    (and item
         (eq context lem/completion-mode::*completion-context*)
         popup
         (eq item (lem/popup-menu:get-focus-item popup))
         (member item (lem/completion-mode::context-last-items context)
                 :test #'eq)
         item)))

(defun auto-completion-selected-preview-p (&optional
                                             (session
                                               *auto-completion-session*))
  (alexandria:when-let ((item
                         (and session
                              (auto-completion-current-selected-item session))))
    (not (eq item (auto-completion-session-preselect-item session)))))

(defun auto-completion-window-delete-hook ()
  (when (auto-completion-live-session)
    (ignore-errors (lem/completion-mode:completion-end))))

(defun auto-completion-start-session (context item)
  (let* ((buffer (lem/completion-mode::context-buffer context))
         (window (current-window))
         (items (lem/completion-mode::context-last-items context))
         (preselect (unless (auto-completion-valid-prompt-p context items)
                      item))
         (change-group
           (handler-case (buffer-prepare-change-group buffer)
             (error (condition)
               (message "Completion reset unavailable: ~A" condition)
               nil)))
         (session
           (make-auto-completion-session
            :context context
            :buffer buffer
            :window window
            :change-group change-group
            :preselect-item preselect
            :selected-item preselect)))
    (setf *auto-completion-session* session)
    (add-hook (window-delete-hook window)
              'auto-completion-window-delete-hook)
    (if preselect
        (auto-completion-popup-show-focus session)
        (auto-completion-popup-clear-focus session))
    session))

(defun auto-completion-accept-session-change-group (session)
  (alexandria:when-let ((group
                         (auto-completion-session-change-group session)))
    (when (buffer-change-group-active-p group)
      (handler-case (buffer-accept-change-group group)
        (error (condition)
          (message
           "Could not close completion undo group; discarding its history: ~A"
           condition)
          ;; Completion teardown cannot retain a live owner after this session
          ;; disappears.  Keep the text and fail closed by releasing ownership
          ;; through the core's explicit truncated-history path.
          (buffer-abort-change-group group))))
    (setf (auto-completion-session-change-group session) nil)))

(defun auto-completion-teardown-session (&optional
                                           (session
                                             *auto-completion-session*))
  "Idempotently remove SESSION and accept its real input changes."
  (when (and session (not (auto-completion-session-cleaning-p session)))
    (setf (auto-completion-session-cleaning-p session) t)
    (when (eq session *auto-completion-session*)
      (setf *auto-completion-session* nil))
    (let ((window (auto-completion-session-window session)))
      (when window
        (ignore-errors
          (remove-hook (window-delete-hook window)
                       'auto-completion-window-delete-hook))))
    (auto-completion-clear-preview session nil)
    (auto-completion-close-info)
    (auto-completion-accept-session-change-group session)
    (when lem-core::*in-the-editor*
      (redraw-display :force t))))

(defun auto-completion-refresh-selection (session context item)
  "Reset implicit selection for an explicitly presented provider generation."
  (auto-completion-clear-preview session nil)
  (let* ((items (lem/completion-mode::context-last-items context))
         (preselect (unless (auto-completion-valid-prompt-p context items)
                      item)))
    (setf (auto-completion-session-preselect-item session) preselect
          (auto-completion-session-selected-item session) preselect)
    (if preselect
        (auto-completion-popup-show-focus session)
        (auto-completion-popup-clear-focus session))))

(defun auto-completion-select-focused-item (session item)
  (setf (auto-completion-session-selected-item session) item)
  (if (auto-completion-selected-preview-p session)
      (progn
        (auto-completion-popup-show-focus session)
        (auto-completion-show-preview session item))
      (auto-completion-clear-preview session t)))

(defun auto-completion-context-observer (context event item)
  "Observe only Corfu-style automatic contexts; prompt contexts stay native."
  (case event
    (:present
     (when (lem/completion-mode::context-automatic-p context)
       (alexandria:if-let ((session (auto-completion-live-session context)))
         (auto-completion-refresh-selection session context item)
         (auto-completion-start-session context item))))
    (:focus
     (when (lem/completion-mode::context-automatic-p context)
       (alexandria:when-let ((session (auto-completion-live-session context)))
         (auto-completion-select-focused-item session item))))
    (:end
     (alexandria:when-let ((session
                            (auto-completion-live-session context)))
       (when (eq context *auto-completion-context*)
         (setf *auto-completion-context* nil))
       (auto-completion-teardown-session session)))))

(defun auto-completion-first-item (session)
  (first
   (lem/completion-mode::context-last-items
    (auto-completion-session-context session))))

(defun auto-completion-return-to-prompt (session)
  (auto-completion-clear-preview session nil)
  (setf (auto-completion-session-selected-item session) nil)
  (auto-completion-popup-clear-focus session t)
  (redraw-display :force t))

(defun auto-completion-call-navigation (function)
  (funcall function))

(defun auto-completion-navigate (direction)
  "Navigate the owned popup with Corfu's logical prompt row and no cycling."
  (alexandria:if-let ((session
                       (and (auto-completion-session-owned-p)
                            (auto-completion-live-session))))
    (let ((selected (auto-completion-session-selected-item session))
          (preselect (auto-completion-session-preselect-item session))
          (first (auto-completion-first-item session)))
      (ecase direction
        (:next
         (if selected
             (auto-completion-call-navigation
              #'lem/completion-mode::completion-next-line)
             (auto-completion-call-navigation
              #'lem/completion-mode::completion-beginning-of-buffer)))
        (:previous
         (cond
           ((null selected))
           ((and (null preselect) (eq selected first))
            (auto-completion-return-to-prompt session))
           (t
            (auto-completion-call-navigation
             #'lem/completion-mode::completion-previous-line))))
        (:first
         (if (and (null preselect)
                  (or (null selected) (eq selected first)))
             (auto-completion-return-to-prompt session)
             (auto-completion-call-navigation
              #'lem/completion-mode::completion-beginning-of-buffer)))
        (:last
         (auto-completion-call-navigation
          #'lem/completion-mode::completion-end-of-buffer))))
    (ecase direction
      (:next (lem/completion-mode::completion-next-line))
      (:previous (lem/completion-mode::completion-previous-line))
      (:first (lem/completion-mode::completion-beginning-of-buffer))
      (:last (lem/completion-mode::completion-end-of-buffer)))))

(defun auto-completion-prompt-active-p ()
  (not (null (lem/prompt-window:current-prompt-window))))

(defun auto-completion-context-options (spec)
  "Apply the provider's configured Corfu filtering and validity semantics."
  (cond
    ;; Vertico only displays and filters prompt candidates.  Merely opening a
    ;; synchronous list must not insert its common prefix or accept a singleton.
    ((auto-completion-prompt-active-p)
     (list :narrowing nil))
    ((and (null (auto-completion-primary-spec))
          (auto-completion-file-context-p (current-point)))
     (list :test-function
           (or (lem/completion-mode::spec-test-function spec)
               #'auto-completion-file-input-valid-p)
           :observer-function #'auto-completion-context-observer))
    (t
     (list :filter-function #'auto-completion-orderless-filter-items
           :test-function
           (or (lem/completion-mode::spec-test-function spec)
               #'auto-completion-case-fold-input-valid-p)
           :separator #\Space
           :observer-function #'auto-completion-context-observer))))

(setf (variable-value
       'lem/completion-mode:completion-context-options-function :global)
      #'auto-completion-context-options)

(defun auto-completion-insert-state-p (buffer)
  (or (not (mode-active-p buffer 'lem-vi-mode:vi-mode))
      (let ((state (lem-vi-mode/core:current-state)))
        (and (typep state 'lem-vi-mode:insert)
             ;; REPLACE inherits INSERT's keymap, but completion's fallback
             ;; command does not participate in Vi's overwrite pre-command
             ;; path.  Keep the popup out of replacement sessions entirely.
             (not (typep state 'lem-vi-mode/states:replace-state))))))

(defun auto-completion-eligible-p ()
  (let ((buffer (current-buffer)))
    (and (null lem/completion-mode::*completion-context*)
         (not (auto-completion-prompt-active-p))
         (not (buffer-read-only-p buffer))
         (not (key-recording-p))
         (not lem/kbdmacro::*macro-running-p*)
         (auto-completion-insert-state-p buffer)
         (auto-completion-prefix-ready-p (current-point)))))

(defun auto-completion-trigger-command-p (command)
  (or (typep command 'self-insert)
      (member (command-name command)
              '(delete-previous-char
                lem/completion-mode::completion-self-insert
                lem/completion-mode::completion-delete-previous-char
                lem/completion-mode::completion-backward-delete-word
                lem-yath-completion-backward-delete-word))))

(defun auto-completion-continue-command-p (command)
  (member (command-name command) *auto-completion-continue-commands*))

(defun auto-completion-cancel-timer ()
  (incf *auto-completion-generation*)
  (when *auto-completion-timer*
    (ignore-errors (stop-timer *auto-completion-timer*))
    (setf *auto-completion-timer* nil)))

(defun auto-completion-context-pending-p ()
  (and *auto-completion-context*
       (eq *auto-completion-context*
           lem/completion-mode::*completion-context*)
       (lem/completion-mode::context-request-pending-p
        *auto-completion-context*)
       (null (lem/completion-mode::context-popup-menu
              *auto-completion-context*))))

(defun auto-completion-owned-context-p ()
  (and *auto-completion-context*
       (eq *auto-completion-context*
           lem/completion-mode::*completion-context*)))

(defun auto-completion-accept-selected (session)
  (alexandria:when-let ((item (auto-completion-current-selected-item session)))
    (auto-completion-clear-preview session nil)
    (lem/completion-mode::completion-accept (current-point) item)
    t))

(defun auto-completion-tab ()
  "Implement Corfu complete: selected candidate, otherwise common prefix."
  (alexandria:if-let ((session
                       (and (auto-completion-session-owned-p)
                            (auto-completion-live-session))))
    (if (auto-completion-current-selected-item session)
        (auto-completion-accept-selected session)
        (alexandria:when-let
            ((items
               (lem/completion-mode::context-last-items
                (auto-completion-session-context session))))
          (lem/completion-mode::narrowing-down
           (auto-completion-session-context session) items)))
    (lem/completion-mode::completion-narrowing-down-or-next-line)))

(defun auto-completion-expand ()
  "Implement Corfu expand without accepting its implicit preselection."
  (alexandria:if-let ((session
                       (and (auto-completion-session-owned-p)
                            (auto-completion-live-session))))
    (if (auto-completion-selected-preview-p session)
        (auto-completion-accept-selected session)
        (alexandria:when-let
            ((items
               (lem/completion-mode::context-last-items
                (auto-completion-session-context session))))
          (lem/completion-mode::narrowing-down
           (auto-completion-session-context session) items)))
    (lem/completion-mode::completion-narrowing-down-or-next-line)))

(defun auto-completion-close-info ()
  "Close the transient Corfu information window, if this module owns it."
  (let ((window *auto-completion-info-window*)
        (buffer *auto-completion-info-buffer*)
        (owned-p *auto-completion-info-buffer-owned-p*))
    (setf *auto-completion-info-window* nil
          *auto-completion-info-buffer* nil
          *auto-completion-info-buffer-owned-p* nil)
    (when (and window (not (deleted-window-p window)))
      (ignore-errors (quit-window window :kill-buffer owned-p)))
    (when (and owned-p buffer (not (deleted-buffer-p buffer)))
      (ignore-errors (delete-buffer buffer)))
    (when (and lem-core::*in-the-editor* window)
      (redraw-display :force t))))

(defun auto-completion-display-info-buffer (buffer &key owned-p)
  "Display BUFFER transiently without moving focus away from completion."
  (auto-completion-close-info)
  (let* ((source-window (current-window))
         (info-window (pop-to-buffer buffer :split-action :sensibly)))
    (unless (eq info-window source-window)
      (setf *auto-completion-info-window* info-window
            *auto-completion-info-buffer* buffer
            *auto-completion-info-buffer-owned-p* owned-p))
    (redraw-display :force t)
    info-window))

(defun auto-completion-selected-item-or-error ()
  (or (alexandria:when-let ((session
                             (and (auto-completion-session-owned-p)
                                  (auto-completion-live-session))))
        (auto-completion-current-selected-item session))
      (editor-error "No completion candidate is selected")))

(defun auto-completion-documentation-buffer (item)
  "Run ITEM's provider documentation action and capture its rendered buffer."
  (let ((action
          (lem/completion-mode::completion-item-focus-action item))
        (context lem/completion-mode::*completion-context*))
    (unless action
      (editor-error "No documentation available for `~a'"
                    (auto-completion-item-label item)))
    ;; Focus actions render provider-owned Markdown through Lem's message
    ;; window. Promote that exact buffer into Corfu's explicit information
    ;; split instead of trying to reconstruct provider documentation here.
    (clear-message)
    (funcall action context)
    (let ((window (frame-message-window (current-frame))))
      (unless (and window (not (deleted-window-p window)))
        (editor-error "No documentation available for `~a'"
                      (auto-completion-item-label item)))
      (let ((buffer (window-buffer window)))
        (setf (frame-message-window (current-frame)) nil)
        (delete-window window)
        ;; Markdown rendering constructs this owned temporary buffer through
        ;; ordinary insertion.  It has no user edits to confirm on teardown.
        (buffer-unmark buffer)
        buffer))))

(defun auto-completion-info-pre-command ()
  "Restore the layout before the command following Corfu information."
  (when (and *auto-completion-info-window*
             (not
              (member
               (and (this-command) (command-name (this-command)))
               '(lem-yath-corfu-info-scroll-forward
                 lem-yath-corfu-info-scroll-backward))))
    (auto-completion-close-info)))

(defun auto-completion-info-scroll (direction argument)
  "Scroll the transient Corfu information window in DIRECTION.

Without ARGUMENT, move by one windowful minus two context rows.  A numeric
prefix scrolls that many rows; a negative prefix reverses DIRECTION."
  (let ((window *auto-completion-info-window*))
    (unless (and window (not (deleted-window-p window)))
      (editor-error "No Corfu information window is visible"))
    (let* ((page-size (max 1 (- (window-height window) 2)))
           (amount (* direction (or argument page-size))))
      (if (minusp amount)
          (lem-core/commands/window:scroll-up (- amount) window)
          (lem-core/commands/window:scroll-down amount window))
      (redraw-display :force t))))

(define-command lem-yath-corfu-info-scroll-forward (argument) (:universal-nil)
  "Scroll Corfu documentation forward like Emacs `scroll-other-window'."
  (auto-completion-info-scroll 1 argument))

(define-command lem-yath-corfu-info-scroll-backward (argument) (:universal-nil)
  "Scroll Corfu documentation backward like `scroll-other-window-down'."
  (auto-completion-info-scroll -1 argument))

(define-command lem-yath-corfu-expand () ()
  "Expand the common candidate prefix like Corfu's default M-Tab."
  (if (auto-completion-prompt-active-p)
      (editor-error "M-Tab is not bound in completion prompts")
      (auto-completion-expand)))

(define-command lem-yath-corfu-info-documentation () ()
  "Show the selected Corfu candidate's provider documentation."
  (if (auto-completion-prompt-active-p)
      (call-command 'show-context-menu nil)
      (let* ((item (auto-completion-selected-item-or-error))
             (buffer (auto-completion-documentation-buffer item)))
        (auto-completion-display-info-buffer buffer :owned-p t))))

(define-command lem-yath-corfu-info-location () ()
  "Show the selected Corfu file candidate without accepting it."
  (if (auto-completion-prompt-active-p)
      (call-command 'goto-line nil)
      (let* ((item (auto-completion-selected-item-or-error))
             (location (gethash item *auto-completion-file-locations*))
             (pathname
               (and location (ignore-errors (uiop:probe-file* location)))))
        (unless pathname
          (editor-error "No location available for `~a'"
                        (auto-completion-item-label item)))
        (auto-completion-display-info-buffer (find-file-buffer pathname)))))

(defun auto-completion-return ()
  "Implement Corfu insert: selected candidate, or quit at the prompt row."
  (alexandria:if-let ((session
                       (and (auto-completion-session-owned-p)
                            (auto-completion-live-session))))
    (if (auto-completion-current-selected-item session)
        (auto-completion-accept-selected session)
        (lem/completion-mode:completion-end))
    (lem/completion-mode::completion-select)))

(defun auto-completion-reset-selection (session)
  (auto-completion-clear-preview session nil)
  (if (auto-completion-session-preselect-item session)
      (lem/completion-mode::completion-beginning-of-buffer)
      (progn
        (setf (auto-completion-session-selected-item session) nil)
        (auto-completion-popup-clear-focus session t)))
  (redraw-display :force t))

(defun auto-completion-reset-input (session)
  (let* ((context (auto-completion-session-context session))
         (before (auto-completion-context-input context))
         (group (auto-completion-session-change-group session)))
    (unless (and group (buffer-change-group-active-p group))
      (message "Completion input cannot be reset safely; keeping it")
      (lem/completion-mode:completion-end)
      (return-from auto-completion-reset-input nil))
    (handler-case
        (progn
          (buffer-cancel-change-group group)
          (setf (auto-completion-session-change-group session) nil)
          (alexandria:when-let
              ((end (lem/completion-mode::context-range-end context)))
            (when (alive-point-p end)
              (move-point (current-point) end)))
          (let ((after (auto-completion-context-input context)))
            (if (equal before after)
                (lem/completion-mode:completion-end)
                (handler-case
                    (progn
                      (setf (auto-completion-session-change-group session)
                            (buffer-prepare-change-group
                             (auto-completion-session-buffer session)))
                      (lem/completion-mode:completion-refresh))
                  (error (condition)
                    (message "Completion reset stopped: ~A" condition)
                    (lem/completion-mode:completion-end))))))
      (error (condition)
        (message "Completion reset refused: ~A" condition)
        (lem/completion-mode:completion-end)))))

(define-command lem-yath-corfu-reset () ()
  "Reset selection, then input, then quit like the configured Corfu Escape."
  (alexandria:if-let ((session
                       (and (auto-completion-session-owned-p)
                            (auto-completion-live-session))))
    (if (auto-completion-selected-preview-p session)
        (auto-completion-reset-selection session)
        (auto-completion-reset-input session))
    (progn
      (unread-key-sequence (last-read-key-sequence))
      (lem/completion-mode:completion-end))))

(define-command lem-yath-corfu-quit () ()
  "Quit automatic completion without applying or resetting its preview."
  (if (auto-completion-session-owned-p)
      (progn
        (auto-completion-clear-preview *auto-completion-session* nil)
        (lem/completion-mode:completion-end))
      (progn
        (unread-key-sequence (last-read-key-sequence))
        (lem/completion-mode:completion-end))))

(define-command lem-yath-corfu-next () ()
  (auto-completion-navigate :next))

(define-command lem-yath-corfu-previous () ()
  (auto-completion-navigate :previous))

(define-command lem-yath-corfu-first () ()
  (auto-completion-navigate :first))

(define-command lem-yath-corfu-last () ()
  (auto-completion-navigate :last))

(defun auto-completion-live-range-point (context accessor)
  "Return CONTEXT's live completion boundary selected by ACCESSOR."
  (alexandria:when-let ((point (funcall accessor context)))
    (when (and (alive-point-p point)
               (eq (point-buffer point) (current-buffer)))
      point)))

(defun auto-completion-return-to-boundary (boundary line-command)
  "Implement Corfu's prompt-row BOUNDARY motion.

The first invocation returns from a selected candidate to BOUNDARY.  At an
already active prompt boundary, LINE-COMMAND retains ordinary line motion."
  (alexandria:if-let ((session
                       (and (auto-completion-session-owned-p)
                            (auto-completion-live-session))))
    (let* ((context (auto-completion-session-context session))
           (point (funcall boundary context))
           (selected (auto-completion-session-selected-item session))
           (preselect (auto-completion-session-preselect-item session)))
      (if (and point
               (eq selected preselect)
               (point= point (current-point)))
          (call-command line-command nil)
          (progn
            (auto-completion-reset-selection session)
            (when point
              (move-point (current-point) point)))))
    (call-command line-command nil)))

(define-command lem-yath-corfu-prompt-beginning () ()
  "Return to Corfu's input start, then retain ordinary line-beginning motion."
  (if (auto-completion-prompt-active-p)
      (lem-yath-prompt-beginning-of-line)
      (auto-completion-return-to-boundary
       (lambda (context)
         (auto-completion-live-range-point
          context #'lem/completion-mode::context-range-start))
       'move-to-beginning-of-line)))

(define-command lem-yath-corfu-prompt-end () ()
  "Return to Corfu's input end, then retain ordinary line-end motion."
  (if (auto-completion-prompt-active-p)
      (call-command 'move-to-end-of-line nil)
      (auto-completion-return-to-boundary
       (lambda (context)
         (auto-completion-live-range-point
          context #'lem/completion-mode::context-range-end))
       'move-to-end-of-line)))

(defun auto-completion-scroll-page (direction)
  "Move one completion popup page in DIRECTION without cycling."
  (alexandria:when-let*
      ((context lem/completion-mode::*completion-context*)
       (popup (lem/completion-mode::context-popup-menu context)))
    (let ((count (or (lem/completion-mode::context-max-display-items context)
                     20)))
      (lem/completion-mode::clear-context-focus-message context)
      (ecase direction
        (:forward
         (dotimes (index count)
           (declare (ignore index))
           (when (and (lem/popup-menu:popup-menu-focus-active-p popup)
                      (lem/completion-mode::popup-focus-at-last-item-p popup))
             (return))
           (popup-menu-down popup)))
        (:backward
         (if (not (lem/popup-menu:popup-menu-focus-active-p popup))
             (popup-menu-first popup)
             (dotimes (index count)
               (declare (ignore index))
               (when (lem/completion-mode::popup-focus-at-first-item-p popup)
                 (return))
               (popup-menu-up popup)))))
      (lem/completion-mode::call-focus-action))))

(define-command lem-yath-corfu-scroll-forward () ()
  "Move forward by one configured Corfu or Vertico page."
  (auto-completion-scroll-page :forward))

(define-command lem-yath-corfu-scroll-backward () ()
  "Move backward by one configured Corfu or Vertico page."
  (auto-completion-scroll-page :backward))

(define-command lem-yath-corfu-meta-next () ()
  (if (completion-prompt-active-p)
      (lem-yath-completion-next-history)
      (auto-completion-navigate :next)))

(define-command lem-yath-corfu-meta-previous () ()
  (if (completion-prompt-active-p)
      (lem-yath-completion-previous-history)
      (auto-completion-navigate :previous)))

(defparameter *auto-completion-preview-edit-commands*
  '(lem/completion-mode::completion-self-insert
    lem/completion-mode::completion-delete-previous-char
    lem/completion-mode::completion-backward-delete-word
    lem-yath-completion-backward-delete-word
    lem-yath-completion-space))

(defun auto-completion-pre-command ()
  "Commit a semantic preview before the next ordinary command executes."
  (alexandria:when-let ((session
                         (and (auto-completion-session-owned-p)
                              (auto-completion-live-session))))
    (let* ((command (this-command))
           (name (command-name command))
           (continue-p (auto-completion-continue-command-p command)))
      (cond
        ((and (auto-completion-selected-preview-p session)
              (or (not continue-p)
                  (member name *auto-completion-preview-edit-commands*)))
         (auto-completion-accept-selected session))
        ((not continue-p)
         (lem/completion-mode:completion-end))))))

(defun auto-completion-window-size-change (window)
  (alexandria:when-let ((session (auto-completion-live-session)))
    (when (eq window (auto-completion-session-window session))
      (auto-completion-clear-preview session nil)
      (when (auto-completion-selected-preview-p session)
        (ignore-errors
          (auto-completion-show-preview
           session (auto-completion-session-selected-item session)))))))

(defun auto-completion-kill-buffer-hook (buffer)
  (alexandria:when-let ((session (auto-completion-live-session)))
    (when (eq buffer (auto-completion-session-buffer session))
      (ignore-errors (lem/completion-mode:completion-end)))))

(defun auto-completion-shutdown ()
  (auto-completion-cancel-timer)
  (alexandria:when-let ((session (auto-completion-live-session)))
    (if (eq (auto-completion-session-context session)
            lem/completion-mode::*completion-context*)
        (ignore-errors (lem/completion-mode:completion-end))
        (auto-completion-teardown-session session))))

(defun auto-completion-prune-context ()
  (unless (eq *auto-completion-context*
              lem/completion-mode::*completion-context*)
    (setf *auto-completion-context* nil))
  (alexandria:when-let ((session (auto-completion-live-session)))
    (unless (eq (auto-completion-session-context session)
                lem/completion-mode::*completion-context*)
      (auto-completion-teardown-session session))))

(defun auto-completion-snapshot-valid-p
    (timer generation window buffer tick position)
  (and (eq timer *auto-completion-timer*)
       (= generation *auto-completion-generation*)
       (eq window (current-window))
       (eq buffer (current-buffer))
       (= tick (buffer-modified-tick buffer))
       (= position (position-at-point (current-point)))
       (auto-completion-eligible-p)))

(defun auto-completion-fire
    (timer generation window buffer tick position)
  (when (and (eq timer *auto-completion-timer*)
             (= generation *auto-completion-generation*))
    (let ((queued-p (plusp (event-queue-length)))
          (valid-p (auto-completion-snapshot-valid-p
                    timer generation window buffer tick position)))
      ;; A one-shot timer is no longer pending even when its snapshot became
      ;; invalid.  Do not retain an expired object in global state.
      (setf *auto-completion-timer* nil)
      (cond
        ;; Lem has no `while-no-input'.  Do not query a provider ahead of an
        ;; already queued key or editor event.  A replacement timer is safe: a
        ;; queued command will invalidate it from the post-command hook.
        (queued-p
         (when valid-p
           (auto-completion-schedule)))
        (valid-p
         (handler-case
             (let ((context
                     (lem/completion-mode:run-completion
                      (auto-completion-provider)
                      :automatic t
                      :max-display-items *auto-completion-max-display-items*
                      :cycle nil)))
               (setf *auto-completion-context*
                     (and
                      (eq context lem/completion-mode::*completion-context*)
                      context)))
           (error (condition)
             (setf *auto-completion-context* nil)
             (message "Automatic completion failed: ~a" condition))))))))

(defun auto-completion-schedule ()
  (when (auto-completion-eligible-p)
    (let* ((generation *auto-completion-generation*)
           (window (current-window))
           (buffer (current-buffer))
           (tick (buffer-modified-tick buffer))
           (position (position-at-point (current-point)))
           (timer nil))
      (setf timer
            (make-timer
             (lambda ()
               (auto-completion-fire
                timer generation window buffer tick position))
             :name "lem-yath automatic completion"))
      (setf *auto-completion-timer* timer)
      (start-timer timer *auto-completion-delay-ms* :repeat nil))))

(defun auto-completion-post-command ()
  "Debounce completion after ordinary insertion and backward deletion."
  (auto-completion-cancel-timer)
  (let ((command-name (command-name (this-command))))
    (when (and
           (auto-completion-owned-context-p)
           (or (not (auto-completion-continue-command-p (this-command)))
               (and
                (auto-completion-context-pending-p)
                (not (member
                      command-name
                      '(lem/completion-mode::completion-self-insert
                        lem/completion-mode::completion-delete-previous-char
                        lem/completion-mode::completion-backward-delete-word
                        lem-yath-completion-backward-delete-word))))))
      (lem/completion-mode:completion-end)))
  (auto-completion-prune-context)
  (when (and (null lem/completion-mode::*completion-context*)
             (auto-completion-trigger-command-p (this-command)))
    (auto-completion-schedule)))

(remove-hook *pre-command-hook* 'auto-completion-pre-command)
(remove-hook *pre-command-hook* 'auto-completion-info-pre-command)
(remove-hook *post-command-hook* 'auto-completion-post-command)
(remove-hook *window-size-change-functions*
             'auto-completion-window-size-change)
(remove-hook (variable-value 'kill-buffer-hook :global t)
             'auto-completion-kill-buffer-hook)
(remove-hook *exit-editor-hook* 'auto-completion-shutdown)
(remove-hook *exit-editor-hook* 'auto-completion-cancel-timer)

(add-hook *pre-command-hook* 'auto-completion-info-pre-command 900)
(add-hook *pre-command-hook* 'auto-completion-pre-command 1000)
(add-hook *post-command-hook* 'auto-completion-post-command -100)
(add-hook *window-size-change-functions*
          'auto-completion-window-size-change)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'auto-completion-kill-buffer-hook)
(add-hook *exit-editor-hook* 'auto-completion-shutdown)

(define-command lem-yath-orderless-insert-separator () ()
  "Insert Corfu's separator and switch the current batch to local filtering."
  (let* ((session (and (auto-completion-session-owned-p)
                       (auto-completion-live-session)))
         (preview-p (auto-completion-selected-preview-p session)))
    (when preview-p
      (auto-completion-reset-selection session))
    (if (lem/completion-mode:completion-start-local-filtering #\Space)
        (unless (and preview-p
                     (let ((context
                             (auto-completion-session-context session)))
                       (or
                        (alexandria:when-let
                            ((start
                               (lem/completion-mode::context-range-start
                                context)))
                          (point= start (current-point)))
                        (alexandria:when-let
                            ((previous (character-at (current-point) -1)))
                          (char= previous #\Space)))))
          (insert-character (current-point) #\Space)
          (lem/completion-mode:completion-refresh))
        (lem-yath-completion-space))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "M-Space" 'lem-yath-orderless-insert-separator)
(define-key lem/completion-mode::*completion-mode-keymap*
  "Escape" 'lem-yath-corfu-reset)
(define-key lem/completion-mode::*completion-mode-keymap*
  "C-g" 'lem-yath-corfu-quit)
(define-key lem/completion-mode::*completion-mode-keymap*
  'next-line 'lem-yath-corfu-next)
(define-key lem/completion-mode::*completion-mode-keymap*
  "Down" 'lem-yath-corfu-next)
(define-key lem/completion-mode::*completion-mode-keymap*
  'previous-line 'lem-yath-corfu-previous)
(define-key lem/completion-mode::*completion-mode-keymap*
  "Up" 'lem-yath-corfu-previous)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-n" 'lem-yath-corfu-meta-next)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-p" 'lem-yath-corfu-meta-previous)
(define-key lem/completion-mode::*completion-mode-keymap*
  "C-a" 'lem-yath-corfu-prompt-beginning)
(define-key lem/completion-mode::*completion-mode-keymap*
  "Home" 'lem-yath-corfu-prompt-beginning)
(define-key lem/completion-mode::*completion-mode-keymap*
  "C-e" 'lem-yath-corfu-prompt-end)
(define-key lem/completion-mode::*completion-mode-keymap*
  "End" 'lem-yath-corfu-prompt-end)
(define-key lem/completion-mode::*completion-mode-keymap*
  "C-v" 'lem-yath-corfu-scroll-forward)
(define-key lem/completion-mode::*completion-mode-keymap*
  "PageDown" 'lem-yath-corfu-scroll-forward)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-v" 'lem-yath-corfu-scroll-backward)
(define-key lem/completion-mode::*completion-mode-keymap*
  "PageUp" 'lem-yath-corfu-scroll-backward)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-Tab" 'lem-yath-corfu-expand)
(define-key lem/completion-mode::*completion-mode-keymap*
  "C-M-i" 'lem-yath-corfu-expand)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-g" 'lem-yath-corfu-info-location)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-h" 'lem-yath-corfu-info-documentation)
(define-key lem/completion-mode::*completion-mode-keymap*
  "C-M-v" 'lem-yath-corfu-info-scroll-forward)
(define-key lem/completion-mode::*completion-mode-keymap*
  "C-M-Shift-v" 'lem-yath-corfu-info-scroll-backward)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-PageUp" 'lem-yath-corfu-info-scroll-backward)
(define-key lem/completion-mode::*completion-mode-keymap*
  'move-to-end-of-buffer 'lem-yath-corfu-last)
(define-key lem/completion-mode::*completion-mode-keymap*
  'move-to-beginning-of-buffer 'lem-yath-corfu-first)
