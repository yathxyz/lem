;;;; Magit-compatible action dispatches in Legit log buffers.

(in-package :lem-yath)

(defvar *legit-log-action-origin-key* 'lem-yath-legit-log-action-origin)

(defstruct legit-log-action-origin
  state
  hash
  line
  root)

(defun legit-log-action-repository-root (&optional (directory (uiop:getcwd)))
  "Return the current Git top-level without presenting command failures."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-log-timeout*))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (list (uiop:native-namestring git) "rev-parse" "--show-toplevel")
         :directory directory
         :environment
         (legit-rebase-child-environment
          "GIT_PAGER" "cat" "LC_ALL" "C")
         :output-limit *legit-log-output-limit*)
      (declare (ignore error-output))
      (and (eql status 0)
           (str:non-blank-string-p output)
           (str:trim output)))))

(defun legit-log-action-status-buffer-p ()
  (and (lem/legit::legit-status-active-p)
       (eq (current-window) lem/legit::*peek-window*)
       (string= (buffer-name (window-buffer lem/legit::*peek-window*))
                "*peek-legit*")))

(defun legit-log-action-status-directory ()
  (and (lem/legit::legit-status-active-p)
       (buffer-directory (window-buffer lem/legit::*peek-window*))))

(defun legit-log-action-interface-directory ()
  "Return the directory owned by the active Legit view or current buffer."
  (or (legit-log-action-status-directory)
      (and (not (deleted-buffer-p (current-buffer)))
           (buffer-directory (current-buffer)))))

