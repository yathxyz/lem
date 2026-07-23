;;;; Magit-compatible Git reset dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-reset-timeout* 30)
(defparameter *legit-reset-output-limit* (* 4 1024 1024))
(defparameter *legit-reset-candidate-limit* 5000)

(defvar *legit-reset-revision-history* nil)
(defvar *legit-reset-branch-history* nil)
(defvar *legit-reset-file-history* nil)
(defvar *legit-reset-dispatch-keymap*
  (make-keymap :description "Reset"))

(defun legit-reset-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Reset is available only in a Git repository.")))

(defun legit-reset-run-program (arguments &key environment)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-reset-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :environment environment
     :output-limit *legit-reset-output-limit*)))

(defun legit-reset-checked-output (arguments &key environment)
  "Return stdout from Git ARGUMENTS, or report Git's failure."
  (multiple-value-bind (output error-output status)
      (legit-reset-run-program arguments :environment environment)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-reset-run (arguments success-message &key environment)
  "Run Git ARGUMENTS, refresh Legit, and report the result."
  (multiple-value-bind (output error-output status)
      (legit-reset-run-program arguments :environment environment)
    (lem/legit::show-legit-status)
    (if (and (integerp status) (zerop status))
        (progn
          (message "~a" success-message)
          t)
        (progn
          (lem/legit::pop-up-message
           (legit-command-error-text output error-output))
          nil))))

(defun legit-reset-normalize-revision (revision)
  "Resolve whitespace-free REVISION to one commit hash."
  (let ((revision (str:trim revision)))
    (when (str:blankp revision)
      (editor-error "A Git revision is required."))
    (when (find-if (lambda (character)
                     (member character '(#\Space #\Tab #\Newline #\Return)))
                   revision)
      (editor-error "A Git revision cannot contain whitespace."))
    (str:trim
     (legit-reset-checked-output
      (list "rev-parse" "--verify" (format nil "~a^{commit}" revision))))))

(defun legit-reset-revision-candidates ()
  "Return bounded display/revision pairs reachable through all refs."
  (let* ((refs
           (remove-if
            #'str:blankp
            (str:lines
             (legit-reset-checked-output
              (list "for-each-ref" "--format=%(refname:short)")))))
         (commits (legit-cherry-pick-candidates))
         (pairs
           (remove-duplicates
            (append (mapcar (lambda (ref) (cons ref ref)) refs) commits)
            :key #'car :test #'string=)))
    (subseq pairs 0 (min *legit-reset-candidate-limit* (length pairs)))))

(defun legit-reset-read-revision (prompt &optional initial-value exclude)
  "Read and resolve one Git revision for reset.

EXCLUDE removes one completion label but does not prohibit an explicitly typed
revision, matching Magit's branch-reset reader."
  (let* ((candidates
           (remove exclude (legit-reset-revision-candidates)
                   :key #'car :test #'string=))
         (labels (mapcar #'car candidates))
         (input
           (prompt-for-string
            prompt
            :initial-value (or initial-value "")
            :history-symbol '*legit-reset-revision-history*
            :completion-function
            (lambda (query) (completion-strings query labels)))))
    (when input
      (let ((revision (or (cdr (assoc input candidates :test #'string=))
                          input)))
        (values (legit-reset-normalize-revision revision) revision)))))

(defun legit-reset-default-revision ()
  (or (text-property-at (current-point) :commit-hash)
      "HEAD"))

(defun legit-reset-current-branch ()
  (multiple-value-bind (output error-output status)
      (legit-reset-run-program
       '("symbolic-ref" "--quiet" "--short" "HEAD"))
    (cond
      ((and (integerp status) (zerop status))
       (let ((branch (str:trim output)))
         (unless (str:blankp branch) branch)))
      ((eql status 1) nil)
      (t (editor-error "~a"
                       (legit-command-error-text output error-output))))))

(defun legit-reset-local-branches ()
  (let ((branches
          (remove-if
           #'str:blankp
           (str:lines
            (legit-reset-checked-output
             (list "for-each-ref" "--format=%(refname:short)"
                   "refs/heads"))))))
    (subseq branches 0 (min *legit-reset-candidate-limit*
                            (length branches)))))

(defun legit-reset-read-local-branch ()
  (let* ((branches (legit-reset-local-branches))
         (current (legit-reset-current-branch)))
    (unless branches
      (editor-error "There are no local branches to reset."))
    (prompt-for-string
     "Reset branch: "
     :initial-value (or current "")
     :history-symbol '*legit-reset-branch-history*
     :completion-function
     (lambda (query) (completion-strings query branches))
     :test-function
     (lambda (input) (member input branches :test #'string=)))))

(defun legit-reset-upstream (branch)
  (multiple-value-bind (output error-output status)
      (legit-reset-run-program
       (list "for-each-ref" "--format=%(upstream:short)"
             (format nil "refs/heads/~a" branch)))
    (declare (ignore error-output))
    (when (and (integerp status) (zerop status)
               (str:non-blank-string-p output))
      (str:trim output))))

(defun legit-reset-tracked-changes-p ()
  "Return true for staged, unstaged, or unmerged tracked changes."
  (labels ((changed-p (arguments)
             (multiple-value-bind (output error-output status)
                 (legit-reset-run-program arguments)
               (declare (ignore output))
               (cond
                 ((eql status 0) nil)
                 ((eql status 1) t)
                 (t (editor-error "~a"
                                  (legit-command-error-text
                                   "" error-output)))))))
    (or (changed-p '("diff" "--quiet" "--no-ext-diff"))
        (changed-p '("diff" "--cached" "--quiet" "--no-ext-diff")))))

(defun legit-reset-branch ()
  "Reset a selected local branch, hard-resetting when it is current."
  (alexandria:when-let ((branch (legit-reset-read-local-branch)))
    (multiple-value-bind (target target-name)
        (legit-reset-read-revision
         (format nil "Reset ~a to: " branch)
         (legit-reset-upstream branch)
         branch)
      (when target
        (let ((current (legit-reset-current-branch)))
          (if (and current (string= branch current))
              (when (or (not (legit-reset-tracked-changes-p))
                        (prompt-for-y-or-n-p
                         "Uncommitted changes will be lost.  Proceed? "))
                (legit-reset-run
                 (list "reset" "--hard" target)
                 (format nil "Reset ~a to ~a." branch target-name)))
              (legit-reset-run
               (list "update-ref" "-m"
                     (format nil "reset: moving to ~a" target-name)
                     (format nil "refs/heads/~a" branch)
                     target)
               (format nil "Reset ~a to ~a." branch target-name))))))))

(defun legit-reset-tree-paths (revision)
  "Return exact file and directory candidates present in REVISION."
  (let* ((files
           (project-split-nul
            (legit-reset-checked-output
             (list "ls-tree" "-z" "--full-tree" "-r" "--name-only"
                   revision))))
         (directories
           (mapcar
            (lambda (path) (concatenate 'string path "/"))
            (project-split-nul
             (legit-reset-checked-output
              (list "ls-tree" "-z" "--full-tree" "-r" "-d" "--name-only"
                    revision)))))
         (paths (sort (remove-duplicates (append files directories)
                                         :test #'string=)
                      #'string<)))
    (when (> (length paths) *legit-reset-candidate-limit*)
      (editor-error "Revision has more than ~d file candidates."
                    *legit-reset-candidate-limit*))
    paths))

(defun legit-reset-current-relative-file (paths)
  (alexandria:when-let ((filename (buffer-filename (current-buffer))))
    (let* ((root (uiop:ensure-directory-pathname (truename (uiop:getcwd))))
           (relative (tm-relative-path filename root)))
      (and relative (member relative paths :test #'string=) relative))))

(defun legit-reset-read-file (revision)
  (let* ((paths (legit-reset-tree-paths revision))
         (current (legit-reset-current-relative-file paths))
         (choices
           (mapcar (lambda (path)
                     (cons (completion-path-display-string path) path))
                   paths))
         (labels (mapcar #'car choices))
         (initial
           (and current
                (alexandria:when-let
                    ((choice
                       (find current choices :key #'cdr :test #'string=)))
                  (car choice)))))
    (unless paths
      (editor-error "Revision contains no files."))
    (let ((input
            (prompt-for-string
             "Checkout file: "
             :initial-value (or initial "")
             :history-symbol '*legit-reset-file-history*
             :completion-function
             (lambda (query) (completion-strings query labels)))))
      ;; Display escapes keep control-bearing filenames on one prompt row;
      ;; only the exact NUL-parsed candidate is returned to Git.
      (or (cdr (assoc input choices :test #'string=))
          (editor-error
           "Select a file or directory present in the revision.")))))

(defun legit-reset-file ()
  "Checkout one exact file or directory from a selected revision."
  (multiple-value-bind (revision)
      (legit-reset-read-revision "Checkout from revision: "
                                 (legit-reset-default-revision))
    (when revision
      (alexandria:when-let ((path (legit-reset-read-file revision)))
        (legit-reset-run
         (list "checkout" revision "--" path)
         (format nil "Checked out ~a." path))))))

(defun legit-reset-head-and-or-index (mode description)
  (multiple-value-bind (revision)
      (legit-reset-read-revision
       (format nil "~a: " description)
       (legit-reset-default-revision))
    (when revision
      (legit-reset-run
       (list "reset" mode revision)
       (format nil "~a complete." description)))))

(defun legit-reset-index ()
  (multiple-value-bind (revision)
      (legit-reset-read-revision "Reset index to: "
                                 (legit-reset-default-revision))
    (when revision
      (legit-reset-run
       (list "reset" revision "--" ".")
       "Index reset."))))

(defun legit-reset-worktree ()
  "Reset only the worktree using Magit's temporary-index algorithm."
  (multiple-value-bind (revision)
      (legit-reset-read-revision "Reset worktree to: "
                                 (legit-reset-default-revision))
    (when revision
      (uiop:with-temporary-file (:pathname index-path :stream index-stream)
        (close index-stream)
        (delete-file index-path)
        (let* ((native-path (uiop:native-namestring index-path))
               (environment
                 (legit-rebase-child-environment
                  "GIT_INDEX_FILE" native-path)))
          (legit-reset-checked-output
           (list "read-tree" revision
                 (format nil "--index-output=~a" native-path)))
          (legit-reset-run
           '("checkout-index" "--all" "--force")
           "Worktree reset."
           :environment environment))))))

(defun legit-reset-add-popup-entry (key description)
  (define-key *legit-reset-dispatch-keymap* key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find *legit-reset-dispatch-keymap*
                                (lem-core::parse-keyspec key)))
        description))

(dolist (entry
          '(("b" "branch")
            ("f" "file")
            ("m" "mixed (HEAD and index)")
            ("s" "soft (HEAD only)")
            ("h" "hard (HEAD, index and worktree)")
            ("k" "keep (HEAD and index, keeping uncommitted)")
            ("i" "index (only)")
            ("w" "worktree (only)")
            ("q" "cancel")))
  (legit-reset-add-popup-entry (first entry) (second entry)))

(setf (lem/transient::keymap-show-p *legit-reset-dispatch-keymap*) t
      (lem/transient::keymap-display-style *legit-reset-dispatch-keymap*)
      :column)

(defun dispatch-legit-reset ()
  "Display and execute one configured Magit reset action."
  (unwind-protect
       (progn
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate *legit-reset-dispatch-keymap*))
         (redraw-display)
         (let ((name (lem-core::keyseq-to-string (list (read-key)))))
           (lem/transient::hide-transient)
           (cond
             ((or (string= name "q") (string= name "Escape"))
              (message "Reset cancelled."))
             ((string= name "b") (legit-reset-branch))
             ((string= name "f") (legit-reset-file))
             ((string= name "m")
              (legit-reset-head-and-or-index "--mixed" "Mixed reset"))
             ((string= name "s")
              (legit-reset-head-and-or-index "--soft" "Soft reset"))
             ((string= name "h")
              (legit-reset-head-and-or-index "--hard" "Hard reset"))
             ((string= name "k")
              (legit-reset-head-and-or-index "--keep" "Keep reset"))
             ((string= name "i") (legit-reset-index))
             ((string= name "w") (legit-reset-worktree))
             (t (message "No reset action is bound to ~a" name)))))
    (lem/transient::hide-transient)))

(define-command lem-yath-legit-reset () ()
  "Open the configured Magit-compatible Git reset transient."
  (lem/legit::with-current-project (vcs)
    (legit-reset-require-git vcs)
    (dispatch-legit-reset)))

;; Evil Collection moves Magit's top-level reset dispatch from X to O.  Clear
;; the old binding as well so source reloads cannot retain the stale route.
(undefine-key lem/legit::*peek-legit-keymap* "X")
(undefine-key lem/legit::*legit-diff-mode-keymap* "X")
(define-key lem/legit::*peek-legit-keymap* "O" 'lem-yath-legit-reset)
(define-key lem/legit::*legit-diff-mode-keymap* "O" 'lem-yath-legit-reset)
