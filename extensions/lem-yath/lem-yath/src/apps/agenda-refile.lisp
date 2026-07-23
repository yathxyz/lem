;;;; Same-file default Org refiling from the bounded agenda view.

(in-package :lem-yath)

(defstruct (agenda-refile-target (:constructor make-agenda-refile-target))
  title line heading)

(defun agenda-refile-link-display-format (title)
  "Replace ordinary bracket links in TITLE with their Org display text."
  (with-output-to-string (stream)
    (let ((offset 0))
      (ppcre:do-scans
          (start end register-starts register-ends
           "\\[\\[([^]\\n]+)\\](?:\\[([^]\\n]*)\\])?\\]" title)
        (write-string title stream :start offset :end start)
        (let ((description-start (aref register-starts 1)))
          (if description-start
              (write-string title stream
                            :start description-start
                            :end (aref register-ends 1))
              (write-string title stream
                            :start (aref register-starts 0)
                            :end (aref register-ends 0))))
        (setf offset end))
      (write-string title stream :start offset))))

(defun agenda-refile-heading-title (line)
  "Return GNU Org's normalized completion label for heading LINE."
  (multiple-value-bind (level title tags) (roam-org-heading-fields line)
    (declare (ignore level tags))
    (agenda-refile-link-display-format title)))

(defun agenda-refile-targets (buffer)
  "Return BUFFER's level-one headings in source order.

This is the active Emacs default, equivalent to
`org-refile-targets = ((nil . (:level . 1)))'."
  (let ((targets '())
        (open-block nil))
    (with-point ((point (buffer-start-point buffer)))
      (loop :for line-number :from 1
            :for line := (line-string point)
            :for marker := (org-block-marker line)
            :do (cond
                  (open-block
                   (when (and marker (eq (car marker) :end)
                              (string= (cdr marker) open-block))
                     (setf open-block nil)))
                  ((and marker (eq (car marker) :begin))
                   (setf open-block (cdr marker)))
                  ((eql 1 (org-heading-level-from-line line))
                   (push (make-agenda-refile-target
                          :title (agenda-refile-heading-title line)
                          :line line-number
                          :heading line)
                         targets)))
            :unless (line-offset point 1) :do (return)))
    (nreverse targets)))

(defun agenda-refile-validate-source (buffer line expected-heading)
  "Return the exact source heading at LINE or signal without editing."
  (with-point ((heading (buffer-start-point buffer)))
    (unless (or (= line 1) (line-offset heading (1- line)))
      (error "Agenda source line no longer exists; refresh the agenda"))
    (unless (string= expected-heading (line-string heading))
      (error "Agenda source changed; refresh before refiling"))
    (unless (org-heading-line-p heading)
      (error "Agenda row no longer names an Org subtree"))
    (copy-point heading :temporary)))

(defun agenda-refile-target-labels (targets)
  "Return unique target labels while preserving file order."
  (remove-duplicates (mapcar #'agenda-refile-target-title targets)
                     :test #'string-equal :from-end t))

(defun agenda-read-refile-target (source-title targets)
  "Prompt for an existing member of TARGETS, returning its first match."
  (let* ((labels (agenda-refile-target-labels targets))
         (selection
           (prompt-for-string
            (format nil "Refile subtree \"~a\" to: " source-title)
            :completion-function
            (lambda (input) (prescient-filter input labels :category :symbol))
            :test-function
            (lambda (input) (find input labels :test #'string-equal))
            :history-symbol 'lem-yath-agenda-refile-targets)))
    (find selection targets :key #'agenda-refile-target-title
                            :test #'string-equal)))

(defun agenda-refile-find-target (buffer target)
  "Return TARGET's still-exact level-one heading in BUFFER."
  (with-point ((heading (buffer-start-point buffer)))
    (unless (or (= 1 (agenda-refile-target-line target))
                (line-offset heading (1- (agenda-refile-target-line target))))
      (error "Refile target line no longer exists; choose again"))
    (unless (and (string= (agenda-refile-target-heading target)
                          (line-string heading))
                 (eql 1 (org-heading-level-at heading)))
      (error "Refile target changed; choose again"))
    (copy-point heading :right-inserting)))

(defun agenda-refile-entry-text (subtree root-level target-level)
  "Return SUBTREE adjusted as a child of TARGET-LEVEL."
  (format nil "~{~a~%~}"
          (agenda-adjust-subtree-level-lines
           subtree root-level (1+ target-level))))

(defun agenda-refile-restore-buffer (buffer text originally-modified-p)
  "Restore BUFFER to TEXT after a failed same-file transaction."
  (org-clear-folds buffer)
  (erase-buffer buffer)
  (insert-string (buffer-start-point buffer) text)
  (unless originally-modified-p (buffer-mark-saved buffer)))

(defun agenda-refile-source-subtree
    (file line expected-heading target)
  "Move one exact source subtree below same-file TARGET and save.

Return the moved heading's new source line."
  (unless (and file (integerp line) (plusp line) expected-heading target)
    (error "No mutable agenda heading on this line"))
  (let ((buffer (find-file-buffer file)))
    (with-current-buffer buffer
      (when (buffer-read-only-p buffer)
        (error "Agenda source is read-only: ~a" file))
      (let* ((source (agenda-refile-validate-source
                      buffer line expected-heading))
             (target-point (agenda-refile-find-target buffer target))
             (source-end (org-subtree-end-point source))
             (root-level (org-heading-level-at source))
             (target-level (org-heading-level-at target-point)))
        (when (and (not (point< target-point source))
                   (point< target-point source-end))
          (error "Cannot refile to a position inside the source subtree"))
        (let* ((subtree (points-to-string source source-end))
               (entry (agenda-refile-entry-text
                       subtree root-level target-level))
               (original-text
                 (points-to-string (buffer-start-point buffer)
                                   (buffer-end-point buffer)))
               (originally-modified-p (buffer-modified-p buffer)))
          (handler-case
              (progn
                (agenda-undo-track-buffer buffer)
                (org-clear-folds buffer)
                (delete-between-points source source-end)
                (let ((insertion (org-subtree-end-point target-point)))
                  (unless (start-line-p insertion)
                    (insert-character insertion #\Newline))
                  (let ((new-line (line-number-at-point insertion)))
                    (insert-string insertion entry)
                    ;; The Emacs configuration advises `org-agenda-refile' to
                    ;; persist the modified agenda source immediately.
                    (save-buffer buffer)
                    new-line)))
            (error (condition)
              (agenda-refile-restore-buffer
               buffer original-text originally-modified-p)
              (error condition))))))))

