;;;; Editing defaults. Emacs side: indent-tabs-mode nil, tab-width 4,
;;;; ws-butler (trim trailing whitespace on save), raised undo limits.

(in-package :lem-yath)

(setf (variable-value 'tab-width :global) 4)

;;; ws-butler approximation: trim trailing whitespace across the buffer on
;;; save (ws-butler restricted itself to touched lines; Lem has no
;;; per-line change tracking to lean on, so we trim the whole buffer).

(defvar *trim-trailing-whitespace* t)

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
