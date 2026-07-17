;;;; GNU Org and Evil-Org agenda bulk-action dispatch.

(in-package :lem-yath)

(defparameter *agenda-bulk-action-prompt*
  (concatenate
   'string
   "Bulk: [$]archive [A]rch->sib [t]odo [+/-]tag [s]chedule "
   "[d]eadline [r]efile [S]catter [f]unction [q]uit: "))

(defun agenda-bulk-action-target-before-p (left right)
  "Order targets by source file and live source position, like GNU Org."
  (let ((left-file
          (agenda-clock-file-key (agenda-clock-target-file left)))
        (right-file
          (agenda-clock-file-key (agenda-clock-target-file right))))
    (if (string= left-file right-file)
        (< (position-at-point (agenda-clock-target-point left))
           (position-at-point (agenda-clock-target-point right)))
        (string< left-file right-file))))

(defun agenda-bulk-action-targets ()
  "Return writable live targets and whether they came from explicit marks."
  (let* ((marked-p (not (null (agenda-bulk-marks))))
         (targets
           (if marked-p
               (reverse (copy-list (agenda-bulk-marks)))
               (list (agenda-clock-target-from-row)))))
    ;; GNU Org refuses the whole dispatch before prompting when any marker is
    ;; invalid.  Lem additionally checks the source heading and writability.
    (dolist (target targets)
      (agenda-clock-validate-target target t))
    (values (sort targets #'agenda-bulk-action-target-before-p) marked-p)))

(defun agenda-bulk-action-read ()
  "Read one supported GNU bulk action, or NIL when cancelled."
  (let ((character (prompt-for-character *agenda-bulk-action-prompt*)))
    (case character
      ((nil #\Escape #\q #\Q) nil)
      (#\$ :archive)
      (#\t :todo)
      (#\+ :tag-add)
      (#\- :tag-remove)
      (#\s :schedule)
      (#\d :deadline)
      ((#\r #\w) :refile)
      (#\A :archive-sibling)
      (#\S :scatter)
      (#\f :function)
      (#\p :persistent-marks)
      (otherwise (list :invalid character)))))

(defun agenda-bulk-action-unsupported-p (action)
  (member action '(:archive-sibling :scatter :function :persistent-marks)
          :test #'eq))

(defun agenda-bulk-action-tag-items (input known-tags)
  (prescient-filter input known-tags :category :symbol))

(defun agenda-bulk-action-read-tag (verb)
  "Read one valid Org tag to add or remove."
  (let* ((known-tags (agenda-known-tags))
         (input
           (prompt-for-string
            (format nil "Tag to ~a: " verb)
            :completion-function
            (lambda (value)
              (agenda-bulk-action-tag-items value known-tags))
            :test-function
            (lambda (value)
              (= 1 (length (agenda-normalize-tags value))))
            :history-symbol 'lem-yath-agenda-bulk-tags))
         (tags (agenda-normalize-tags input)))
    (unless (= 1 (length tags))
      (error "Bulk action requires exactly one tag"))
    (first tags)))

(defun agenda-bulk-action-read-todo-state ()
  "Read one configured TODO keyword through GNU Org-style completion."
  (let* ((states
           (remove-duplicates (mapcar #'cdr *agenda-todo-fast-keys*)
                              :test #'string=))
         (state
           (prompt-for-string
            "Todo state: "
            :completion-function
            (lambda (input)
              (prescient-filter input states :category :symbol))
            :test-function
            (lambda (input) (find input states :test #'string=))
            :history-symbol 'lem-yath-agenda-bulk-todo-states)))
    (or (find state states :test #'string=)
        (error "Unknown TODO state: ~a" state))))

(defun agenda-bulk-action-target-source (target)
  "Return TARGET's live file, line, and exact heading text."
  (let ((point (agenda-clock-validate-target target t)))
    (values (agenda-clock-target-file target)
            (line-number-at-point point)
            (line-string point))))

(defun agenda-bulk-action-apply-todo (target state)
  (let ((restore-key (agenda-clock-target-entry-key target)))
    (multiple-value-bind (file line heading)
        (agenda-bulk-action-target-source target)
      (agenda-set-source-todo file line heading state))
    restore-key))

(defun agenda-bulk-action-apply-tag (target tag add-p)
  (let ((restore-key (agenda-clock-target-entry-key target)))
    (multiple-value-bind (file line heading)
        (agenda-bulk-action-target-source target)
      (let* ((old-tags (agenda-heading-tags heading))
             (new-tags
               (if add-p
                   (if (member tag old-tags :test #'string=)
                       old-tags
                       (append old-tags (list tag)))
                   (remove tag old-tags :test #'string=))))
        (agenda-set-source-tags file line heading new-tags)))
    restore-key))

(defun agenda-bulk-action-apply-planning (target kind date)
  (multiple-value-bind (file line heading)
      (agenda-bulk-action-target-source target)
    (multiple-value-bind (old-date old-extra)
        (agenda-source-planning-components file line heading kind)
      (multiple-value-bind (result restore-key)
          (agenda-apply-source-planning
           file line heading kind old-date old-extra :set :date date)
        (declare (ignore result))
        restore-key))))

(defun agenda-bulk-action-apply-archive (target)
  (multiple-value-bind (file line heading)
      (agenda-bulk-action-target-source target)
    (agenda-archive-source-subtree file line heading))
  nil)

(defun agenda-bulk-action-map (targets function)
  "Apply FUNCTION to still-live TARGETS, returning counts and a restore key."
  (let ((processed 0)
        (skipped 0)
        (restore-key nil))
    (dolist (target targets)
      (if (agenda-clock-target-valid-p target t)
          (let ((candidate (funcall function target)))
            (unless restore-key (setf restore-key candidate))
            (incf processed))
          (incf skipped)))
    (values processed skipped restore-key)))

(defun agenda-bulk-action-refile-files (targets)
  (remove-duplicates
   (mapcar #'agenda-clock-target-file targets)
   :test #'uiop:pathname-equal))

(defun agenda-bulk-action-refile-target (targets)
  "Prompt once for the configured same-file level-one refile target."
  (let ((files (agenda-bulk-action-refile-files targets)))
    (unless (= 1 (length files))
      (error "Bulk refile across agenda files is not supported"))
    (let* ((file (first files))
           (buffer (find-file-buffer file))
           (source (agenda-clock-validate-target (first targets) t))
           (source-title (agenda-refile-heading-title (line-string source)))
           (choices (with-current-buffer buffer
                      (agenda-refile-targets buffer))))
      (unless choices (error "No same-file level-one refile targets"))
      (alexandria:when-let
          ((target (agenda-read-refile-target source-title choices)))
        (with-current-buffer buffer
          (agenda-refile-find-target buffer target))))))

(defun agenda-bulk-action-refile-preflight (targets destination)
  "Refuse a destination inside any selected source before moving anything."
  (dolist (target targets)
    (let* ((source (agenda-clock-validate-target target t))
           (end (org-subtree-end-point source)))
      (when (and (not (point< destination source))
                 (point< destination end))
        (error "Cannot refile to a position inside a selected subtree")))))

(defun agenda-bulk-action-apply-refile (targets)
  "Move TARGETS below one same-file level-one heading."
  (alexandria:if-let ((destination
                       (agenda-bulk-action-refile-target targets)))
    (unwind-protect
         (progn
           (agenda-bulk-action-refile-preflight targets destination)
           (agenda-bulk-action-map
            targets
            (lambda (target)
              (multiple-value-bind (file line heading)
                  (agenda-bulk-action-target-source target)
                (let* ((entry-key (agenda-clock-target-entry-key target))
                       (refile-target
                         (make-agenda-refile-target
                          :title (agenda-refile-heading-title
                                  (line-string destination))
                          :line (line-number-at-point destination)
                          :heading (line-string destination)))
                       (new-line
                         (agenda-refile-source-subtree
                          file line heading refile-target)))
                  (agenda-refile-restored-key entry-key file new-line))))))
      (delete-point destination))
    (values 0 0 nil)))

(defun agenda-bulk-action-perform (action targets)
  "Prompt for ACTION's shared value and apply it to TARGETS."
  (case action
    (:todo
     (let ((state (agenda-bulk-action-read-todo-state)))
       (agenda-bulk-action-map
        targets
        (lambda (target)
          (agenda-bulk-action-apply-todo target state)))))
    (:tag-add
     (let ((tag (agenda-bulk-action-read-tag "add")))
       (agenda-bulk-action-map
        targets
        (lambda (target)
          (agenda-bulk-action-apply-tag target tag t)))))
    (:tag-remove
     (let ((tag (agenda-bulk-action-read-tag "remove")))
       (agenda-bulk-action-map
        targets
        (lambda (target)
          (agenda-bulk-action-apply-tag target tag nil)))))
    ((:schedule :deadline)
     (let* ((schedule-p (eq action :schedule))
            (kind (if schedule-p "SCHEDULED" "DEADLINE"))
            (label (if schedule-p "Schedule date" "Deadline date")))
       (multiple-value-bind (date selected-p)
           (agenda-read-date label)
         (if selected-p
             (agenda-bulk-action-map
              targets
              (lambda (target)
                (agenda-bulk-action-apply-planning target kind date)))
             (values 0 0 nil)))))
    (:archive
     (agenda-bulk-action-map targets #'agenda-bulk-action-apply-archive))
    (:refile
     (agenda-bulk-action-apply-refile targets))
    (otherwise (values 0 0 nil))))

(defun agenda-bulk-action-result-message (processed skipped)
  (message "Acted on ~d ~a~a"
           processed
           (if (= processed 1) "entry" "entries")
           (if (plusp skipped)
               (format nil ", skipped ~d" skipped)
               "")))

(define-command lem-yath-agenda-bulk-action () ()
  "Dispatch one GNU Org action across marked entries or the current row."
  (let ((agenda-buffer (current-buffer))
        (temporary-targets-p nil)
        (targets nil))
    (unwind-protect
         (handler-case
             (multiple-value-bind (selected-targets marked-p)
                 (agenda-bulk-action-targets)
               (setf targets selected-targets
                     temporary-targets-p (not marked-p))
               (alexandria:when-let ((action (agenda-bulk-action-read)))
                 (cond
                   ((consp action)
                    (message "Invalid bulk action: ~a; marks kept"
                             (second action)))
                   ((agenda-bulk-action-unsupported-p action)
                    (message "Bulk action ~a is not supported; marks kept"
                             action))
                   (t
                    (multiple-value-bind (processed skipped restore-key)
                        (agenda-bulk-action-perform action targets)
                      (when (plusp processed)
                        (unless temporary-targets-p
                          (agenda-bulk-clear agenda-buffer nil))
                        (setf (buffer-value agenda-buffer
                                            'lem-yath-agenda-restore-entry)
                              restore-key)
                        (agenda-start-scan agenda-buffer)
                        (agenda-bulk-action-result-message
                         processed skipped)))))))
           (error (condition)
             (message "Agenda bulk action failed: ~a" condition)))
      (when temporary-targets-p
        (dolist (target targets)
          (agenda-clock-delete-target target))))))

;; Evil-Org shadows GNU Org's base B with x in motion state.
(define-key *lem-yath-agenda-vi-keymap* "x" 'lem-yath-agenda-bulk-action)
(define-key *lem-yath-agenda-mode-keymap* "B" 'lem-yath-agenda-bulk-action)
