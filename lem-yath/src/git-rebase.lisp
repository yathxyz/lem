;;;; Signal-free interactive-rebase sequence editor.

(in-package :lem-yath)

(defparameter *legit-rebase-control-script*
  "#!/usr/bin/env bash
set -u

control=${LEM_YATH_REBASE_CONTROL:-}
if [[ -z $control ]]; then
  exit 2
fi

while [[ ! -s $control ]]; do
  sleep 0.05
done

action=
IFS= read -r action <\"$control\" || true
rm -f -- \"$control\"

case $action in
  continue) exit 0 ;;
  abort) exit 1 ;;
  *) exit 2 ;;
esac
")

(defstruct legit-rebase-session
  process
  control-pathname
  (waiting-p t))

(defvar *legit-rebase-sessions* (make-hash-table :test #'eq))

(defun legit-rebase-private-directory ()
  (merge-pathnames "legit/" (lem:lem-home)))

(defun legit-rebase-control-script-pathname ()
  (merge-pathnames "lem-yath-rebase-editor.sh"
                   (legit-rebase-private-directory)))

(defun ensure-legit-rebase-control-script ()
  "Write the fixed sequence-editor helper below Lem's private directory."
  (let ((pathname (legit-rebase-control-script-pathname)))
    (server-ensure-private-directory pathname)
    (server-write-private-file pathname *legit-rebase-control-script*)
    #+sbcl
    (sb-posix:chmod (uiop:native-namestring pathname) #o700)
    #-sbcl
    (error "The rebase control helper requires the supported SBCL runtime")
    pathname))

(defun fresh-legit-rebase-control-pathname ()
  "Return an absent unpredictable control pathname in the private directory."
  (let ((directory (legit-rebase-private-directory)))
    (loop :repeat 100
          :for pathname :=
            (merge-pathnames
             (format nil "rebase-control-~d-~16,'0x"
                     #+sbcl (sb-posix:getpid)
                     #-sbcl 0
                     (random (ash 1 60)))
             directory)
          :unless (server-stat-if-present pathname)
            :return pathname
          :finally (error "Could not reserve a rebase control pathname"))))

(defun close-legit-rebase-process (process)
  "Release the native asynchronous process after UIOP has reaped it."
  (uiop:close-streams process)
  #+sbcl
  (alexandria:when-let
      ((native (slot-value process 'uiop/launch-program::process)))
    (sb-ext:process-close native)))

(defun release-finished-legit-rebase-session (vcs &key wait)
  "Reap VCS's dead Git process and return its still-live session, if any."
  (alexandria:when-let ((session (gethash vcs *legit-rebase-sessions*)))
    (let ((process (legit-rebase-session-process session)))
      (when wait
        (loop :repeat 20
              :while (ignore-errors (uiop:process-alive-p process))
              :do (sleep 0.05)))
      (unless (ignore-errors (uiop:process-alive-p process))
        (unwind-protect
             (ignore-errors (uiop:wait-process process))
          (ignore-errors (close-legit-rebase-process process))
          #+sbcl
          (server-delete-owned-path
           (legit-rebase-session-control-pathname session)
           sb-posix:s-ifreg)
          (remhash vcs *legit-rebase-sessions*)
          (setf session nil))))
    session))

(defun write-legit-rebase-action (pathname action)
  "Publish literal ACTION for the waiting sequence editor."
  (server-write-private-file pathname (format nil "~a~%" action)))

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

(defun wait-for-legit-rebase-todo (process)
  (loop :repeat 500
        :when (uiop:file-exists-p ".git/rebase-merge/git-rebase-todo")
          :return t
        :unless (ignore-errors (uiop:process-alive-p process))
          :return nil
        :do (sleep 0.01)
        :finally (return nil)))

(defmethod lem/porcelain:rebase-interactively
    ((vcs lem/porcelain/git::vcs-git) &key from)
  (when (uiop:directory-exists-p ".git/rebase-merge/")
    (lem/porcelain:porcelain-error
     "A Git rebase is already in progress; continue, abort, or skip it first."))
  (when (release-finished-legit-rebase-session vcs :wait t)
    (lem/porcelain:porcelain-error
     "The previous interactive rebase is still finishing. Please retry."))
  (unless from
    (return-from lem/porcelain:rebase-interactively
      (values "Git rebase is missing the commit to rebase from." nil 1)))
  (let* ((script (ensure-legit-rebase-control-script))
         (control (fresh-legit-rebase-control-pathname))
         (environment
           (legit-rebase-child-environment
            "GIT_SEQUENCE_EDITOR"
            (format nil "bash ~a"
                    (uiop:escape-shell-token
                     (uiop:native-namestring script)))
            "LEM_YATH_REBASE_CONTROL"
            (uiop:native-namestring control)))
         (process nil))
    (setf process
          (uiop:launch-program
           (list "git" "rebase" "--autostash" "-i"
                 (if (lem/porcelain/git::root-commit-p from)
                     "--root"
                     (format nil "~a^" from)))
           :environment environment
           :output nil
           :error-output nil
           :ignore-error-status t))
    (setf (gethash vcs *legit-rebase-sessions*)
          (make-legit-rebase-session
           :process process :control-pathname control))
    (unless (wait-for-legit-rebase-todo process)
      (when (ignore-errors (uiop:process-alive-p process))
        (write-legit-rebase-action control "abort"))
      (release-finished-legit-rebase-session vcs :wait t)
      (lem/porcelain:porcelain-error
       "Git did not create an interactive-rebase todo within five seconds."))
    (values "rebase started" nil 0)))

(defun active-legit-rebase-control-session (vcs)
  (let ((session (release-finished-legit-rebase-session vcs)))
    (when (and session
               (legit-rebase-session-waiting-p session)
               (legit-rebase-session-control-pathname session))
      session)))

(defmethod lem/porcelain:rebase-continue
    ((vcs lem/porcelain/git::vcs-git))
  (cond
    ((active-legit-rebase-control-session vcs)
     (let* ((session (gethash vcs *legit-rebase-sessions*))
            (control (legit-rebase-session-control-pathname session)))
       (write-legit-rebase-action control "continue")
       (setf (legit-rebase-session-waiting-p session) nil)
       (values "rebase continued" nil 0)))
    ((uiop:directory-exists-p ".git/rebase-merge/")
     (lem/porcelain/git::run-git '("rebase" "--continue")))
    (t
     (lem/porcelain:porcelain-error "No Git rebase is in progress."))))

(defmethod lem/porcelain:rebase-abort
    ((vcs lem/porcelain/git::vcs-git))
  (cond
    ((active-legit-rebase-control-session vcs)
     (let* ((session (gethash vcs *legit-rebase-sessions*))
            (control (legit-rebase-session-control-pathname session)))
       (write-legit-rebase-action control "abort")
       (setf (legit-rebase-session-waiting-p session) nil)
       (release-finished-legit-rebase-session vcs :wait t)
       (values "rebase aborted" nil 0)))
    ((uiop:directory-exists-p ".git/rebase-merge/")
     (lem/porcelain/git::run-git '("rebase" "--abort")))
    (t
     (lem/porcelain:porcelain-error "No Git rebase is in progress."))))

(defmethod lem/porcelain:rebase-skip
    ((vcs lem/porcelain/git::vcs-git))
  (cond
    ((active-legit-rebase-control-session vcs)
     (lem/porcelain:porcelain-error
      "The interactive todo must be continued or aborted before skipping."))
    ((uiop:directory-exists-p ".git/rebase-merge/")
     (lem/porcelain/git::run-git '("rebase" "--skip")))
    (t
     (lem/porcelain:porcelain-error "No Git rebase is in progress."))))

(defvar *legit-amend-operation-key* 'lem-yath-legit-amend-operation)

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
    (when (release-finished-legit-rebase-session vcs :wait t)
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

(define-key lem/legit::*peek-legit-keymap* "A" 'lem-yath-legit-amend)
(define-key lem/legit::*legit-diff-mode-keymap* "A" 'lem-yath-legit-amend)

(defun position-legit-rebase-todo-at-first-command (buffer)
  "Do not restore a stale cursor row when Git creates a fresh todo file."
  (alexandria:when-let ((filename (buffer-filename buffer)))
    (when (string= (file-namestring filename) "git-rebase-todo")
      (buffer-start (buffer-point buffer)))))

(defun shutdown-legit-rebase-sessions ()
  "Release every sequence editor still waiting when Lem exits or reloads."
  (let ((sessions '()))
    (maphash (lambda (vcs session)
               (push (cons vcs session) sessions))
             *legit-rebase-sessions*)
    (dolist (entry sessions)
      (let* ((vcs (car entry))
             (session (cdr entry))
             (control (legit-rebase-session-control-pathname session)))
        (when (and control (legit-rebase-session-waiting-p session))
          (ignore-errors (write-legit-rebase-action control "abort"))
          (setf (legit-rebase-session-waiting-p session) nil))
        (release-finished-legit-rebase-session vcs :wait t)))))

(shutdown-legit-rebase-sessions)
(remove-hook *find-file-hook* 'position-legit-rebase-todo-at-first-command)
(remove-hook *exit-editor-hook* 'shutdown-legit-rebase-sessions)
(add-hook *find-file-hook* 'position-legit-rebase-todo-at-first-command -10000)
(add-hook *exit-editor-hook* 'shutdown-legit-rebase-sessions)
