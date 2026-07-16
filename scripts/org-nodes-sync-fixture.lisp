(in-package :lem-yath)

(defun org-nodes-test-env (name)
  (or (uiop:getenv name) (error "~a is unset" name)))

(defun org-nodes-test-log (control &rest arguments)
  (with-open-file (stream (org-nodes-test-env "LEM_YATH_ORG_NODES_REPORT")
                          :direction :output :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun org-nodes-test-open (environment)
  (find-file (org-nodes-test-env environment))
  (current-buffer))

(defun org-nodes-test-touch (&optional (buffer (current-buffer)))
  (with-point ((end (buffer-end-point buffer)))
    (insert-string end (format nil "~%# fixture change ~d" (get-universal-time)))))

(defun org-nodes-test-heading (title &optional (buffer (current-buffer)))
  (with-point ((point (buffer-start-point buffer)))
    (loop
      (when (and (org-heading-line-p point)
                 (search title (line-string point) :test #'char=))
        (return (copy-point point :temporary)))
      (unless (line-offset point 1) (return nil)))))

(defun org-nodes-test-heading-id (title &optional (buffer (current-buffer)))
  (alexandria:when-let ((heading (org-nodes-test-heading title buffer)))
    (with-point ((drawer heading))
      (when (and (line-offset drawer 1)
                 (string= (line-string drawer) ":PROPERTIES:"))
        (org-property-id drawer)))))

(defun org-nodes-test-id-p (title)
  (if (org-nodes-test-heading-id title) "yes" "no"))

(defun org-nodes-test-hook-count (hook function buffer)
  (count function (variable-value hook :buffer buffer)
         :key (lambda (entry) (if (consp entry) (car entry) entry))
         :test #'eq))

(defun org-nodes-test-mode-hook-count (function)
  (count function *org-mode-hook*
         :key (lambda (entry) (if (consp entry) (car entry) entry))
         :test #'eq))

(define-command lem-yath-test-org-nodes-static () ()
  (let* ((buffer (current-buffer))
         (source (merge-pathnames
                  "src/org/nodes-sync.lisp"
                  (asdf:system-source-directory "lem-yath"))))
    (load source)
    (load source)
    (setf *org-nodes-sync-hosts* (list (org-nodes-short-hostname))
          *org-nodes-sync-command* (org-nodes-test-env
                                    "LEM_YATH_ORG_NODES_COMMAND")
          *org-nodes-auto-id-enabled* nil)
    (org-nodes-sync-setup-buffer buffer)
    (let ((eligible (org-nodes-sync-eligible-path buffer))
          (command (org-nodes-sync-executable)))
      (let ((*org-nodes-sync-hosts* '("definitely-not-this-host")))
      (org-nodes-test-log
       "STATIC enabled=~a host=~a eligible=~a command=~a denied=~a before=~d after=~d mode-hook=~d auto=~a"
       (if *org-nodes-sync-enabled* "yes" "no")
       (org-nodes-short-hostname)
       (if eligible "yes" "no")
       (if command "yes" "no")
       (if (org-nodes-sync-eligible-path buffer) "no" "yes")
       (org-nodes-test-hook-count 'before-save-hook 'org-nodes-before-save buffer)
       (org-nodes-test-hook-count 'after-save-hook 'org-nodes-after-save buffer)
       (org-nodes-test-mode-hook-count 'org-nodes-sync-setup-buffer)
       (if *org-nodes-auto-id-enabled* "yes" "no"))))))

(define-command lem-yath-test-org-nodes-touch-default () ()
  (setf *org-nodes-auto-id-enabled* nil)
  (org-nodes-test-touch)
  (org-nodes-test-log "TOUCH default"))

(define-command lem-yath-test-org-nodes-touch-auto () ()
  (setf *org-nodes-auto-id-enabled* t)
  (org-nodes-test-touch)
  (org-nodes-test-log "TOUCH auto"))

(define-command lem-yath-test-org-nodes-status () ()
  (let ((buffer (current-buffer)))
    (org-nodes-test-log
     "STATUS file=~a state=~(~a~) task=~a scheduled=~a deadline=~a reading=~a plain=~a source=~a modified=~a"
     (file-namestring (or (buffer-filename buffer) #P"none"))
     (or (buffer-value buffer 'lem-yath-org-nodes-sync-last-status) :none)
     (org-nodes-test-id-p "Task")
     (org-nodes-test-id-p "Scheduled")
     (org-nodes-test-id-p "Deadline")
     (org-nodes-test-id-p "Reading")
     (org-nodes-test-id-p "Plain")
     (org-nodes-test-id-p "Source owner")
     (if (buffer-modified-p buffer) "yes" "no"))))

(define-command lem-yath-test-org-nodes-open-conflict () ()
  (org-nodes-test-open "LEM_YATH_ORG_NODES_CONFLICT")
  (org-nodes-test-touch))

(define-command lem-yath-test-org-nodes-open-outside () ()
  (org-nodes-test-open "LEM_YATH_ORG_NODES_OUTSIDE")
  (org-nodes-test-touch))

(define-command lem-yath-test-org-nodes-open-escape () ()
  (org-nodes-test-open "LEM_YATH_ORG_NODES_ESCAPE")
  (org-nodes-test-touch))

(define-command lem-yath-test-org-nodes-open-failure () ()
  (org-nodes-test-open "LEM_YATH_ORG_NODES_FAILURE")
  (setf *org-nodes-auto-id-enabled* nil)
  (org-nodes-test-touch))

(define-command lem-yath-test-org-nodes-manual () ()
  (let ((buffer (org-nodes-test-open "LEM_YATH_ORG_NODES_MANUAL")))
    (setf *org-nodes-auto-id-enabled* nil)
    (let ((count (org-nodes-ensure-actionable-heading-ids buffer t)))
      (org-nodes-test-log
       "MANUAL count=~d task=~a plain=~a modified=~a"
       (or count -1)
       (org-nodes-test-id-p "Manual task")
       (org-nodes-test-id-p "Manual plain")
       (if (buffer-modified-p buffer) "yes" "no")))))

(define-key *global-keymap* "F2" 'lem-yath-test-org-nodes-static)
(define-key *global-keymap* "F3" 'lem-yath-test-org-nodes-touch-default)
(define-key *global-keymap* "F4" 'lem-yath-test-org-nodes-touch-auto)
(define-key *global-keymap* "F5" 'lem-yath-test-org-nodes-status)
(define-key *global-keymap* "F6" 'lem-yath-test-org-nodes-open-conflict)
(define-key *global-keymap* "F7" 'lem-yath-test-org-nodes-open-outside)
(define-key *global-keymap* "F8" 'lem-yath-test-org-nodes-open-failure)
(define-key *global-keymap* "F9" 'lem-yath-test-org-nodes-manual)
(define-key *global-keymap* "F10" 'lem-yath-test-org-nodes-open-escape)

(org-nodes-test-log "READY")
