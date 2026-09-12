;;;; Native Lisp client ownership for interactive Git rebase.

(in-package :lem-yath)

(defstruct legit-rebase-session
  job
  directory
  todo-pathname)

(defvar *legit-rebase-sessions* (make-hash-table :test #'eq))

(defun legit-rebase-metadata-pathname (name)
  "Resolve Git metadata in ordinary repositories and linked worktrees."
  (multiple-value-bind (output error-output status)
      (lem/porcelain/git::run-git
       (list "rev-parse" "--path-format=absolute" "--git-path" name))
    (unless (zerop status)
      (lem/porcelain:porcelain-error "~a" error-output))
    (uiop:parse-native-namestring
     (string-right-trim '(#\Newline #\Return) output))))

(defun legit-rebase-in-progress-p ()
  (or (uiop:directory-exists-p
       (legit-rebase-metadata-pathname "rebase-merge/"))
      (uiop:directory-exists-p
       (legit-rebase-metadata-pathname "rebase-apply/"))))

(defparameter *legit-rebase-job-owner* "human/git-rebase")
(defparameter *legit-rebase-job-timeout* (* 24 60 60))
(defvar *legit-rebase-job-timer* nil)

(defun legit-rebase-job-success-p (result)
  (and result (equal "exited" (gethash "state" result))
       (eql 0 (gethash "exit-code" result))))

(defun legit-rebase-jobs (&optional (directory (uiop:getcwd)))
  "Find retained jobs for this exact worktree, including interrupted history."
  (remove-if-not
   (lambda (job)
     (and (equal *legit-rebase-job-owner* (lem-toolkit/jobs:job-owner job))
          (uiop:pathname-equal directory (lem-toolkit/jobs:job-directory job))))
   (lem-toolkit/jobs:list-jobs (ensure-toolkit-job-manager))))

(defun release-finished-legit-rebase-session (vcs)
  "Observe completed cleanup without waiting; retain its durable job history."
  (alexandria:when-let ((session (gethash vcs *legit-rebase-sessions*)))
    (alexandria:when-let
        ((result (lem-toolkit/jobs:job-result (legit-rebase-session-job session))))
      (message "Git rebase job ~a ~a (~a, exit ~a). Use lem-yath-legit-rebase-job to inspect."
               (gethash "id" result)
               (if (legit-rebase-job-success-p result) "succeeded" "failed")
               (gethash "state" result) (gethash "exit-code" result))
      (remhash vcs *legit-rebase-sessions*)
      (setf session nil))
    session))

(defun active-legit-rebase-session (vcs)
  "Do not overlap a prior job, including one retained across configuration reload."
  (or (release-finished-legit-rebase-session vcs)
      (alexandria:when-let
          ((job (find-if-not #'lem-toolkit/jobs:job-result (legit-rebase-jobs))))
        (setf (gethash vcs *legit-rebase-sessions*)
              (make-legit-rebase-session
               :job job :directory (uiop:getcwd)
               :todo-pathname
               (legit-rebase-metadata-pathname "rebase-merge/git-rebase-todo"))))))

(defun poll-legit-rebase-jobs ()
  (dolist (vcs (loop :for vcs :being :the :hash-keys :of *legit-rebase-sessions*
                     :collect vcs))
    (release-finished-legit-rebase-session vcs))
  (when (zerop (hash-table-count *legit-rebase-sessions*))
    (when *legit-rebase-job-timer* (stop-timer *legit-rebase-job-timer*))
    (setf *legit-rebase-job-timer* nil)))

(defun ensure-legit-rebase-job-timer ()
  (unless *legit-rebase-job-timer*
    (setf *legit-rebase-job-timer*
          (start-timer (make-idle-timer 'poll-legit-rebase-jobs :name "Git rebase jobs")
                       200 :repeat t))))

(define-command lem-yath-legit-rebase-job () ()
  "Inspect this worktree's active or selected retained rebase job."
  (lem/legit::with-current-project (vcs)
    (let* ((session (gethash vcs *legit-rebase-sessions*))
           (job (or (and session (legit-rebase-session-job session))
                    (let ((jobs (legit-rebase-jobs)))
                      (if (rest jobs)
                          (let* ((choices
                                   (loop :for job :in jobs
                                         :for snapshot := (lem-toolkit/jobs:job-snapshot
                                                           job :include-output nil)
                                         :collect
                                         (cons (format nil "~a  ~a  ~s"
                                                       (gethash "id" snapshot)
                                                       (gethash "state" snapshot)
                                                       (gethash "argv" snapshot))
                                               job)))
                                 (selection
                                   (prompt-for-string
                                    "Rebase job: "
                                    :completion-function
                                    (lambda (text) (completion-strings text (mapcar #'car choices)))
                                    :test-function
                                    (lambda (text) (assoc text choices :test #'equal)))))
                            (cdr (assoc selection choices :test #'equal)))
                          (first jobs))))))
      (unless job (editor-error "No retained rebase job for this worktree"))
      (setf (current-window)
            (pop-to-buffer (lem-toolkit/jobs-ui:show-job job))))))

(defun legit-rebase-child-environment (&rest overrides)
  "Copy Lem's environment and apply string name/value OVERRIDES for one child."
  #+sbcl
  (let ((names (loop :for tail :on overrides :by #'cddr
                     :collect (concatenate 'string (first tail) "="))))
    (nconc
     (loop :for entry :in (sb-impl::posix-environ)
           :unless (some (lambda (prefix)
                           (alexandria:starts-with-subseq prefix entry))
                         names)
             :collect entry)
     (loop :for tail :on overrides :by #'cddr
           :collect (format nil "~a=~a" (first tail) (second tail)))))
  #-sbcl
  (declare (ignore overrides))
  #-sbcl
  (error "Child-specific rebase environments require SBCL"))

(defun launch-legit-rebase (vcs arguments &optional todo)
  "Queue a durable managed job; native editor requests arrive asynchronously."
  (unless (lem-daemon:daemon-running-p)
    (lem/porcelain:porcelain-error "Start Lem's native server before rebasing."))
  (let* ((manager (ensure-toolkit-job-manager))
         (editor (uiop:escape-sh-command
                  (list (or (uiop:getenvp "LEM_DAEMON_CLIENT") "lemclient")
                        "--server-name" (lem-daemon:server-name))))
         (job
           (lem-toolkit/jobs:start-job
            (append '("git" "rebase") arguments)
            :manager manager :owner *legit-rebase-job-owner*
            :directory (uiop:native-namestring (uiop:getcwd))
            :timeout *legit-rebase-job-timeout* :output-limit (* 64 1024)
            :environment
            (legit-rebase-child-environment
             "GIT_SEQUENCE_EDITOR" editor "GIT_EDITOR" editor))))
    (setf (gethash vcs *legit-rebase-sessions*)
          (make-legit-rebase-session :job job :directory (uiop:getcwd)
                                     :todo-pathname todo))
    (ensure-legit-rebase-job-timer)
    job))

(defun legit-rebase-waiting-buffer (session)
  "Return the todo only while its native sequence-editor request is pending."
  (alexandria:when-let*
      ((todo (legit-rebase-session-todo-pathname session))
       (buffer (get-file-buffer todo)))
    (when (lem-daemon:request-buffer-list buffer) buffer)))

(defun finish-legit-rebase-todo (buffer abort-p)
  ;; These commands restore the request's origin in the selected window.
  ;; A dynamic current-buffer binding would leave that window inconsistent.
  (lem-daemon::select-file-visit-window)
  (switch-to-buffer buffer)
  (if abort-p
      (lem-daemon:daemon-edit-abort)
      (lem-daemon:daemon-edit-save-and-done)))

(defmethod lem/porcelain:rebase-interactively
    ((vcs lem/porcelain/git::vcs-git) &key from)
  (when (legit-rebase-in-progress-p)
    (lem/porcelain:porcelain-error
     "A Git rebase is already in progress; continue, abort, or skip it first."))
  (when (active-legit-rebase-session vcs)
    (lem/porcelain:porcelain-error
     "The previous interactive rebase is still finishing. Please retry."))
  (unless from
    (return-from lem/porcelain:rebase-interactively
      (values "Git rebase is missing the commit to rebase from." nil 1)))
  (let ((todo (legit-rebase-metadata-pathname "rebase-merge/git-rebase-todo")))
    ;; Native file clients retain their buffers. Git will create a new todo;
    ;; do not silently reuse an old buffer or discard unsaved edits in it.
    (alexandria:when-let ((buffer (get-file-buffer todo)))
      (when (or (buffer-modified-p buffer)
                (lem-daemon:request-buffer-list buffer))
        (lem/porcelain:porcelain-error
         "The previous rebase todo still has edits or a waiting client."))
      (delete-buffer buffer))
    (let ((job
            (launch-legit-rebase
             vcs (list "--autostash" "-i"
                       (if (lem/porcelain/git::root-commit-p from)
                           "--root" (format nil "~a^" from)))
             todo)))
      ;; The fourth value delegates todo display to the native file client.
      (values (format nil "Rebase queued as job ~a" (lem-toolkit/jobs:job-id job)) nil 0 t))))

(defmethod lem/porcelain:rebase-continue
    ((vcs lem/porcelain/git::vcs-git))
  (alexandria:when-let ((session (active-legit-rebase-session vcs)))
    (alexandria:when-let ((buffer (legit-rebase-waiting-buffer session)))
      (finish-legit-rebase-todo buffer nil)
      (return-from lem/porcelain:rebase-continue
        (values "Rebase editor completion sent; Git is still running" nil 0)))
    (lem/porcelain:porcelain-error
     "Git is still running; finish its editor request or wait for it to stop."))
  (unless (legit-rebase-in-progress-p)
    (lem/porcelain:porcelain-error "No Git rebase is in progress."))
  (launch-legit-rebase vcs '("--continue"))
  (values "Rebase continuation queued" nil 0))

(defmethod lem/porcelain:rebase-abort
    ((vcs lem/porcelain/git::vcs-git))
  (alexandria:when-let ((session (active-legit-rebase-session vcs)))
    (alexandria:when-let ((buffer (legit-rebase-waiting-buffer session)))
      (finish-legit-rebase-todo buffer t)
      (return-from lem/porcelain:rebase-abort
        (values "Rebase editor abort requested" nil 0)))
    (lem/porcelain:porcelain-error
     "Git is still running; abort its editor request or wait for it to stop."))
  (unless (legit-rebase-in-progress-p)
    (lem/porcelain:porcelain-error "No Git rebase is in progress."))
  (launch-legit-rebase vcs '("--abort"))
  (values "Rebase abort queued" nil 0))

(defmethod lem/porcelain:rebase-skip
    ((vcs lem/porcelain/git::vcs-git))
  (when (active-legit-rebase-session vcs)
    (lem/porcelain:porcelain-error
     "Git is still running; finish its editor request before skipping."))
  (unless (legit-rebase-in-progress-p)
    (lem/porcelain:porcelain-error "No Git rebase is in progress."))
  (launch-legit-rebase vcs '("--skip"))
  (values "Rebase skip queued" nil 0))

(defvar *legit-amend-operation-key* 'lem-yath-legit-amend-operation)

(defvar *legit-commit-dispatch-keymap*
  (make-keymap :description "Commit"))

(defparameter *legit-amend-buffer-help*
  "

# Please enter the commit message for your changes.
# Lines starting with '#' are discarded; an empty message does nothing.
# Validate with C-c C-c; quit with M-q or C-c C-k.
")

(defun legit-amend-buffer-p (&optional (buffer (current-buffer)))
  (eq (buffer-value buffer *legit-amend-operation-key*) :amend))

(defun legit-command-error-text (output error-output)
  (cond
    ((str:non-blank-string-p error-output) error-output)
    ((str:non-blank-string-p output) output)
    (t "Git did not explain why the operation failed.")))

(defun show-legit-amend-buffer (message directory)
  "Open a transient commit buffer prefilled with HEAD's current message."
  (when (get-buffer "*legit-amend*")
    (editor-error "An amend message buffer is already open."))
  (let ((buffer (make-buffer "*legit-amend*")))
    (setf (buffer-directory buffer) directory
          (buffer-read-only-p buffer) nil
          (buffer-value buffer *legit-amend-operation-key*) :amend)
    (erase-buffer buffer)
    (insert-string
     (buffer-point buffer)
     (format nil "~a~a"
             (string-right-trim '(#\Newline #\Return) message)
             *legit-amend-buffer-help*))
    (change-buffer-mode buffer 'lem/legit::legit-commit-mode)
    (buffer-start (buffer-point buffer))
    (next-window)
    (switch-to-buffer buffer)))

(define-command lem-yath-legit-amend () ()
  "Amend HEAD from a prefilled Legit commit-message buffer."
  (lem/legit::with-current-project (vcs)
    (unless (typep vcs 'lem/porcelain/git::vcs-git)
      (editor-error "Amend is available only in a Git repository."))
    (when (active-legit-rebase-session vcs)
      (editor-error
       "The interactive rebase is still reaching its edit stop. Please retry."))
    (multiple-value-bind (output error-output status)
        (lem/porcelain/git::run-git '("log" "-1" "--format=%B"))
      (if (zerop status)
          (show-legit-amend-buffer output (uiop:getcwd))
          (editor-error "~a"
                        (legit-command-error-text output error-output))))))

(defun legit-amend-continue ()
  "Commit the current transient buffer as an amended HEAD."
  (let* ((buffer (current-buffer))
         (message
           (lem/legit::clean-commit-message (buffer-text buffer))))
    (when (str:blankp message)
      (message "No commit message; amend was not run.")
      (return-from legit-amend-continue nil))
    (lem/legit::with-current-project (vcs)
      (unless (typep vcs 'lem/porcelain/git::vcs-git)
        (editor-error "Amend is available only in a Git repository."))
      (multiple-value-bind (output error-output status)
          (lem/porcelain/git::run-git
           (list "commit" "--amend" "-m" message))
        (if (zerop status)
            (progn
              (buffer-unmark buffer)
              (kill-buffer buffer)
              (when (lem/legit::legit-status-active-p)
                (setf (current-window) lem/legit::*peek-window*))
              (lem/legit::show-legit-status)
              (message "Amended HEAD."))
            (lem/legit::pop-up-message
             (legit-command-error-text output error-output)))))))

(defun legit-amend-abort ()
  "Discard the current transient amend message after confirmation."
  (when (or (not lem/legit::*prompt-to-abort-commit*)
            (prompt-for-y-or-n-p "Abort amend?"))
    (let ((buffer (current-buffer)))
      (buffer-unmark buffer)
      (kill-buffer buffer)
      (when (lem/legit::legit-status-active-p)
        (setf (current-window) lem/legit::*peek-window*)))))

(defun remove-legacy-legit-amend-binding (keymap)
  "Remove lem-yath's former A binding without erasing an upstream command."
  (alexandria:when-let
      ((prefix
         (lem-core::keymap-find keymap (lem-core::parse-keyspec "A"))))
    (when (eq (lem-core::prefix-suffix prefix) 'lem-yath-legit-amend)
      (undefine-key keymap "A"))))

(remove-legacy-legit-amend-binding lem/legit::*peek-legit-keymap*)
(remove-legacy-legit-amend-binding lem/legit::*legit-diff-mode-keymap*)

(define-key *legit-commit-dispatch-keymap* "c" 'lem/legit::legit-commit)
(define-key *legit-commit-dispatch-keymap* "a" 'lem-yath-legit-amend)
(define-key lem/legit::*peek-legit-keymap*
  "c" *legit-commit-dispatch-keymap*)
(define-key lem/legit::*legit-diff-mode-keymap*
  "c" *legit-commit-dispatch-keymap*)

(defun position-legit-rebase-todo-at-first-command (buffer)
  "Do not restore a stale cursor row when Git creates a fresh todo file."
  (alexandria:when-let ((filename (buffer-filename buffer)))
    (when (string= (file-namestring filename) "git-rebase-todo")
      (buffer-start (buffer-point buffer))
      (maphash (lambda (vcs session)
                 (declare (ignore vcs))
                 (when (and (legit-rebase-session-todo-pathname session)
                            (uiop:pathname-equal
                             filename (legit-rebase-session-todo-pathname session)))
                   (setf (buffer-directory buffer)
                         (legit-rebase-session-directory session))))
               *legit-rebase-sessions*))))

(defun shutdown-legit-rebase-sessions ()
  "Release pending edit requests without waiting for Git or closing the job manager."
  (maphash
   (lambda (vcs session)
     (declare (ignore vcs))
     (alexandria:when-let ((buffer (legit-rebase-waiting-buffer session)))
       (finish-legit-rebase-todo buffer t)))
   *legit-rebase-sessions*)
  (when *legit-rebase-job-timer* (stop-timer *legit-rebase-job-timer*))
  (setf *legit-rebase-job-timer* nil))

(remove-hook *find-file-hook* 'position-legit-rebase-todo-at-first-command)
(remove-hook *exit-editor-hook* 'shutdown-legit-rebase-sessions)
(add-hook *find-file-hook* 'position-legit-rebase-todo-at-first-command -10000)
(add-hook *exit-editor-hook* 'shutdown-legit-rebase-sessions)
