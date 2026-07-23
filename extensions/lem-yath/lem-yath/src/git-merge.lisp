;;;; Magit-compatible core Git merge dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-merge-timeout* 120)
(defparameter *legit-merge-output-limit* (* 4 1024 1024))
(defparameter *legit-merge-message-limit* (* 1024 1024))
(defparameter *legit-merge-main-branch-names*
  '("main" "master" "trunk" "development"))
(defvar *legit-merge-strategy-history* nil)
(defvar *legit-merge-strategy-option-history* nil)
(defvar *legit-merge-diff-algorithm-history* nil)
(defvar *legit-merge-gpg-history* nil)

(defstruct legit-merge-options
  ff-mode
  strategy
  strategy-option
  ignore-space-change-p
  ignore-all-space-p
  diff-algorithm
  gpg-sign
  signoff-p)

(defun legit-merge-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Merge is available only in a Git repository.")))

(defun legit-merge-in-progress-p ()
  (legit-git-metadata-path-exists-p "MERGE_HEAD"))

(defun legit-merge-run-program (arguments &key environment)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-merge-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :environment environment
     :output-limit *legit-merge-output-limit*)))

(defun legit-merge-checked-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-merge-run-program arguments)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-merge-option-arguments (options)
  (append
   (case (legit-merge-options-ff-mode options)
     (:ff-only '("--ff-only"))
     (:no-ff '("--no-ff")))
   (alexandria:when-let ((strategy (legit-merge-options-strategy options)))
     (list (format nil "--strategy=~a" strategy)))
   (alexandria:when-let
       ((strategy-option (legit-merge-options-strategy-option options)))
     (list (format nil "--strategy-option=~a" strategy-option)))
   (when (legit-merge-options-ignore-space-change-p options)
     '("-Xignore-space-change"))
   (when (legit-merge-options-ignore-all-space-p options)
     '("-Xignore-all-space"))
   (alexandria:when-let
       ((algorithm (legit-merge-options-diff-algorithm options)))
     (list (format nil "-Xdiff-algorithm=~a" algorithm)))
   (let ((key (legit-merge-options-gpg-sign options)))
     (when key
       (list (if (str:blankp key)
                 "--gpg-sign"
                 (format nil "--gpg-sign=~a" key)))))
   (when (legit-merge-options-signoff-p options) '("--signoff"))))

(defun legit-merge-non-fast-forward-arguments (options)
  "Return OPTIONS arguments with Magit's required --no-ff override."
  (cons "--no-ff"
        (remove "--ff-only" (legit-merge-option-arguments options)
                :test #'string=)))

(defun legit-merge-read-head (prompt)
  "Read one verified merge head while retaining its branch name for Git."
  (multiple-value-bind (hash revision)
      (legit-reset-read-revision
       prompt (text-property-at (current-point) :commit-hash)
       (legit-reset-current-branch))
    (when hash revision)))

(defun legit-merge-assert-clean-enough ()
  "Match Magit's confirmation before merging a dirty tracked worktree."
  (or (not (legit-reset-tracked-changes-p))
      (prompt-for-y-or-n-p
       "Merging with dirty worktree is risky.  Continue? ")))

(defun legit-merge-run (arguments success-message)
  "Run Git merge ARGUMENTS and preserve a normal conflict stop."
  (multiple-value-bind (output error-output status)
      (legit-merge-run-program
       (cons "merge" arguments)
       :environment (legit-rebase-child-environment "GIT_EDITOR" "true"))
    (lem/legit::show-legit-status)
    (cond
      ((and (integerp status) (zerop status))
       (message "~a" success-message)
       t)
      ((legit-merge-in-progress-p)
       (message
        "Merge stopped; resolve conflicts, then commit or abort from m.")
       nil)
      (t
       (lem/legit::pop-up-message
        (legit-command-error-text output error-output))
       nil))))

(defun legit-merge-read-message ()
  "Read Git's bounded prepared merge message."
  (let* ((relative
           (str:trim
            (legit-merge-checked-output
             '("rev-parse" "--git-path" "MERGE_MSG"))))
         (pathname (merge-pathnames relative (uiop:getcwd))))
    (unless (uiop:file-exists-p pathname)
      (editor-error "Git did not prepare a merge message."))
    (with-open-file (stream pathname :direction :input :external-format :utf-8)
      (let ((chunk (make-string 8192))
            (count 0)
            (output (make-string-output-stream)))
        (loop :for length := (read-sequence chunk stream)
              :until (zerop length)
              :do (incf count length)
                  (when (> count *legit-merge-message-limit*)
                    (editor-error "Merge message exceeds 1 MiB."))
                  (write-sequence chunk output :end length))
        (get-output-stream-string output)))))

(defun legit-merge-open-commit-message ()
  "Open Legit's commit buffer prefilled from MERGE_MSG."
  (unless (legit-merge-in-progress-p)
    (editor-error "No merge is in progress."))
  (when (get-buffer "*legit-commit*")
    (editor-error "A commit message buffer is already open."))
  (let ((message (legit-merge-read-message)))
    (lem/legit::legit-commit)
    (let ((point (buffer-start-point (current-buffer))))
      (insert-string point
                     (format nil "~a~%"
                             (string-right-trim '(#\Newline #\Return)
                                                message)))
      (buffer-start (buffer-point (current-buffer))))))

(defun legit-merge-plain (options)
  (alexandria:when-let
      ((head (legit-merge-read-head "Merge: ")))
    (when (legit-merge-assert-clean-enough)
      (legit-merge-run
       (append '("--no-edit")
               (legit-merge-option-arguments options)
               (list head))
       "Merge completed."))))

(defun legit-merge-no-commit (options &key edit-message-p)
  (alexandria:when-let
      ((head (legit-merge-read-head "Merge without committing: ")))
    (when (legit-merge-assert-clean-enough)
      (when (legit-merge-run
             (append '("--no-commit")
                     (legit-merge-non-fast-forward-arguments options)
                     (list head))
             "Merge prepared without committing.")
        (when edit-message-p
          (legit-merge-open-commit-message))))))

(defun legit-merge-squash ()
  (alexandria:when-let
      ((head (legit-merge-read-head "Squash: ")))
    (when (legit-merge-assert-clean-enough)
      (legit-merge-run
       (list "--squash" head)
       "Squash merge applied without committing."))))

(defun legit-merge-preview ()
  "Render Git's prospective merge tree without changing repository state."
  (alexandria:when-let
      ((head (legit-merge-read-head "Preview merge: ")))
    (let* ((base
             (str:trim
              (legit-merge-checked-output
               (list "merge-base" "HEAD" head))))
           (preview
             (legit-merge-checked-output
              (list "merge-tree" base "HEAD" head))))
      (lem/legit::show-diff preview)
      ;; Focus the preview so Legit's status post-command hook does not
      ;; immediately replace it with the commit under the status cursor.
      (setf (current-window) lem/legit::*source-window*)
      (message "Previewing merge without changing the repository."))))

(defun legit-merge-abort ()
  (unless (legit-merge-in-progress-p)
    (editor-error "No merge is in progress."))
  (when (prompt-for-y-or-n-p "Abort merge? ")
    (legit-merge-run '("--abort") "Merge aborted.")))

(defun legit-merge-ref-exists-p (ref)
  (multiple-value-bind (output error-output status)
      (legit-merge-run-program (list "show-ref" "--verify" "--quiet" ref))
    (declare (ignore output))
    (cond
      ((eql status 0) t)
      ((eql status 1) nil)
      (t (editor-error "~a"
                       (legit-command-error-text "" error-output))))))

(defun legit-merge-main-branch ()
  "Return the first existing branch Magit would treat as the main branch."
  (let ((branches (legit-reset-local-branches))
        (configured (legit-fetch-config-value "init.defaultBranch")))
    (find-if
     (lambda (name) (member name branches :test #'string=))
     (remove-duplicates
      (append (when configured (list configured))
              *legit-merge-main-branch-names*)
      :test #'string=))))

(defun legit-merge-read-local-branch (prompt &key exclude initial-value)
  (let ((branches (remove exclude (legit-reset-local-branches)
                          :test #'string=)))
    (unless branches
      (editor-error "There is no other local branch to merge."))
    (prompt-for-string
     prompt
     :initial-value (if (member initial-value branches :test #'string=)
                        initial-value
                        "")
     :history-symbol '*legit-reset-branch-history*
     :completion-function
     (lambda (query) (completion-strings query branches))
     :test-function
     (lambda (input) (member input branches :test #'string=)))))

(defun legit-merge-push-remote-for-branch (branch)
  "Return BRANCH's configured valid push remote, if any."
  (let* ((remotes (legit-fetch-remotes))
         (branch-remote
           (legit-fetch-config-value
            (format nil "branch.~a.pushRemote" branch)))
         (default-remote (legit-fetch-config-value "remote.pushDefault")))
    (cond
      ((member branch-remote remotes :test #'string=) branch-remote)
      ((member default-remote remotes :test #'string=) default-remote))))

(defun legit-merge-existing-push-remote (branch)
  "Return the push remote only when its tracking branch already exists."
  (alexandria:when-let ((remote (legit-merge-push-remote-for-branch branch)))
    (when (legit-merge-ref-exists-p
           (format nil "refs/remotes/~a/~a" remote branch))
      remote)))

(defun legit-merge-run-command (arguments)
  "Run bounded Git ARGUMENTS, showing any failure without changing it."
  (multiple-value-bind (output error-output status)
      (legit-merge-run-program arguments)
    (if (and (integerp status) (zerop status))
        t
        (progn
          (lem/legit::pop-up-message
           (legit-command-error-text output error-output))
          nil))))

(defun legit-merge-protected-source-confirmed-p (branch)
  (or (not (equal branch (legit-merge-main-branch)))
      (prompt-for-y-or-n-p
       (format nil
               "Do you really want to merge main branch ~a into another branch? "
               branch))))

(defun legit-merge-confirm-push-remote (branch)
  "Return whether to proceed and the optional lease-protected push remote."
  (let ((remote (legit-merge-existing-push-remote branch)))
    (if remote
        (values
         (prompt-for-y-or-n-p
          (format nil
                  "Force-push ~a to ~a/~a with lease before merging? "
                  branch remote branch))
         remote)
        (values t nil))))

(defun legit-merge-force-push (branch remote)
  (or (null remote)
      (legit-merge-run-command
       (list "push" "-v" "--force-with-lease" remote
             (format nil "~a:~a" branch branch)))))

(defun legit-merge-absorb-message-arguments (branch)
  (let* ((configured
           (legit-fetch-config-value
            (format nil "branch.~a.pullRequest" branch)))
         (pull-request (and configured (str:trim configured))))
    (when (and pull-request
               (or (> (length pull-request) 32)
                   (zerop (length pull-request))
                   (not (every #'digit-char-p pull-request))))
      (editor-error "The configured pull-request number is invalid."))
    (if pull-request
        (let ((current (legit-reset-current-branch)))
          (list
           "-m"
           (format nil "Merge branch '~a'~a [#~a]"
                   branch
                   (if (equal current (legit-merge-main-branch))
                       ""
                       (format nil " into ~a" (or current "HEAD")))
                   pull-request)))
        '("--no-edit"))))

(defun legit-merge-delete-absorbed-branch (branch)
  "Delete BRANCH only after its merge completed successfully."
  (when (legit-merge-run-command (list "branch" "-D" "--" branch))
    (lem/legit::show-legit-status)
    (message "Absorbed and deleted branch ~a." branch)
    t))

(defun legit-merge-execute-absorb (branch options push-remote)
  "Execute an already confirmed absorb of BRANCH into the current HEAD."
  (let ((arguments
          (append (legit-merge-absorb-message-arguments branch)
                  (legit-merge-option-arguments options)
                  (list branch))))
    (when (legit-merge-force-push branch push-remote)
      (when (legit-merge-run
             arguments (format nil "Merged branch ~a; removing it." branch))
        (legit-merge-delete-absorbed-branch branch)))))

(defun legit-merge-absorb (options)
  "Merge another local branch into HEAD and delete it after success."
  (let ((current (legit-reset-current-branch)))
    (alexandria:when-let
        ((branch
           (legit-merge-read-local-branch
            "Absorb branch: " :exclude current)))
      (when (and (legit-merge-assert-clean-enough)
                 (legit-merge-protected-source-confirmed-p branch)
                 (prompt-for-y-or-n-p
                  (format nil
                          "Absorb ~a into ~a and delete ~a after success? "
                          branch (or current "detached HEAD") branch)))
        (multiple-value-bind (proceed-p remote)
            (legit-merge-confirm-push-remote branch)
          (when proceed-p
            (legit-merge-execute-absorb branch options remote)))))))

(defun legit-merge-dissolve (options)
  "Merge the current branch into another local branch and remove the former."
  (let* ((current (legit-reset-current-branch))
         (head (str:trim
                (legit-merge-checked-output
                 '("rev-parse" "--verify" "HEAD^{commit}"))))
         (initial (or (and current (legit-reset-upstream current))
                      (legit-merge-main-branch))))
    (alexandria:when-let
        ((target
           (legit-merge-read-local-branch
            (format nil "Merge ~a into: " (or current head))
            :exclude current :initial-value initial)))
      (when (and (legit-merge-assert-clean-enough)
                 (or (null current)
                     (legit-merge-protected-source-confirmed-p current))
                 (prompt-for-y-or-n-p
                  (if current
                      (format nil
                              "Dissolve ~a into ~a and delete ~a after success? "
                              current target current)
                      (format nil "Merge detached HEAD into ~a? " target))))
        (multiple-value-bind (proceed-p remote)
            (if current
                (legit-merge-confirm-push-remote current)
                (values t nil))
          (when (and proceed-p
                     (legit-merge-run-command (list "checkout" target)))
            (if current
                (legit-merge-execute-absorb current options remote)
                (legit-merge-run
                 (append '("--no-edit")
                         (legit-merge-option-arguments options)
                         (list head))
                 "Merged detached HEAD."))))))))

(defun legit-merge-read-choice (prompt choices history-symbol)
  (prompt-for-string
   prompt
   :history-symbol history-symbol
   :completion-function
   (lambda (query) (completion-strings query choices))
   :test-function
   (lambda (input) (member input choices :test #'string=))))

(defun legit-merge-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-merge-popup-keymap (options active-p)
  (let ((keymap (make-keymap :description "Merge")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (if active-p
        (dolist (entry '(("m" "commit merge")
                         ("a" "abort merge")
                         ("q" "cancel")))
          (legit-merge-add-popup-entry keymap (first entry) (second entry)))
        (dolist
            (entry
              `(("- f" ,(format nil "[~a] fast-forward only"
                                 (if (eq (legit-merge-options-ff-mode options)
                                         :ff-only) "x" " ")))
                ("- n" ,(format nil "[~a] no fast-forward"
                                 (if (eq (legit-merge-options-ff-mode options)
                                         :no-ff) "x" " ")))
                ("- s" ,(format nil "strategy: ~a"
                                 (or (legit-merge-options-strategy options)
                                     "default")))
                ("- X" ,(format nil "strategy option: ~a"
                                 (or (legit-merge-options-strategy-option options)
                                     "none")))
                ("- b" ,(format nil "[~a] ignore space changes"
                                 (if (legit-merge-options-ignore-space-change-p
                                      options) "x" " ")))
                ("- w" ,(format nil "[~a] ignore all whitespace"
                                 (if (legit-merge-options-ignore-all-space-p
                                      options) "x" " ")))
                ("- A" ,(format nil "diff algorithm: ~a"
                                 (or (legit-merge-options-diff-algorithm options)
                                     "default")))
                ("- S" ,(format nil "GPG sign: ~a"
                                 (let ((key (legit-merge-options-gpg-sign options)))
                                   (cond ((null key) "off")
                                         ((str:blankp key) "default key")
                                         (t key)))))
                ("+ s" ,(format nil "[~a] add Signed-off-by"
                                 (if (legit-merge-options-signoff-p options)
                                     "x" " ")))
                ("m" "merge")
                ("e" "merge and edit message")
                ("n" "merge but do not commit")
                ("a" "absorb branch")
                ("p" "preview merge")
                ("s" "squash merge")
                ("d" "dissolve branch")
                ("q" "cancel")))
          (legit-merge-add-popup-entry keymap (first entry) (second entry))))
    keymap))

(defun legit-merge-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (member name '("-" "+") :test #'string=)
        (format nil "~a ~a" name
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun legit-merge-toggle-ff (options value)
  (setf (legit-merge-options-ff-mode options)
        (unless (eq (legit-merge-options-ff-mode options) value) value)))

(defun dispatch-legit-merge ()
  "Display and execute one configured Magit merge action."
  (let ((options (make-legit-merge-options)))
    (unwind-protect
         (loop
           :for active-p := (legit-merge-in-progress-p)
           :for keymap := (legit-merge-popup-keymap options active-p)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-merge-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Merge cancelled.")
                   (return nil))
                  ((and active-p (string= name "m"))
                   (legit-merge-open-commit-message)
                   (return t))
                  ((and active-p (string= name "a"))
                   (legit-merge-abort)
                   (return t))
                  (active-p
                   (message "No in-progress merge action is bound to ~a" name)
                   (return nil))
                  ((string= name "- f")
                   (legit-merge-toggle-ff options :ff-only))
                  ((string= name "- n")
                   (legit-merge-toggle-ff options :no-ff))
                  ((string= name "- s")
                   (setf (legit-merge-options-strategy options)
                         (legit-merge-read-choice
                          "Merge strategy: "
                          '("resolve" "recursive" "ort" "octopus" "ours"
                            "subtree")
                          '*legit-merge-strategy-history*)))
                  ((string= name "- X")
                   (setf (legit-merge-options-strategy-option options)
                         (legit-merge-read-choice
                          "Strategy option: " '("ours" "theirs" "patience")
                          '*legit-merge-strategy-option-history*)))
                  ((string= name "- b")
                   (setf (legit-merge-options-ignore-space-change-p options)
                         (not (legit-merge-options-ignore-space-change-p
                               options))))
                  ((string= name "- w")
                   (setf (legit-merge-options-ignore-all-space-p options)
                         (not (legit-merge-options-ignore-all-space-p
                               options))))
                  ((string= name "- A")
                   (setf (legit-merge-options-diff-algorithm options)
                         (legit-merge-read-choice
                          "Diff algorithm: "
                          '("default" "minimal" "patience" "histogram")
                          '*legit-merge-diff-algorithm-history*)))
                  ((string= name "- S")
                   (setf (legit-merge-options-gpg-sign options)
                         (if (legit-merge-options-gpg-sign options)
                             nil
                             (or (prompt-for-string
                                  "GPG signing key (blank uses default): "
                                  :history-symbol '*legit-merge-gpg-history*)
                                 ""))))
                  ((string= name "+ s")
                   (setf (legit-merge-options-signoff-p options)
                         (not (legit-merge-options-signoff-p options))))
                  ((string= name "m")
                   (legit-merge-plain options)
                   (return t))
                  ((string= name "e")
                   (legit-merge-no-commit options :edit-message-p t)
                   (return t))
                  ((string= name "n")
                   (legit-merge-no-commit options)
                   (return t))
                  ((string= name "a")
                   (legit-merge-absorb options)
                   (return t))
                  ((string= name "p")
                   (legit-merge-preview)
                   (return t))
                  ((string= name "s")
                   (legit-merge-squash)
                   (return t))
                  ((string= name "d")
                   (legit-merge-dissolve options)
                   (return t))
                  (t
                   (message "No merge action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-merge () ()
  "Open the configured Magit-compatible Git merge transient."
  (lem/legit::with-current-project (vcs)
    (legit-merge-require-git vcs)
    (dispatch-legit-merge)))

(define-key lem/legit::*peek-legit-keymap* "m" 'lem-yath-legit-merge)
(define-key lem/legit::*legit-diff-mode-keymap* "m" 'lem-yath-legit-merge)
