(in-package :lem-yath)

(defvar *jj-porcelain-test-report*
  (uiop:getenv "LEM_YATH_JJ_PORCELAIN_REPORT"))
(defvar *jj-porcelain-test-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_JJ_PORCELAIN_ROOT")))
(defvar *jj-porcelain-test-source-buffer* (current-buffer))

(defun jj-porcelain-test-yes-no (value)
  (if value "yes" "no"))

(defun jj-porcelain-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (#\Space (write-char #\_ stream))
                (otherwise (write-char character stream))))))

(defun jj-porcelain-test-key-command (keys)
  (alexandria:when-let
      ((prefix
         (lem-core::keymap-find *lem-yath-jj-view-keymap*
                                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun jj-porcelain-test-keys-p ()
  (every
   (lambda (binding)
     (eq (second binding)
         (jj-porcelain-test-key-command (first binding))))
   '(("c" lem-yath-jj-describe)
     ("C" lem-yath-jj-commit)
     ("o" lem-yath-jj-new)
     ("O" lem-yath-jj-new-dwim)
     ("I" lem-yath-jj-new-before)
     ("A" lem-yath-jj-new-after)
     ("s" lem-yath-jj-squash)
     ("S" lem-yath-jj-split)
     ("r" lem-yath-jj-rebase)
     ("_" lem-yath-jj-revert)
     ("y" lem-yath-jj-duplicate)
     ("Y" lem-yath-jj-duplicate-dwim)
     ("b" lem-yath-jj-bookmark)
     ("e" lem-yath-jj-edit)
     ("u" lem-yath-jj-undo)
     ("C-r" lem-yath-jj-redo)
     ("x" lem-yath-jj-abandon)
     ("d" lem-yath-jj-show)
     ("Return" lem-yath-jj-show)
     ("C-j" lem-yath-jj-next-revision)
     ("C-k" lem-yath-jj-previous-revision)
     ("g r" lem-yath-jj-refresh)
     ("g j" lem-yath-jj-next-revision)
     ("g k" lem-yath-jj-previous-revision)
     ("." lem-yath-jj-goto-working-copy)
     ("[" lem-yath-jj-goto-parent)
     ("]" lem-yath-jj-goto-child)
     ("?" lem-yath-jj-help)
     ("q" lem-yath-jj-quit))))

(defun jj-porcelain-test-split-key-command (keys)
  (alexandria:when-let
      ((prefix
         (lem-core::keymap-find *lem-yath-jj-split-mode-keymap*
                                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun jj-porcelain-test-split-keys-p ()
  (every
   (lambda (binding)
     (eq (second binding)
         (jj-porcelain-test-split-key-command (first binding))))
   '(("H" lem-yath-jj-split-toggle-hunk)
     ("Space" lem-yath-jj-split-toggle-hunk)
     ("F" lem-yath-jj-split-toggle-file)
     ("R" lem-yath-jj-split-toggle-region)
     ("C" lem-yath-jj-split-clear)
     ("C-j" lem-yath-jj-split-next-hunk)
     ("C-k" lem-yath-jj-split-previous-hunk)
     ("o" lem-yath-jj-split-onto)
     ("a" lem-yath-jj-split-after)
     ("b" lem-yath-jj-split-before)
     ("c" lem-yath-jj-split-parent)
     ("p" lem-yath-jj-split-toggle-parallel)
     ("s" lem-yath-jj-split-execute)
     ("Return" lem-yath-jj-split-execute)
     ("q" lem-yath-jj-split-cancel))))

(defun jj-porcelain-test-message-key-command (keys)
  (alexandria:when-let
      ((prefix
         (lem-core::keymap-find *lem-yath-jj-message-mode-keymap*
                                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun jj-porcelain-test-message-keys-p ()
  (and
   (eq 'lem-yath-jj-message-finish
       (jj-porcelain-test-message-key-command "C-c C-c"))
   (eq 'lem-yath-jj-message-abort
       (jj-porcelain-test-message-key-command "C-c C-k"))))

(defun jj-porcelain-test-row-count (buffer)
  (with-point ((point (buffer-start-point buffer)))
    (loop :with count := 0
          :do (when (jj-row-revision point) (incf count))
          :while (line-offset point 1)
          :finally (return count))))

(define-command lem-yath-jj-porcelain-test-report () ()
  (let* ((buffer (current-buffer))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (kind (buffer-value buffer *lem-yath-jj-view-kind-key*))
         (row (jj-row-revision))
         (revision
           (or row
               (and (eq kind :show)
                    (buffer-value buffer *lem-yath-jj-revision-key*))))
         (description
           (and root revision
                (ignore-errors (jj-description root revision)))))
    (with-open-file (stream *jj-porcelain-test-report*
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (format
       stream
       "STATE kind=~a row=~a description=~a rows=~d root=~a read-only=~a mode=~a keys=~a source=~a source-live=~a~%"
       (if kind (string-downcase (symbol-name kind)) "none")
       (jj-porcelain-test-yes-no row)
       (if description (jj-porcelain-test-encode description) "none")
       (if (eq kind :log) (jj-porcelain-test-row-count buffer) 0)
       (jj-porcelain-test-yes-no
        (and root
             (ignore-errors
               (equal (truename root)
                      (truename *jj-porcelain-test-root*)))))
       (jj-porcelain-test-yes-no (buffer-read-only-p buffer))
       (jj-porcelain-test-yes-no
        (mode-active-p buffer 'lem-yath-jj-view-mode))
       (jj-porcelain-test-yes-no (jj-porcelain-test-keys-p))
       (jj-porcelain-test-yes-no
        (eq buffer *jj-porcelain-test-source-buffer*))
       (jj-porcelain-test-yes-no
       (not (deleted-buffer-p *jj-porcelain-test-source-buffer*)))))))

(define-command lem-yath-jj-porcelain-test-split-report () ()
  (let* ((buffer (current-buffer))
         (hunks (buffer-value buffer *lem-yath-jj-split-hunks-key*))
         (selected (and hunks (jj-split-selected-count hunks)))
         (partial
           (and hunks
                (count-if (lambda (hunk)
                            (consp (jj-split-hunk-selection hunk)))
                          hunks)))
         (placement
           (buffer-value buffer *lem-yath-jj-split-placement-key*)))
    (with-open-file (stream *jj-porcelain-test-report*
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (format
       stream
       "SPLIT kind=~a hunks=~d selected=~d partial=~d row=~a keys=~a placement=~a parallel=~a~%"
       (if (eq :split (buffer-value buffer *lem-yath-jj-view-kind-key*))
           "split"
           "other")
       (length hunks)
       (or selected 0)
       (or partial 0)
       (jj-porcelain-test-yes-no (jj-split-hunk-at-point))
       (jj-porcelain-test-yes-no (jj-porcelain-test-split-keys-p))
       (if placement (string-downcase (symbol-name placement)) "parent")
       (jj-porcelain-test-yes-no
       (buffer-value buffer *lem-yath-jj-split-parallel-key*))))))

(define-command lem-yath-jj-porcelain-test-message-report () ()
  (let* ((buffer (current-buffer))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (revision (buffer-value buffer *lem-yath-jj-revision-key*))
         (action (buffer-value buffer *lem-yath-jj-message-action-key*))
         (origin (buffer-value buffer *lem-yath-jj-message-origin-key*)))
    (with-open-file (stream *jj-porcelain-test-report*
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (format
       stream
       "MESSAGE action=~a revision=~a root=~a mode=~a keys=~a origin=~a row=~a modified=~a content=~a~%"
       (if action (string-downcase (symbol-name action)) "none")
       (if revision revision "none")
       (jj-porcelain-test-yes-no
        (and root
             (ignore-errors
               (equal (truename root)
                      (truename *jj-porcelain-test-root*)))))
       (jj-porcelain-test-yes-no
        (eq (buffer-major-mode buffer) 'lem-yath-jj-message-mode))
       (jj-porcelain-test-yes-no (jj-porcelain-test-message-keys-p))
       (jj-porcelain-test-yes-no
        (and origin (not (deleted-buffer-p origin))))
       (jj-porcelain-test-yes-no
        (and origin
             (not (deleted-buffer-p origin))
             (save-excursion
               (setf (current-buffer) origin)
               (jj-row-revision))))
       (jj-porcelain-test-yes-no (buffer-modified-p buffer))
       (jj-porcelain-test-encode (buffer-text buffer))))))

(define-key *global-keymap* "F1" 'lem-yath-jj-porcelain-test-report)
(define-key *global-keymap* "F2" 'lem-yath-jj-porcelain-test-split-report)
(define-key *global-keymap* "F3" 'lem-yath-jj-porcelain-test-message-report)
