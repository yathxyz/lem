;;;; Editing defaults. Emacs side: tab-width 4, fill-column 70,
;;;; ws-butler (trim trailing whitespace on save), raised undo limits.

(in-package :lem-yath)

(setf (variable-value 'tab-width :global) 4
      (variable-value 'indent-tabs-mode :global) nil)

;;; ws-butler parity: remember changed lines and trim only those lines when a
;;; programming buffer is saved. Existing whitespace elsewhere is preserved.

(defvar *trim-trailing-whitespace* t)
(defvar *trimming-touched-lines* nil)
(defparameter *fill-column* 70)

(defun lem-yath-buffer-fill-column (&optional (buffer (current-buffer)))
  (or (buffer-value buffer 'lem-yath-fill-column)
      *fill-column*))

(defparameter *non-programming-language-mode-classes*
  '(("LEM-MARKDOWN-MODE" . "MARKDOWN-MODE")
    ("LEM-ASCIIDOC-MODE" . "ASCIIDOC-MODE")
    ("LEM-YATH" . "TYPST-MODE")
    ("LEM-XML-MODE" . "XML-MODE")
    ("LEM-PATCH-MODE" . "PATCH-MODE")
    ("LEM-REVIEW-MODE" . "REVIEW-MODE"))
  "Lem language modes which correspond to Emacs text or special modes.")

(defun mode-object-typep (mode-object class-name)
  (destructuring-bind (package-name . symbol-name) class-name
    (alexandria:when-let* ((package (find-package package-name))
                           (symbol (find-symbol symbol-name package)))
      (and (find-class symbol nil)
           (typep mode-object symbol)))))

(defun programming-buffer-p (buffer)
  "Whether BUFFER is the Lem equivalent of an Emacs `prog-mode' buffer."
  (let ((mode-object (ignore-errors
                       (ensure-mode-object (buffer-major-mode buffer)))))
    (and mode-object
         (typep mode-object 'lem/language-mode:language-mode)
         (notany (lambda (class-name)
                   (mode-object-typep mode-object class-name))
                 *non-programming-language-mode-classes*))))

(defun touched-line-points (buffer)
  (buffer-value buffer 'lem-yath-touched-line-points))

(defun (setf touched-line-points) (points buffer)
  (setf (buffer-value buffer 'lem-yath-touched-line-points) points))

(defun clear-touched-line-points (buffer)
  (let ((points (touched-line-points buffer)))
    (setf (touched-line-points buffer) nil)
    (dolist (point points)
      (ignore-errors (delete-point point)))))

(defun remember-touched-line (buffer point)
  (with-point ((line point))
    (line-start line)
    (unless (find line (touched-line-points buffer) :test #'same-line-p)
      (push (copy-point line :right-inserting)
            (touched-line-points buffer)))))

(defun begin-touched-line-epoch (point change)
  "Discard stale markers before the first change to a clean buffer."
  (declare (ignore change))
  (let ((buffer (point-buffer point)))
    (when (and *trim-trailing-whitespace*
               (not *trimming-touched-lines*)
               (programming-buffer-p buffer)
               (not (buffer-value
                     buffer 'lem-yath-save-normalization-pending))
               (not (buffer-modified-p buffer)))
      (clear-touched-line-points buffer))))

(defun track-touched-lines (start end old-length)
  "Record every surviving line affected by one buffer change."
  (declare (ignore old-length))
  (let ((buffer (point-buffer start)))
    (when (and *trim-trailing-whitespace*
               (not *trimming-touched-lines*)
               (programming-buffer-p buffer))
      (with-point ((line start))
        (line-start line)
        (loop
          (remember-touched-line buffer line)
          (when (or (same-line-p line end)
                    (not (line-offset line 1)))
            (return)))))))

(defun trim-line-trailing-whitespace (point)
  (with-point ((cursor point))
    (line-end cursor)
    (loop :while (member (character-at cursor -1) '(#\Space #\Tab))
          :do (progn
                (character-offset cursor -1)
                (delete-character cursor 1)))))

(defun trim-touched-trailing-whitespace (buffer)
  (when (and *trim-trailing-whitespace*
             (buffer-filename buffer)
             (programming-buffer-p buffer))
    (let ((*trimming-touched-lines* t))
      (dolist (point (touched-line-points buffer))
        (trim-line-trailing-whitespace point)))))

(defun clear-touched-lines-after-save (&rest args)
  (let ((buffer (or (first args) (current-buffer))))
    (when (typep buffer 'lem:buffer)
      (when (buffer-value buffer 'lem-yath-save-normalization-complete)
        (clear-touched-line-points buffer)
        (setf (buffer-value buffer 'lem-yath-save-normalization-pending) nil))
      (setf (buffer-value buffer 'lem-yath-save-normalization-complete) nil))))

(add-hook (variable-value 'before-change-functions :global t)
          'begin-touched-line-epoch)

(add-hook (variable-value 'after-change-functions :global t)
          'track-touched-lines)

;; Save-time text mutation is owned by formatting-before-save-hook so touched
;; line cleanup and EditorConfig normalization share its retained transaction.
(remove-hook (variable-value 'before-save-hook :global t)
             'trim-trailing-whitespace-hook)

(add-hook (variable-value 'after-save-hook :global t)
          'clear-touched-lines-after-save)

;;; paragraph filling ---------------------------------------------------------

(defun lem-yath-blank-line-p (point)
  (every (lambda (char) (member char '(#\Space #\Tab)))
         (line-string point)))

(defun lem-yath-paragraph-bounds ()
  "Return the nonblank paragraph around point as two temporary points."
  (when (lem-yath-blank-line-p (current-point))
    (return-from lem-yath-paragraph-bounds))
  (with-point ((start (current-point) :left-inserting)
               (end (current-point) :right-inserting))
    (line-start start)
    (loop
      (with-point ((previous start))
        (unless (and (line-offset previous -1)
                     (not (lem-yath-blank-line-p previous)))
          (return))
        (line-start previous)
        (move-point start previous)))
    (line-start end)
    (loop
      (with-point ((next end))
        (unless (and (line-offset next 1)
                     (not (lem-yath-blank-line-p next)))
          (return))
        (line-start next)
        (move-point end next)))
    (line-end end)
    (values (copy-point start :temporary)
            (copy-point end :temporary))))

(defun lem-yath-paragraph-text (start end)
  (with-point ((point start))
    (let ((lines '()))
      (loop
        (push (string-trim '(#\Space #\Tab) (line-string point)) lines)
        (unless (and (point< point end) (line-offset point 1))
          (return)))
      (format nil "~{~a~^ ~}" (nreverse lines)))))

(defun lem-yath-line-indentation-string (point)
  (let* ((line (line-string point))
         (trimmed (string-left-trim '(#\Space #\Tab) line)))
    (subseq line 0 (- (length line) (length trimmed)))))

(defun lem-yath-wrap-paragraph-text
    (text indentation &optional (fill-column (lem-yath-buffer-fill-column)))
  (let* ((words (remove "" (cl-ppcre:split "\\s+" text) :test #'string=))
         (width (max 10 (- fill-column (length indentation))))
         (lines '())
         (current ""))
    (dolist (word words)
      (if (or (zerop (length current))
              (<= (+ (length current) 1 (length word)) width))
          (setf current (if (zerop (length current))
                            word
                            (format nil "~a ~a" current word)))
          (progn
            (push current lines)
            (setf current word))))
    (when (plusp (length current))
      (push current lines))
    (format nil "~{~a~^~%~}"
            (mapcar (lambda (line) (concatenate 'string indentation line))
                    (nreverse lines)))))

(define-command lem-yath-fill-paragraph () ()
  "Fill the paragraph around point to `*fill-column*'."
  (multiple-value-bind (start end) (lem-yath-paragraph-bounds)
    (unless start
      (message "No paragraph at point")
      (return-from lem-yath-fill-paragraph))
    (let* ((indentation (lem-yath-line-indentation-string start))
           (replacement
             (lem-yath-wrap-paragraph-text
              (lem-yath-paragraph-text start end)
              indentation))
           (length (- (position-at-point end) (position-at-point start))))
      (delete-character start length)
      (move-point (current-point) start)
      (insert-string (current-point) replacement))))

(define-command lem-yath-toggle-auto-fill () ()
  "Toggle automatic paragraph filling in the current buffer."
  (let ((enabled (not (buffer-value (current-buffer) 'lem-yath-auto-fill))))
    (setf (buffer-value (current-buffer) 'lem-yath-auto-fill) enabled)
    (message "Auto fill ~:[disabled~;enabled~]" enabled)))

(defun auto-fill-after-command ()
  (when (and (buffer-value (current-buffer) 'lem-yath-auto-fill)
             (typep (lem-vi-mode/core:current-state) 'lem-vi-mode:insert)
             (> (point-column (current-point))
                (lem-yath-buffer-fill-column))
             (member (character-at (current-point) -1) '(#\Space #\Tab)))
    (lem-yath-fill-paragraph)))

(add-hook *post-command-hook* 'auto-fill-after-command)