(defun agenda-refile-restored-key (entry-key file line)
  "Return ENTRY-KEY with its source FILE and LINE updated."
  (when entry-key
    (list file line
          (third entry-key)
          (fourth entry-key)
          (fifth entry-key)
          (sixth entry-key)
          (seventh entry-key))))

(define-command lem-yath-agenda-refile () ()
  "Refile the current agenda subtree under a same-file level-one heading."
  (let* ((agenda-buffer (current-buffer))
         (entry-key (agenda-entry-key-at-point (current-point)))
         (file (text-property-at (current-point) :agenda-file))
         (line (text-property-at (current-point) :agenda-line))
         (heading (text-property-at (current-point) :agenda-heading)))
    (if (null file)
        (message "No agenda entry on this line.")
        (handler-case
            (let* ((source-buffer (find-file-buffer file))
                   (source
                     (with-current-buffer source-buffer
                       (when (buffer-read-only-p source-buffer)
                         (error "Agenda source is read-only: ~a" file))
                       (agenda-refile-validate-source
                        source-buffer line heading)))
                   (source-title
                     (agenda-refile-heading-title (line-string source)))
                   (targets
                     (with-current-buffer source-buffer
                       (agenda-refile-targets source-buffer))))
              (unless targets (error "No same-file level-one refile targets"))
              (alexandria:when-let
                  ((target (agenda-read-refile-target source-title targets)))
                (let ((new-line
                        (with-agenda-undo-transaction
                            (agenda-buffer "org-agenda-refile" entry-key)
                          (agenda-refile-source-subtree
                           file line heading target))))
                  (setf (buffer-value agenda-buffer
                                      'lem-yath-agenda-restore-entry)
                        (agenda-refile-restored-key entry-key file new-line))
                  (agenda-start-scan agenda-buffer)
                  (message "Refile to \"~a\": done"
                           (agenda-refile-target-title target)))))
          (error (condition)
            (message "Agenda refile failed: ~a" condition))))))

;; GNU Org exposes refile from agenda on C-c C-w.  Evil-Org does not add a
;; normal-state refile binding, so the GNU chord is the parity surface here.
(define-key *lem-yath-agenda-vi-keymap* "C-c C-w" 'lem-yath-agenda-refile)
(define-key *lem-yath-agenda-mode-keymap* "C-c C-w" 'lem-yath-agenda-refile)
