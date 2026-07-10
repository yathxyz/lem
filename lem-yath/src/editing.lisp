;;;; Editing defaults. Emacs side: indent-tabs-mode nil, tab-width 4,
;;;; ws-butler (trim trailing whitespace on save), raised undo limits.

(in-package :lem-yath)

(setf (variable-value 'tab-width :global) 4)

;;; ws-butler approximation: trim trailing whitespace across the buffer on
;;; save (ws-butler restricted itself to touched lines; Lem has no
;;; per-line change tracking to lean on, so we trim the whole buffer).

(defvar *trim-trailing-whitespace* t)
(defparameter *fill-column* 80)

(defun trim-trailing-whitespace (buffer)
  (when (and *trim-trailing-whitespace*
             (buffer-filename buffer))
    (with-point ((p (buffer-start-point buffer) :left-inserting))
      (loop
        (line-end p)
        (loop :while (member (character-at p -1) '(#\Space #\Tab))
              :do (progn (character-offset p -1)
                         (delete-character p 1)))
        (unless (line-offset p 1)
          (return))))))

(defun trim-trailing-whitespace-hook (&rest args)
  (let ((buffer (or (first args) (current-buffer))))
    (when (typep buffer 'lem:buffer)
      (ignore-errors (trim-trailing-whitespace buffer)))))

(add-hook (variable-value 'before-save-hook :global t)
          'trim-trailing-whitespace-hook)

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

(defun lem-yath-wrap-paragraph-text (text indentation)
  (let* ((words (remove "" (cl-ppcre:split "\\s+" text) :test #'string=))
         (width (max 10 (- *fill-column* (length indentation))))
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
             (> (point-column (current-point)) *fill-column*)
             (member (character-at (current-point) -1) '(#\Space #\Tab)))
    (lem-yath-fill-paragraph)))

(add-hook *post-command-hook* 'auto-fill-after-command)
