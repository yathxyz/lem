;;;; Magit-compatible Git pull dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-pull-timeout* 120)
(defparameter *legit-pull-output-limit* (* 4 1024 1024))

(defstruct legit-pull-options
  ff-only-p
  rebase-p
  force-p)

(defun legit-pull-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Pull is available only in a Git repository.")))

(defun legit-pull-run-program (arguments)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-pull-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :environment
     (legit-rebase-child-environment
      "GIT_EDITOR" "true" "GIT_MERGE_AUTOEDIT" "no" "LC_ALL" "C")
     :output-limit *legit-pull-output-limit*)))

(defun legit-pull-option-arguments (options)
  (when (and (legit-pull-options-ff-only-p options)
             (legit-pull-options-rebase-p options))
    (editor-error "Fast-forward-only and rebase pull modes are incompatible."))
  (append
   (when (legit-pull-options-ff-only-p options) '("--ff-only"))
   (when (legit-pull-options-rebase-p options) '("--rebase"))
   (when (legit-pull-options-force-p options) '("--force"))))

(defun legit-pull-stopped-p ()
  "Return true when a failed pull retained merge or rebase state."
  (or (legit-merge-in-progress-p)
      (legit-git-metadata-path-exists-p "rebase-merge")
      (legit-git-metadata-path-exists-p "rebase-apply")))

(defun legit-pull-repository-argument (remote)
  "Return a pull repository argument which Git cannot reinterpret as options.

`git pull -- REMOTE' accepts an option-like configured remote itself, but its
internal `git fetch' invocation loses that separator.  Resolve that exceptional
name to its configured URL before invoking pull."
  (if (or (str:blankp remote) (not (char= (char remote 0) #\-)))
      remote
      (multiple-value-bind (output error-output status)
          (legit-pull-run-program (list "remote" "get-url" "--" remote))
        (unless (and (eql status 0) (str:non-blank-string-p output))
          (editor-error "~a"
                        (legit-command-error-text output error-output)))
        (let ((url (str:trim output)))
          (when (> (length url) *legit-fetch-value-limit*)
            (editor-error "The configured pull URL exceeds 4096 characters."))
          (when (char= (char url 0) #\-)
            (editor-error
             "The configured pull URL cannot begin with an option marker."))
          url))))

(defun legit-pull-run (options remote branch success-message)
  "Pull BRANCH from REMOTE with OPTIONS and preserve stopped Git state."
  (multiple-value-bind (output error-output status)
      (legit-pull-run-program
       (append (list "pull")
               (legit-pull-option-arguments options)
               (list "--" (legit-pull-repository-argument remote) branch)))
    (lem/legit::show-legit-status)
    (cond
      ((and (integerp status) (zerop status))
       (message "~a" success-message)
       t)
      ((legit-pull-stopped-p)
       (message
        "Pull stopped; resolve conflicts, then continue or abort the merge/rebase.")
       nil)
      (t
       (lem/legit::pop-up-message
        (legit-command-error-text output error-output))
       nil))))

(defun legit-pull-current-branch ()
  (or (legit-fetch-current-branch)
      (editor-error "Pull requires a named checked-out branch.")))

(defun legit-pull-configured-push-branch (branch remote)
  "Return BRANCH's configured push destination branch for REMOTE.

Git's symbolic @{push} result is authoritative when it exists.  A remote
branch which has not been published yet falls back to the current branch name,
matching Git's default `simple' and `current' push modes."
  (multiple-value-bind (output error-output status)
      (legit-pull-run-program
       '("rev-parse" "--abbrev-ref" "--symbolic-full-name" "@{push}"))
    (declare (ignore error-output))
    (let* ((target (and (eql status 0) (str:trim output)))
           (prefix (format nil "~a/" remote)))
      (if (and target (alexandria:starts-with-subseq prefix target))
          (subseq target (length prefix))
          branch))))

(defun legit-pull-configure-push-remote (branch)
  (alexandria:when-let
      ((remote
         (legit-push-read-remote
          (format nil "Set push remote and pull ~a from there: " branch))))
    (unless (prompt-for-y-or-n-p
             (format nil "Set ~a as push remote and pull ~a from there? "
                     remote branch))
      (return-from legit-pull-configure-push-remote nil))
    (legit-push-configure-remote branch remote)
    remote))

(defun legit-pull-from-push-remote (options)
  (let* ((branch (legit-pull-current-branch))
         (remote (or (legit-fetch-push-remote)
                     (legit-pull-configure-push-remote branch))))
    (when remote
      (let ((source (legit-pull-configured-push-branch branch remote)))
        (legit-pull-run
         options remote source
         (format nil "Pulled ~a/~a into ~a." remote source branch))))))

(defun legit-pull-upstream-components (branch)
  "Return BRANCH's configured upstream remote and branch name."
  (let ((remote
          (legit-fetch-config-value (format nil "branch.~a.remote" branch)))
        (merge
          (legit-fetch-config-value (format nil "branch.~a.merge" branch))))
    (when (and remote merge
               (alexandria:starts-with-subseq "refs/heads/" merge))
      (values remote (subseq merge (length "refs/heads/"))))))

(defun legit-pull-configure-upstream (branch)
  (alexandria:when-let
      ((target
         (legit-push-read-target
          (format nil "Set upstream of ~a and pull from there: " branch))))
    (multiple-value-bind (remote source)
        (legit-push-split-target target)
      (unless (prompt-for-y-or-n-p
               (format nil "Set ~a as upstream and pull ~a from there? "
                       target branch))
        (return-from legit-pull-configure-upstream nil))
      (legit-branch-checked-output
       (list "branch" (format nil "--set-upstream-to=~a" target) branch))
      (values remote source))))

(defun legit-pull-from-upstream (options)
  (let ((branch (legit-pull-current-branch)))
    (multiple-value-bind (remote source)
        (legit-pull-upstream-components branch)
      (unless (and remote source)
        (multiple-value-setq (remote source)
          (legit-pull-configure-upstream branch)))
      (when (and remote source)
        (legit-pull-run
         options remote source
         (format nil "Pulled upstream ~a/~a into ~a."
                 remote source branch))))))

(defun legit-pull-from-elsewhere (options)
  (let ((branch (legit-pull-current-branch)))
    (alexandria:when-let
        ((target (legit-push-read-target "Pull from remote branch: ")))
      (multiple-value-bind (remote source)
          (legit-push-split-target target)
        (legit-pull-run
         options remote source
         (format nil "Pulled ~a into ~a." target branch))))))

(defun legit-pull-configure-rebase ()
  (legit-branch-config-action (legit-pull-current-branch) "r"))

(defun legit-pull-configure-current-branch ()
  (legit-branch-configure (legit-pull-current-branch)))

(defun legit-pull-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-pull-popup-keymap (options)
  "Build the normally visible pinned Magit pull transient."
  (let* ((keymap (make-keymap :description "Pull"))
         (branch (legit-fetch-current-branch))
         (push-remote (legit-fetch-push-remote)))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(("- f" ,(format nil "[~a] fast-forward only"
                             (if (legit-pull-options-ff-only-p options)
                                 "x" " ")))
            ("- r" ,(format nil "[~a] rebase local commits"
                             (if (legit-pull-options-rebase-p options)
                                 "x" " ")))
            ("- F" ,(format nil "[~a] force fetch"
                             (if (legit-pull-options-force-p options)
                                 "x" " ")))
            ("p" ,(format nil "push remote: ~a"
                           (or push-remote "<configure>")))
            ("u" ,(format nil "upstream: ~a"
                           (or (and branch (legit-reset-upstream branch))
                               "<configure>")))
            ("e" "elsewhere")
            ("r" ,(format nil "pull rebase for ~a"
                           (or branch "<detached>")))
            ("C" "configure current branch")
            ("q" "cancel")))
      (legit-pull-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-pull-read-popup-key ()
  "Read one pull action, including Magit's two-event option keys."
  (let* ((first (read-key))
         (first-name (lem-core::keyseq-to-string (list first))))
    (if (string= first-name "-")
        (format nil "- ~a"
                (lem-core::keyseq-to-string (list (read-key))))
        first-name)))

(defun dispatch-legit-pull ()
  "Display and execute one configured Magit pull action."
  (let ((options (make-legit-pull-options)))
    (unwind-protect
         (loop
           :for keymap := (legit-pull-popup-keymap options)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-pull-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Pull cancelled.")
                   (return nil))
                  ((string= name "- f")
                   (let ((enabled
                           (not (legit-pull-options-ff-only-p options))))
                     (setf (legit-pull-options-ff-only-p options) enabled)
                     (when enabled
                       (setf (legit-pull-options-rebase-p options) nil))))
                  ((string= name "- r")
                   (let ((enabled
                           (not (legit-pull-options-rebase-p options))))
                     (setf (legit-pull-options-rebase-p options) enabled)
                     (when enabled
                       (setf (legit-pull-options-ff-only-p options) nil))))
                  ((string= name "- F")
                   (setf (legit-pull-options-force-p options)
                         (not (legit-pull-options-force-p options))))
                  ((string= name "p")
                   (legit-pull-from-push-remote options)
                   (return t))
                  ((string= name "u")
                   (legit-pull-from-upstream options)
                   (return t))
                  ((string= name "e")
                   (legit-pull-from-elsewhere options)
                   (return t))
                  ((string= name "r")
                   (legit-pull-configure-rebase))
                  ((string= name "C")
                   (legit-pull-configure-current-branch))
                  (t
                   (message "No pull action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-pull () ()
  "Open the configured Magit-compatible Git pull transient."
  (lem/legit::with-current-project (vcs)
    (legit-pull-require-git vcs)
    (dispatch-legit-pull)))

(define-key lem/legit::*peek-legit-keymap* "F" 'lem-yath-legit-pull)
(define-key lem/legit::*legit-diff-mode-keymap* "F" 'lem-yath-legit-pull)
