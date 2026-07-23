;;;; Host-gated projection of saved Org files through the external
;;;; nodes-org-sync command.  Database parsing and writes remain owned by the
;;;; separately packaged projector from the Nix configuration.

(in-package :lem-yath)

(defvar *org-nodes-sync-enabled* t
  "Whether eligible Org saves may invoke nodes-org-sync.")

(defun org-nodes-sync-configured-hosts ()
  (let ((configured (uiop:getenv "YATH_NODES_SYNC_HOSTS")))
    (if (and configured (plusp (length configured)))
        (remove-if (lambda (host) (zerop (length host)))
                   (uiop:split-string configured :separator '(#\:)))
        '("nova"))))

(defvar *org-nodes-sync-hosts* (org-nodes-sync-configured-hosts)
  "Unqualified hostnames allowed to publish Org data into the nodes graph.")
(defvar *org-nodes-sync-command* "nodes-org-sync")
(defvar *org-nodes-auto-id-enabled* nil
  "Whether saving should add IDs to actionable headings before writing.")
(defvar *org-nodes-reading-files*
  '("readlist.org" "reading.org" "reading-list.org"))

(defparameter *org-nodes-sync-output-buffer-name* "*nodes-org-sync*")
(defparameter *org-nodes-sync-output-limit* (* 1024 1024))
(defparameter *org-nodes-sync-timeout* 300)
(defparameter *org-nodes-sync-conflict-scanner*
  (cl-ppcre:create-scanner
   "(?i)\\.sync-conflict-[^/]+\\.(?:org|markdown|md)$"))

(defvar *org-nodes-sync-generation* 0)

(defun org-nodes-short-hostname ()
  "Return this machine's lower-case, unqualified host name."
  (let* ((name (string-downcase (machine-instance)))
         (dot (position #\. name)))
    (subseq name 0 dot)))

(defun org-nodes-sync-host-allowed-p ()
  (member (org-nodes-short-hostname) *org-nodes-sync-hosts*
          :test #'string-equal))

(defun org-nodes-sync-conflict-file-p (pathname)
  (and pathname
       (cl-ppcre:scan *org-nodes-sync-conflict-scanner*
                      (uiop:native-namestring pathname))))

(defun org-nodes-sync-executable ()
  "Resolve the configured command name or explicit pathname."
  (if (find #\/ *org-nodes-sync-command*)
      (ignore-errors (uiop:probe-file* *org-nodes-sync-command*))
      (executable-find *org-nodes-sync-command*)))

(defun org-nodes-sync-org-buffer-p (buffer)
  (eq (buffer-major-mode buffer) 'org-mode))

(defun org-nodes-sync-eligible-path (buffer)
  "Return BUFFER's canonical eligible Org path, or NIL."
  (when (and *org-nodes-sync-enabled*
             (org-nodes-sync-host-allowed-p)
             (org-nodes-sync-org-buffer-p buffer))
    (alexandria:when-let* ((filename (buffer-filename buffer))
                           (pathname (ignore-errors (truename filename))))
      (when (and (string-equal (or (pathname-type pathname) "") "org")
                 (not (org-nodes-sync-conflict-file-p pathname))
                 (project-path-in-directory-p pathname (workdir)))
        pathname))))

(defun org-nodes-heading-planning-p (heading)
  (let ((end (org-section-end-point heading)))
    (with-point ((point heading))
      (loop :while (and (line-offset point 1) (point< point end))
            :thereis (and (not (org-inside-block-p point))
                          (cl-ppcre:scan
                           "(?i)^\\s*(?:SCHEDULED|DEADLINE):"
                           (line-string point)))))))

(defun org-nodes-reading-heading-p (heading buffer todo)
  (or (cl-ppcre:scan "(?i):(?:reading|readlist):"
                     (line-string heading))
      (and todo
           (alexandria:when-let ((filename (buffer-filename buffer)))
             (member (string-downcase (file-namestring filename))
                     *org-nodes-reading-files* :test #'string=)))))

(defun org-nodes-actionable-heading-p (heading buffer)
  (multiple-value-bind (start end todo) (org-heading-todo-bounds heading)
    (declare (ignore start end))
    (or todo
        (org-nodes-heading-planning-p heading)
        (org-nodes-reading-heading-p heading buffer todo))))

(defun org-nodes-ensure-actionable-heading-ids-in-buffer (buffer)
  "Add missing IDs to actionable headings in BUFFER and return the count."
  (let ((created 0))
    (save-excursion
      (setf (current-buffer) buffer)
      ;; Work backward so inserting a drawer cannot invalidate the remaining
      ;; temporary heading points.
      (dolist (heading (reverse (org-all-heading-points buffer)))
        (when (org-nodes-actionable-heading-p heading buffer)
          (multiple-value-bind (id created-p)
              (org-id-get-create-at-heading heading)
            (declare (ignore id))
            (when created-p (incf created))))))
    created))

(defun org-nodes-ensure-actionable-heading-ids
    (&optional (buffer (current-buffer)) force)
  "Add stable IDs under the configured host/path policy.
When FORCE is true, do not require the automatic-ID preference."
  (when (and (or force *org-nodes-auto-id-enabled*)
             (org-nodes-sync-eligible-path buffer))
    (org-nodes-ensure-actionable-heading-ids-in-buffer buffer)))

(define-command lem-yath-org-nodes-ensure-actionable-heading-ids () ()
  "Manually add IDs to actionable headings in this eligible Org file."
  (let ((count (org-nodes-ensure-actionable-heading-ids
                (current-buffer) t)))
    (if count
        (message "Created ~d actionable Org ID~:p" count)
        (message "This buffer is not eligible for nodes sync"))))

(defun org-nodes-sync-clean-output (text)
  (with-output-to-string (stream)
    (loop :for character :across (or text "")
          :when (or (member character '(#\Newline #\Return #\Tab))
                    (>= (char-code character) 32))
            :do (write-char character stream))))

(defun org-nodes-sync-publish-result
    (source-buffer generation pathname stdout stderr status condition)
  (let* ((success-p (and (null condition) (integerp status) (zerop status)))
         (details
           (string-trim
            '(#\Space #\Tab #\Newline #\Return)
            (org-nodes-sync-clean-output
             (format nil "~@[~a~%~]~@[~a~%~]~@[~a~]"
                     (and (plusp (length stdout)) stdout)
                     (and (plusp (length stderr)) stderr)
                     condition)))))
    (send-event
     (lambda ()
       (when (and source-buffer (not (deleted-buffer-p source-buffer))
                  (eql generation
                       (buffer-value source-buffer
                                     'lem-yath-org-nodes-sync-generation)))
         (setf (buffer-value source-buffer
                             'lem-yath-org-nodes-sync-last-status)
               (if success-p :succeeded :failed)))
       (unless success-p
         (let ((output-buffer
                 (make-buffer *org-nodes-sync-output-buffer-name*)))
           (insert-string
            (buffer-end-point output-buffer)
            (format nil "~&nodes-org-sync failed for ~a~%~a~2%"
                    (uiop:native-namestring pathname)
                    (if (plusp (length details)) details
                        (format nil "exit status ~a" status))))
           (message "nodes-org-sync failed for ~a; see ~a"
                    (uiop:native-namestring pathname)
                    *org-nodes-sync-output-buffer-name*)))
       (redraw-display)))))

(defun org-nodes-sync-start (buffer pathname executable)
  (let ((generation (incf *org-nodes-sync-generation*))
        (arguments (list (uiop:native-namestring executable)
                         "--quiet" "--file"
                         (uiop:native-namestring pathname))))
    (setf (buffer-value buffer 'lem-yath-org-nodes-sync-generation) generation
          (buffer-value buffer 'lem-yath-org-nodes-sync-last-status) :running)
    (bt2:make-thread
     (lambda ()
       (let ((stdout "") (stderr "") (status nil) (failure nil)
             (*project-process-timeout* *org-nodes-sync-timeout*))
         (handler-case
             (multiple-value-setq (stdout stderr status)
               (run-project-program
                arguments :output-limit *org-nodes-sync-output-limit*))
           (error (condition) (setf failure condition)))
         (org-nodes-sync-publish-result
          buffer generation pathname stdout stderr status failure)))
     :name "lem-yath/nodes-org-sync")
    t))

(defun org-nodes-sync-current-file (&optional (buffer (current-buffer)))
  "Asynchronously project BUFFER through the configured external command."
  (alexandria:when-let* ((pathname (org-nodes-sync-eligible-path buffer))
                         (executable (org-nodes-sync-executable)))
    (org-nodes-sync-start buffer pathname executable)))

(define-command lem-yath-org-nodes-sync-current-file () ()
  "Manually sync the current eligible Org file."
  (unless (org-nodes-sync-current-file (current-buffer))
    (message "This buffer is not eligible for nodes sync, or the command is unavailable")))

(defun org-nodes-before-save (&optional (buffer (current-buffer)))
  (org-nodes-ensure-actionable-heading-ids buffer nil))

(defun org-nodes-after-save (&optional (buffer (current-buffer)))
  (org-nodes-sync-current-file buffer))

(defun org-nodes-sync-setup-buffer (&optional (buffer (current-buffer)))
  "Install the two buffer-local save hooks idempotently."
  (remove-hook (variable-value 'before-save-hook :buffer buffer)
               'org-nodes-before-save)
  (remove-hook (variable-value 'after-save-hook :buffer buffer)
               'org-nodes-after-save)
  (add-hook (variable-value 'before-save-hook :buffer buffer)
            'org-nodes-before-save)
  (add-hook (variable-value 'after-save-hook :buffer buffer)
            'org-nodes-after-save))

(defun org-nodes-sync-reload ()
  (remove-hook *org-mode-hook* 'org-nodes-sync-setup-buffer)
  (add-hook *org-mode-hook* 'org-nodes-sync-setup-buffer)
  (dolist (buffer (buffer-list))
    (when (org-nodes-sync-org-buffer-p buffer)
      (org-nodes-sync-setup-buffer buffer))))

(org-nodes-sync-reload)
