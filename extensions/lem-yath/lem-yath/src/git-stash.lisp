;;;; Evil-Collection-compatible Magit stash dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-stash-timeout* 120)
(defparameter *legit-stash-output-limit* (* 4 1024 1024))
(defparameter *legit-stash-candidate-limit* 5000)
(defparameter *legit-stash-value-limit* 4096)

(defvar *legit-stash-message-history* nil)
(defvar *legit-stash-reference-history* nil)
(defvar *legit-stash-branch-history* nil)

(defstruct legit-stash-options
  include)

(defun legit-stash-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Stash commands are available only in a Git repository.")))

(defun legit-stash-run-program (arguments &key environment input)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-stash-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :environment environment
     :input input
     :output-limit *legit-stash-output-limit*)))

(defun legit-stash-checked-output (arguments &key environment input)
  (multiple-value-bind (output error-output status)
      (legit-stash-run-program arguments
                               :environment environment
                               :input input)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-stash-optional-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-stash-run-program arguments)
    (declare (ignore error-output))
    (and (integerp status)
         (zerop status)
         (str:non-blank-string-p output)
         (str:trim output))))

(defun legit-stash-run (arguments success-message &key conflict-is-result-p)
  "Run Git ARGUMENTS, refresh Legit, and report its bounded result."
  (multiple-value-bind (output error-output status)
      (legit-stash-run-program arguments)
    (lem/legit::show-legit-status)
    (cond
      ((and (integerp status) (zerop status))
       (message "~a" success-message)
       t)
      ((and conflict-is-result-p
            (eql status 1)
            (str:non-blank-string-p
             (legit-stash-checked-output
              '("diff" "--name-only" "--diff-filter=U" "--"))))
       (lem/legit::pop-up-message
        (format nil "Git installed conflicts while applying the stash:~%~a"
                (legit-command-error-text output error-output)))
       t)
      (t
       (lem/legit::pop-up-message
        (legit-command-error-text output error-output))
       nil))))

(defun legit-stash-split-nul (text)
  (remove ""
          (uiop:split-string text :separator (string (code-char 0)))
          :test #'string=))

(defun legit-stash-bounded-files (arguments)
  (let ((files
          (legit-stash-split-nul
           (legit-stash-checked-output arguments))))
    (when (> (length files) *legit-stash-candidate-limit*)
      (editor-error "Git returned more than ~d stash paths."
                    *legit-stash-candidate-limit*))
    files))

(defun legit-stash-staged-p ()
  (multiple-value-bind (output error-output status)
      (legit-stash-run-program '("diff" "--cached" "--quiet" "--"))
    (declare (ignore output error-output))
    (eql status 1)))

(defun legit-stash-worktree-p ()
  (multiple-value-bind (output error-output status)
      (legit-stash-run-program '("diff" "--quiet" "--"))
    (declare (ignore output error-output))
    (eql status 1)))

(defun legit-stash-untracked-files (include)
  (case include
    (:untracked
     (legit-stash-bounded-files
      '("ls-files" "-z" "--others" "--exclude-standard" "--")))
    (:all
     (remove-duplicates
      (append
       (legit-stash-bounded-files
        '("ls-files" "-z" "--others" "--exclude-standard" "--"))
       (legit-stash-bounded-files
        '("ls-files" "-z" "--others" "--ignored"
          "--exclude-standard" "--")))
      :test #'string=))))

(defun legit-stash-head ()
  (or (legit-stash-optional-output
       '("rev-parse" "--verify" "HEAD^{commit}"))
      (editor-error "A stash requires an initial commit.")))

(defun legit-stash-default-message ()
  (let ((branch (or (legit-branch-current) "(no branch)"))
        (summary
          (or (legit-stash-optional-output
               '("log" "-1" "--format=%h %s"))
              "HEAD")))
    (format nil "On ~a: ~a" branch summary)))

(defun legit-stash-message-valid-p (message)
  (and (<= (length message) *legit-stash-value-limit*)
       (not (find (code-char 0) message))))

(defun legit-stash-read-message ()
  (let ((message
          (prompt-for-string
           "Stash message: "
           :history-symbol '*legit-stash-message-history*
           :test-function #'legit-stash-message-valid-p)))
    (and message
         (if (str:blankp message)
             (legit-stash-default-message)
             message))))

(defun legit-stash-commit-tree (tree parents message)
  (str:trim
   (legit-stash-checked-output
    (append (list "-c" "commit.gpgsign=false" "commit-tree" tree)
            (mapcan (lambda (parent) (list "-p" parent)) parents)
            (list "-m" message)))))

(defun legit-stash-call-with-temporary-index (tree function)
  "Call FUNCTION with a child environment containing a temporary index."
  (uiop:with-temporary-file (:pathname path :stream stream)
    (close stream)
    (delete-file path)
    (let ((environment
            (legit-rebase-child-environment
             "GIT_INDEX_FILE" (uiop:native-namestring path))))
      (legit-stash-checked-output
       (if tree (list "read-tree" tree) '("read-tree" "--empty"))
       :environment environment)
      (funcall function environment))))

(defun legit-stash-index-tree ()
  (str:trim (legit-stash-checked-output '("write-tree"))))

(defun legit-stash-commit-index (message parent)
  (legit-stash-commit-tree (legit-stash-index-tree)
                           (and parent (list parent))
                           message))

(defun legit-stash-untracked-commit (files summary)
  (when files
    (legit-stash-call-with-temporary-index
     nil
     (lambda (environment)
       (legit-stash-checked-output
        (append '("add" "--force" "--") files)
        :environment environment)
       (let ((tree
               (str:trim
                (legit-stash-checked-output '("write-tree")
                                             :environment environment))))
         (legit-stash-commit-tree
          tree nil (format nil "untracked files on ~a" summary)))))))

(defun legit-stash-worktree-tree (index-commit comparison-parent worktree-p)
  (legit-stash-call-with-temporary-index
   index-commit
   (lambda (environment)
     (when worktree-p
       (let ((files
               (legit-stash-bounded-files
                (list "diff" "-z" "--name-only" comparison-parent "--"))))
         (when files
           (legit-stash-checked-output
            (append '("add" "--update" "--") files)
            :environment environment))))
     (str:trim
      (legit-stash-checked-output '("write-tree")
                                   :environment environment)))))

(defun legit-stash-store (revision message &optional ref)
  (let* ((ref (or ref "refs/stash"))
         (old (legit-stash-optional-output
               (list "rev-parse" "--verify" ref))))
    (legit-stash-checked-output
     (append (list "update-ref" "--create-reflog" "-m" message
                   ref revision)
             (and old (list old))))))

(defun legit-stash-clean-untracked (include)
  (when include
    (legit-stash-checked-output
     (append '("clean" "--force" "-d")
             (and (eq include :all) '("-x"))
             '("--")))))

(defun legit-stash-clean-index-only (patch)
  (legit-stash-checked-output
   '("apply" "--reverse" "--cached" "--ignore-space-change" "-")
   :input patch)
  (legit-stash-checked-output
   '("apply" "--reverse" "--ignore-space-change" "-")
   :input patch))

(defun legit-stash-clean-after-save (keep include staged-p)
  (ecase keep
    (:snapshot nil)
    (:worktree
     (unless staged-p
       (editor-error "There are no staged changes to stash."))
     (let ((patch
             (legit-stash-checked-output
              '("diff" "--cached" "--binary" "--no-ext-diff" "--"))))
       (legit-stash-clean-index-only patch)))
    (:index
     (legit-stash-checked-output '("checkout" "--" "."))
     (legit-stash-clean-untracked include))
    (:none
     (legit-stash-checked-output '("reset" "--hard" "HEAD"))
     (legit-stash-clean-untracked include))))

(defun legit-stash-save (message index-p worktree-p include keep)
  "Create a Magit-shaped stash and clean according to KEEP."
  (let* ((staged-p (legit-stash-staged-p))
         (unstaged-p (legit-stash-worktree-p))
         (untracked (legit-stash-untracked-files include)))
    (unless (or (and index-p staged-p)
                (and worktree-p unstaged-p)
                untracked)
      (editor-error "There are no eligible changes to stash."))
    (let* ((head (legit-stash-head))
           (summary
             (format nil "~a: ~a"
                     (or (legit-branch-current) "(no branch)")
                     (or (legit-stash-optional-output
                          '("log" "-1" "--format=%h %s"))
                         "HEAD")))
           (comparison-parent
             (if (and worktree-p (not index-p))
                 (legit-stash-commit-index "pre-stash index" head)
                 head))
           (index-commit
             (legit-stash-commit-index
              (format nil "index on ~a" summary) comparison-parent))
           (untracked-commit
             (legit-stash-untracked-commit untracked summary))
           (tree
             (legit-stash-worktree-tree
              index-commit comparison-parent worktree-p))
           (revision
             (legit-stash-commit-tree
              tree
              (remove nil
                      (list comparison-parent index-commit
                            untracked-commit))
              message)))
      (legit-stash-store revision message)
      (legit-stash-clean-after-save keep include staged-p)
      (lem/legit::show-legit-status)
      revision)))

(defun legit-stash-create (options index-p worktree-p keep description)
  (alexandria:when-let ((message (legit-stash-read-message)))
    (let ((include (and worktree-p
                        (legit-stash-options-include options))))
      (when (and (eq keep :none)
                 (legit-git-metadata-path-exists-p "MERGE_HEAD")
                 (not (prompt-for-y-or-n-p
                       "Stashing during a merge loses merge state; proceed? ")))
        (message "Stash cancelled.")
        (return-from legit-stash-create nil))
      (legit-stash-save message index-p worktree-p include keep)
      (message "~a created." description)
      t)))

(defun legit-stash-list-entries ()
  (let ((lines
          (remove-if
           #'str:blankp
           (str:lines
            (legit-stash-checked-output
             '("stash" "list" "--format=%gd%x09%gs"))))))
    (when (> (length lines) *legit-stash-candidate-limit*)
      (editor-error "Git returned more than ~d stashes."
                    *legit-stash-candidate-limit*))
    (mapcar
     (lambda (line)
       (let ((tab (position #\Tab line)))
         (unless tab
           (editor-error "Git returned an invalid stash list entry."))
         (cons (subseq line 0 tab) line)))
     lines)))

(defun legit-stash-read (prompt)
  (let* ((entries (legit-stash-list-entries))
         (references (mapcar #'car entries)))
    (unless references
      (editor-error "There are no stashes."))
    (let ((reference
            (prompt-for-string
             prompt
             :initial-value (if (= (length references) 1)
                                (first references)
                                "")
             :history-symbol '*legit-stash-reference-history*
             :completion-function
             (lambda (query)
               (completion-strings query references))
             :test-function
             (lambda (input)
               (member input references :test #'string=)))))
      reference)))

(defun legit-stash-apply (pop-p)
  (alexandria:when-let
      ((stash (legit-stash-read (if pop-p "Pop stash: " "Apply stash: "))))
    (legit-stash-run
     (list "stash" (if pop-p "pop" "apply") "--index" stash)
     (format nil "~:[Applied~;Popped~] ~a." pop-p stash)
     :conflict-is-result-p t)))

(defun legit-stash-drop ()
  (alexandria:when-let ((stash (legit-stash-read "Drop stash: ")))
    (when (prompt-for-y-or-n-p (format nil "Drop ~a? " stash))
      (legit-stash-run (list "stash" "drop" stash)
                       (format nil "Dropped ~a." stash)))))

(defun legit-stash-list ()
  (let ((entries (legit-stash-list-entries)))
    (if entries
        (lem/legit::pop-up-message
         (format nil "~{~a~^~%~}" (mapcar #'cdr entries)))
        (message "There are no stashes."))))

(defun legit-stash-show ()
  (alexandria:when-let ((stash (legit-stash-read "Show stash: ")))
    (lem/legit::show-diff
     (legit-stash-checked-output
      (list "stash" "show" "--stat" "--patch" stash)))))

(defun legit-stash-read-branch (prompt)
  (let ((branch
          (prompt-for-string
           prompt
           :history-symbol '*legit-stash-branch-history*
           :test-function #'legit-branch-name-valid-p)))
    (when branch
      (when (member branch (legit-branch-local-branches) :test #'string=)
        (editor-error "Local branch ~a already exists." branch))
      branch)))

(defun legit-stash-branch (here-p)
  (alexandria:when-let ((stash (legit-stash-read "Branch from stash: ")))
    (alexandria:when-let
        ((branch (legit-stash-read-branch "New branch name: ")))
      (if here-p
          (when (legit-stash-run
                 (list "checkout" "-b" branch)
                 (format nil "Created and checked out ~a." branch))
            (legit-stash-run
             (list "stash" "apply" "--index" stash)
             (format nil "Applied ~a on ~a." stash branch)
             :conflict-is-result-p t))
          (legit-stash-run
           (list "stash" "branch" branch stash)
           (format nil "Created ~a from ~a." branch stash))))))

(defun legit-stash-format-patch ()
  (alexandria:when-let
      ((stash (legit-stash-read "Create patch from stash: ")))
    (let* ((name
             (str:trim
              (legit-stash-checked-output
               (list "log" "-1" "--format=0001-%f.patch" stash))))
           (path (merge-pathnames name (uiop:ensure-directory-pathname
                                       (uiop:getcwd)))))
      (when (and (probe-file path)
                 (not (prompt-for-y-or-n-p
                       (format nil "Overwrite ~a? " name))))
        (message "Patch creation cancelled.")
        (return-from legit-stash-format-patch nil))
      (with-open-file (stream path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
        (write-string
         (legit-stash-checked-output
          (list "stash" "show" "--patch" stash))
         stream))
      (message "Created ~a." (uiop:native-namestring path))
      path)))

(defun legit-stash-wip-ref (kind)
  (let ((head (or (legit-stash-optional-output
                   '("symbolic-ref" "--quiet" "HEAD"))
                  "HEAD")))
    (format nil "refs/wip/~a/~a" kind head)))

(defun legit-stash-ensure-wip-ref (ref kind)
  (let ((existing (legit-stash-optional-output
                   (list "rev-parse" "--verify" ref)))
        (head (legit-stash-head)))
    (if (and existing
             (string= head
                      (or (legit-stash-optional-output
                           (list "merge-base" existing head)) "")))
        existing
        (let* ((message (format nil "start autosaving ~a" kind))
               (tree
                 (str:trim
                  (legit-stash-checked-output
                   (list "rev-parse" (format nil "~a^{tree}" head)))))
               (revision
                 (legit-stash-commit-tree tree (list head) message)))
          (legit-stash-store revision message ref)
          revision))))

(defun legit-stash-update-wip-ref (ref parent tree message)
  (let* ((parent-tree
           (str:trim
            (legit-stash-checked-output
             (list "rev-parse" (format nil "~a^{tree}" parent)))))
         (revision
           (unless (string= parent-tree tree)
             (legit-stash-commit-tree tree (list parent) message))))
    (when revision
      (legit-stash-store revision message ref))
    revision))

(defun legit-stash-wip-commit ()
  (let* ((message "wip-save tracked files")
         (index-ref (legit-stash-wip-ref "index"))
         (worktree-ref (legit-stash-wip-ref "wtree"))
         (index-parent (legit-stash-ensure-wip-ref index-ref "index"))
         (index-tree (legit-stash-index-tree))
         (index-revision
           (legit-stash-update-wip-ref
            index-ref index-parent index-tree message))
         (worktree-parent
           (legit-stash-ensure-wip-ref worktree-ref "worktree"))
         (worktree-tree
           (legit-stash-call-with-temporary-index
            worktree-parent
            (lambda (environment)
              (legit-stash-checked-output '("add" "--update" "--" ".")
                                           :environment environment)
              (str:trim
               (legit-stash-checked-output '("write-tree")
                                            :environment environment)))))
         (worktree-revision
           (legit-stash-update-wip-ref
            worktree-ref worktree-parent worktree-tree message)))
    (lem/legit::show-legit-status)
    (if (or index-revision worktree-revision)
        (message "Saved tracked changes to WIP refs.")
        (message "WIP refs already match tracked changes."))))

(defun legit-stash-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-stash-popup-keymap (options)
  (let ((keymap (make-keymap :description "Stash"))
        (include (legit-stash-options-include options)))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(("- u" ,(format nil "[~a] include untracked"
                             (if (eq include :untracked) "x" " ")))
            ("- a" ,(format nil "[~a] include ignored and untracked"
                             (if (eq include :all) "x" " ")))
            ("z" "stash index and worktree")
            ("i" "stash index")
            ("w" "stash worktree")
            ("x" "stash keeping index")
            ("Z" "snapshot index and worktree")
            ("I" "snapshot index")
            ("W" "snapshot worktree")
            ("r" "save tracked changes to WIP refs")
            ("a" "apply stash")
            ("p" "pop stash")
            ("k" "drop stash")
            ("l" "list stashes")
            ("v" "show stash")
            ("b" "branch from stash base")
            ("B" "branch here and apply stash")
            ("f" "format stash as patch")
            ("q" "cancel")))
      (legit-stash-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-stash-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (string= name "-")
        (format nil "- ~a"
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun dispatch-legit-stash ()
  "Display and execute the configured Evil Collection Magit stash dispatch."
  (let ((options (make-legit-stash-options)))
    (unwind-protect
         (loop
           :for keymap := (legit-stash-popup-keymap options)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-stash-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Stash dispatch cancelled.")
                   (return nil))
                  ((string= name "- u")
                   (setf (legit-stash-options-include options)
                         (unless (eq (legit-stash-options-include options)
                                     :untracked)
                           :untracked)))
                  ((string= name "- a")
                   (setf (legit-stash-options-include options)
                         (unless (eq (legit-stash-options-include options) :all)
                           :all)))
                  ((string= name "z")
                   (legit-stash-create options t t :none "Stash")
                   (return t))
                  ((string= name "i")
                   (legit-stash-create options t nil :worktree "Index stash")
                   (return t))
                  ((string= name "w")
                   (legit-stash-create options nil t :index "Worktree stash")
                   (return t))
                  ((string= name "x")
                   (legit-stash-create options t t :index "Index-preserving stash")
                   (return t))
                  ((string= name "Z")
                   (legit-stash-create options t t :snapshot "Snapshot")
                   (return t))
                  ((string= name "I")
                   (legit-stash-create options t nil :snapshot "Index snapshot")
                   (return t))
                  ((string= name "W")
                   (legit-stash-create options nil t :snapshot "Worktree snapshot")
                   (return t))
                  ((string= name "r") (legit-stash-wip-commit) (return t))
                  ((string= name "a") (legit-stash-apply nil) (return t))
                  ((string= name "p") (legit-stash-apply t) (return t))
                  ((string= name "k") (legit-stash-drop) (return t))
                  ((string= name "l") (legit-stash-list) (return t))
                  ((string= name "v") (legit-stash-show) (return t))
                  ((string= name "b") (legit-stash-branch nil) (return t))
                  ((string= name "B") (legit-stash-branch t) (return t))
                  ((string= name "f") (legit-stash-format-patch) (return t))
                  (t
                   (message "No stash action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-stash () ()
  "Open the configured Evil Collection Magit stash dispatch."
  (lem/legit::with-current-project (vcs)
    (legit-stash-require-git vcs)
    (dispatch-legit-stash)))

(define-key lem/legit::*peek-legit-keymap* "z" 'lem-yath-legit-stash)
(define-key lem/legit::*legit-diff-mode-keymap* "z" 'lem-yath-legit-stash)
