;;;; Evil-compatible insert-state digraphs.

(in-package :lem-yath)

(defparameter *lem-yath-evil-digraph-count* 1401)

(defun lem-yath-load-evil-digraphs ()
  (let ((path (uiop:getenv "LEM_YATH_EVIL_DIGRAPHS"))
        (table (make-hash-table :test #'equal)))
    (unless (and path (probe-file path))
      (error "LEM_YATH_EVIL_DIGRAPHS does not name a readable table"))
    (with-open-file (stream path :direction :input)
      (loop :for line := (read-line stream nil nil)
            :while line
            :for fields := (uiop:split-string line :separator '(#\Tab))
            :do
               (unless (= 3 (length fields))
                 (error "Malformed Evil digraph row: ~S" line))
               (destructuring-bind (first second replacement) fields
                 (let ((key (cons (code-char (parse-integer first))
                                  (code-char (parse-integer second))))
                       (value (code-char (parse-integer replacement))))
                   (unless (and (car key) (cdr key) value)
                     (error "Unsupported Evil digraph row: ~S" line))
                   (setf (gethash key table) value)))))
    (unless (= *lem-yath-evil-digraph-count* (hash-table-count table))
      (error "Expected ~D effective Evil digraphs, loaded ~D"
             *lem-yath-evil-digraph-count* (hash-table-count table)))
    table))

(defparameter *lem-yath-evil-digraphs* (lem-yath-load-evil-digraphs))

(defun lem-yath-evil-digraph (first second)
  "Return Evil's replacement for FIRST SECOND, including reverse fallback."
  (or (gethash (cons first second) *lem-yath-evil-digraphs*)
      (gethash (cons second first) *lem-yath-evil-digraphs*)))

(defun lem-yath-evil-read-digraph-character (prompt)
  (message-without-log "Digraph: ~A" prompt)
  (redraw-display)
  (let ((key (read-key)))
    (when (lem-core::abort-key-p key)
      (error 'editor-abort))
    (or (lem-core::key-to-char key)
        (editor-error "A digraph requires character keys"))))

(define-command (lem-yath-evil-insert-digraph
                 (:advice-classes editable-advice))
    (&optional (count 1)) (:universal)
  "Read an Evil digraph and insert it COUNT times."
  (unwind-protect
       (let* ((first (lem-yath-evil-read-digraph-character "?"))
              (second (lem-yath-evil-read-digraph-character first))
              (replacement (or (lem-yath-evil-digraph first second) second)))
         (if (typep (lem-vi-mode/core:buffer-state (current-buffer))
                    'lem-vi-mode/states:replace-state)
             (lem-vi-mode:replace-insert-character replacement count)
             (insert-character (current-point) replacement count)))
    (message-without-log "")))

(define-key lem-vi-mode:*insert-keymap* "C-k" 'lem-yath-evil-insert-digraph)