(defun legit-log-message-buffer-p (&optional (buffer (current-buffer)))
  (and (not (deleted-buffer-p buffer))
       (eq (buffer-major-mode buffer) 'lem/legit::legit-commit-mode)))

(defun legit-log-capture-action-origin ()
  "Capture the configured log state and point before an inherited action."
  (make-legit-log-action-origin
   :state (copy-legit-log-state (legit-log-buffer-state))
   :hash (text-property-at (current-point) :commit-hash)
   :line (line-number-at-point (current-point))
   :root (legit-log-action-repository-root)))

(defun legit-log-action-origin-same-repository-p (origin directory)
  (and directory
       (legit-log-action-origin-root origin)
       (string= (legit-log-action-origin-root origin)
                (or (legit-log-action-repository-root directory) ""))))

(defun legit-log-store-message-origin (origin &optional (buffer (current-buffer)))
  "Attach one log ORIGIN to a live commit-message BUFFER."
  (when (and (legit-log-message-buffer-p buffer)
             (legit-log-action-origin-same-repository-p
              origin (buffer-directory buffer)))
    (setf (buffer-value buffer *legit-log-action-origin-key*) origin)
    t))

(defun legit-log-find-commit (buffer hash)
  "Return HASH's heading position in BUFFER, or NIL."
  (when hash
    (with-point ((point (buffer-start-point buffer)))
      (loop
        (when (string= hash (or (text-property-at point :commit-hash) ""))
          (return (position-at-point point)))
        (unless (line-offset point 1)
          (return nil))))))

(defun legit-log-fallback-position (buffer line)
  "Return the position at bounded one-based LINE in BUFFER."
  (let ((point (buffer-start-point buffer)))
    (loop :repeat (max 0 (1- line))
          :while (line-offset point 1))
    (position-at-point point)))

(defun legit-log-restore-action-origin (origin)
  "Redisplay ORIGIN's log and restore its hash or prior line."
  (legit-log-display (legit-log-action-origin-state origin))
  (let* ((buffer (current-buffer))
         (target
           (or (legit-log-find-commit
                buffer (legit-log-action-origin-hash origin))
               (legit-log-fallback-position
                buffer (legit-log-action-origin-line origin)))))
    (move-to-position (buffer-point buffer) target)
    (lem/legit::show-matched-line)))

(defun legit-log-restore-action-origin-safely (origin)
  (handler-case
      (legit-log-restore-action-origin origin)
    (error (condition)
      (message "History changed; staying in status: ~a" condition))))

(defun legit-log-call-action (action)
  "Call ACTION and retain the originating log after ordinary status refresh."
  (lem/legit::with-current-project (vcs)
    (legit-log-require-git vcs)
    (let ((origin (legit-log-capture-action-origin)))
      (call-command action nil)
      (cond
        ;; A native commit editor outlives this command.  Let its confirm or
        ;; abort path own the one-shot restoration instead.
        ((legit-log-store-message-origin origin))
        ;; Do not override a preview, list, or changed-root transition.
        ;; Ordinary same-repository mutations otherwise finish in status.
        ((and (legit-log-action-status-buffer-p)
              (legit-log-action-origin-same-repository-p
               origin (legit-log-action-status-directory)))
         (legit-log-restore-action-origin-safely origin))))))

(defun legit-log-call-message-command (action)
  "Call commit-message ACTION and finish or transfer its log origin."
  (let* ((buffer (current-buffer))
         (origin (buffer-value buffer *legit-log-action-origin-key*)))
    (if (null origin)
        (call-command action nil)
        (lem/legit::with-current-project (vcs)
          (legit-log-require-git vcs)
          (call-command action nil)
          (when (deleted-buffer-p buffer)
            (unless (legit-log-store-message-origin origin)
              (when (legit-log-action-origin-same-repository-p
                     origin (legit-log-action-interface-directory))
                (legit-log-restore-action-origin-safely origin))))))))

(defmacro define-legit-log-action-wrapper (name action)
  `(define-command ,name () ()
     (legit-log-call-action ',action)))

(define-legit-log-action-wrapper lem-yath-legit-log-cherry-pick
  lem-yath-legit-cherry-pick)
(define-legit-log-action-wrapper lem-yath-legit-log-bisect
  lem-yath-legit-bisect)
(define-legit-log-action-wrapper lem-yath-legit-log-fetch
  lem-yath-legit-fetch)
(define-legit-log-action-wrapper lem-yath-legit-log-pull
  lem-yath-legit-pull)
(define-legit-log-action-wrapper lem-yath-legit-log-branch
  lem-yath-legit-branch)
(define-legit-log-action-wrapper lem-yath-legit-log-merge
  lem-yath-legit-merge)
(define-legit-log-action-wrapper lem-yath-legit-log-revert-no-commit
  lem-yath-legit-revert-no-commit)
(define-legit-log-action-wrapper lem-yath-legit-log-revert
  lem-yath-legit-revert)
(define-legit-log-action-wrapper lem-yath-legit-log-reset
  lem-yath-legit-reset)
(define-legit-log-action-wrapper lem-yath-legit-log-push
  lem-yath-legit-push)
(define-legit-log-action-wrapper lem-yath-legit-log-worktree
  lem-yath-legit-worktree)
(define-legit-log-action-wrapper lem-yath-legit-log-stash
  lem-yath-legit-stash)
(define-legit-log-action-wrapper lem-yath-legit-log-remote
  lem-yath-legit-remote)
(define-legit-log-action-wrapper lem-yath-legit-log-submodule
  lem-yath-legit-submodule)
(define-legit-log-action-wrapper lem-yath-legit-log-subtree
  lem-yath-legit-subtree)
(define-legit-log-action-wrapper lem-yath-legit-log-commit
  lem/legit::legit-commit)
(define-legit-log-action-wrapper lem-yath-legit-log-amend
  lem-yath-legit-amend)

(define-command lem-yath-legit-log-message-continue () ()
  (legit-log-call-message-command 'lem-yath-legit-commit-continue))

(define-command lem-yath-legit-log-message-abort () ()
  (legit-log-call-message-command 'lem-yath-legit-commit-abort))

(defvar *legit-log-commit-dispatch-keymap*
  (make-keymap :description "Commit from log"))

(define-key *legit-log-commit-dispatch-keymap*
  "c" 'lem-yath-legit-log-commit)
(define-key *legit-log-commit-dispatch-keymap*
  "a" 'lem-yath-legit-log-amend)

(defparameter *legit-log-action-bindings*
  '(("A" . lem-yath-legit-log-cherry-pick)
    ("B" . lem-yath-legit-log-bisect)
    ("f" . lem-yath-legit-log-fetch)
    ("F" . lem-yath-legit-log-pull)
    ("b" . lem-yath-legit-log-branch)
    ("m" . lem-yath-legit-log-merge)
    ("-" . lem-yath-legit-log-revert-no-commit)
    ("_" . lem-yath-legit-log-revert)
    ("O" . lem-yath-legit-log-reset)
    ("p" . lem-yath-legit-log-push)
    ("Z" . lem-yath-legit-log-worktree)
    ("z" . lem-yath-legit-log-stash)
    ("M" . lem-yath-legit-log-remote)
    ("'" . lem-yath-legit-log-submodule)
    ("\"" . lem-yath-legit-log-subtree))
  "Effective Evil Collection Magit dispatches shared by log buffers.")

(defun install-legit-log-action-bindings ()
  "Install the implemented Magit action surface in Legit's log map."
  (dolist (binding *legit-log-action-bindings*)
    (define-key lem/legit::*legit-commits-log-keymap*
      (car binding) (cdr binding)))
  (define-key lem/legit::*legit-commits-log-keymap*
    "c" *legit-log-commit-dispatch-keymap*)
  (define-key lem/legit::*legit-commit-mode-keymap*
    "C-c C-c" 'lem-yath-legit-log-message-continue)
  (define-key lem/legit::*legit-commit-mode-keymap*
    "C-Return" 'lem-yath-legit-log-message-continue)
  (define-key lem/legit::*legit-commit-mode-keymap*
    "C-c C-k" 'lem-yath-legit-log-message-abort)
  (define-key lem/legit::*legit-commit-mode-keymap*
    "M-q" 'lem-yath-legit-log-message-abort))

(install-legit-log-action-bindings)
