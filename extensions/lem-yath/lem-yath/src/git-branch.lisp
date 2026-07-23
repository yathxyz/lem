;;;; Evil-Collection-compatible Magit branch dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-branch-timeout* 120)
(defparameter *legit-branch-output-limit* (* 4 1024 1024))
(defparameter *legit-branch-candidate-limit* 5000)
(defparameter *legit-branch-value-limit* 4096)

(defvar *legit-branch-name-history* nil)
(defvar *legit-branch-revision-history* nil)
(defvar *legit-branch-config-history* nil)

(defstruct legit-branch-options
  recurse-submodules-p)

(defun legit-branch-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Branch commands are available only in a Git repository.")))

(defun legit-branch-run-program (arguments)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-branch-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :output-limit *legit-branch-output-limit*)))

(defun legit-branch-checked-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-branch-run-program arguments)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-branch-run (arguments success-message)
  "Run Git ARGUMENTS, refresh Legit, and report the result."
  (multiple-value-bind (output error-output status)
      (legit-branch-run-program arguments)
    (lem/legit::show-legit-status)
    (if (and (integerp status) (zerop status))
        (progn
          (message "~a" success-message)
          t)
        (progn
          (lem/legit::pop-up-message
           (legit-command-error-text output error-output))
          nil))))

(defun legit-branch-optional-output (arguments)
  "Return trimmed output, or NIL for an ordinary missing scalar."
  (multiple-value-bind (output error-output status)
      (legit-branch-run-program arguments)
    (cond
      ((and (integerp status) (zerop status)
            (str:non-blank-string-p output))
       (str:trim output))
      ((or (eql status 1)
           (and (integerp status) (zerop status)))
       nil)
      (t
       (editor-error "~a"
                     (legit-command-error-text output error-output))))))

(defun legit-branch-lines (arguments)
  (let ((lines
          (remove-if #'str:blankp
                     (str:lines (legit-branch-checked-output arguments)))))
    (when (> (length lines) *legit-branch-candidate-limit*)
      (editor-error "Git returned more than ~d branch candidates."
                    *legit-branch-candidate-limit*))
    lines))

(defun legit-branch-current ()
  (legit-branch-optional-output
   '("symbolic-ref" "--quiet" "--short" "HEAD")))

(defun legit-branch-local-branches ()
  (legit-branch-lines
   '("for-each-ref" "--format=%(refname:short)" "refs/heads")))

(defun legit-branch-remote-branches ()
  (remove-if
   (lambda (branch) (alexandria:ends-with-subseq "/HEAD" branch))
   (legit-branch-lines
    '("for-each-ref" "--format=%(refname:short)" "refs/remotes"))))

(defun legit-branch-remotes ()
  (legit-branch-lines '("remote")))

(defun legit-branch-config-value (key)
  (legit-branch-optional-output (list "config" "--get" key)))

(defun legit-branch-set-config (key value)
  "Set KEY to VALUE, or remove it when VALUE is NIL."
  (if value
      (legit-branch-checked-output (list "config" key value))
      (when (legit-branch-config-value key)
        (legit-branch-checked-output
         (list "config" "--unset-all" key))))
  (lem/legit::show-legit-status))

(defun legit-branch-name-valid-p (name)
  (and (str:non-blank-string-p name)
       (<= (length name) *legit-branch-value-limit*)
       (multiple-value-bind (output error-output status)
           (legit-branch-run-program
            (list "check-ref-format" "--branch" name))
         (declare (ignore output error-output))
         (and (integerp status) (zerop status)))))

(defun legit-branch-read-new-name (prompt &optional initial-value)
  (let ((name
          (prompt-for-string
           prompt
           :initial-value (or initial-value "")
           :history-symbol '*legit-branch-name-history*
           :test-function #'legit-branch-name-valid-p)))
    (when name
      (when (member name (legit-branch-local-branches) :test #'string=)
        (editor-error "Local branch ~a already exists." name))
      name)))

(defun legit-branch-read-local (prompt &key include-current-p initial-value)
  (let* ((current (legit-branch-current))
         (branches
           (if include-current-p
               (legit-branch-local-branches)
               (remove current (legit-branch-local-branches)
                       :test #'string=))))
    (unless branches
      (editor-error "There is no eligible local branch."))
    (prompt-for-string
     prompt
     :initial-value (or initial-value
                        (and include-current-p current)
                        "")
     :history-symbol '*legit-branch-name-history*
     :completion-function
     (lambda (query) (completion-strings query branches))
     :test-function
     (lambda (input) (member input branches :test #'string=)))))

(defun legit-branch-read-revision (prompt &optional initial-value)
  "Read one verified revision while retaining its user-facing name."
  (multiple-value-bind (hash name)
      (legit-reset-read-revision prompt initial-value)
    (declare (ignore hash))
    name))

(defun legit-branch-default-start ()
  (or (text-property-at (current-point) :commit-hash)
      (legit-branch-current)
      "HEAD"))

(defun legit-branch-checkout-arguments (options)
  (when (legit-branch-options-recurse-submodules-p options)
    '("--recurse-submodules")))

(defun legit-branch-read-checkout-revision ()
  (let* ((choices
           (remove-duplicates
            (append (legit-branch-local-branches)
                    (legit-branch-remote-branches)
                    (mapcar #'car (legit-reset-revision-candidates)))
            :test #'string=))
         (input
           (prompt-for-string
            "Checkout branch or revision: "
            :history-symbol '*legit-branch-revision-history*
            :completion-function
            (lambda (query) (completion-strings query choices)))))
    (when input
      (legit-reset-normalize-revision input)
      input)))

(defun legit-branch-checkout-revision (options)
  (alexandria:when-let ((revision (legit-branch-read-checkout-revision)))
    (legit-branch-run
     (append (list "checkout")
             (legit-branch-checkout-arguments options)
             (list revision))
     (format nil "Checked out ~a." revision))))

(defun legit-branch-remote-parts (branch)
  (alexandria:when-let ((slash (position #\/ branch)))
    (values (subseq branch 0 slash)
            (subseq branch (1+ slash)))))

(defun legit-branch-tracking-candidates ()
  "Return local and non-shadowed remote branches for Magit's local reader."
  (let* ((current (legit-branch-current))
         (all-locals (legit-branch-local-branches))
         (locals (remove current all-locals
                         :test #'string=))
         (remote
           (remove-if
            (lambda (branch)
                (multiple-value-bind (remote name)
                  (legit-branch-remote-parts branch)
                (declare (ignore remote))
                (member name all-locals :test #'string=)))
            (legit-branch-remote-branches))))
    (append locals remote)))

(defun legit-branch-checkout-local (options)
  "Checkout an existing local/remote branch or create a typed new branch."
  (let* ((locals (legit-branch-local-branches))
         (remotes (legit-branch-remote-branches))
         (choices (legit-branch-tracking-candidates))
         (input
           (prompt-for-string
            "Checkout local branch: "
            :history-symbol '*legit-branch-name-history*
            :completion-function
            (lambda (query) (completion-strings query choices)))))
    (when input
      (cond
        ((member input locals :test #'string=)
         (legit-branch-run
          (append (list "checkout")
                  (legit-branch-checkout-arguments options)
                  (list input))
          (format nil "Checked out ~a." input)))
        ((member input remotes :test #'string=)
         (multiple-value-bind (remote name)
             (legit-branch-remote-parts input)
           (when (member name locals :test #'string=)
             (editor-error "Local branch ~a already exists." name))
           (when (legit-branch-run
                  (append (list "checkout")
                          (legit-branch-checkout-arguments options)
                          (list "-b" name "--track" input))
                  (format nil "Created and checked out ~a." name))
             (unless (string= remote
                              (or (legit-branch-config-value
                                   "remote.pushDefault")
                                  ""))
               (legit-branch-set-config
                (format nil "branch.~a.pushRemote" name) remote)))))
        ((legit-branch-name-valid-p input)
         (alexandria:when-let
             ((start
                (legit-branch-read-revision
                 "Create branch starting at: "
                 (legit-branch-default-start))))
           (legit-branch-run
            (append (list "checkout")
                    (legit-branch-checkout-arguments options)
                    (list "-b" input start))
            (format nil "Created and checked out ~a." input))))
        (t
         (editor-error "Select a branch or enter a valid new branch name."))))))

(defun legit-branch-read-create-arguments (prompt)
  "Read Magit's configured upstream-first branch creation arguments."
  (alexandria:when-let
      ((start (legit-branch-read-revision
               (format nil "~a starting at: " prompt)
               (legit-branch-default-start))))
    (alexandria:when-let
        ((name (legit-branch-read-new-name
                (format nil "Name for ~a: " (string-downcase prompt)))))
      (list name start))))

(defun legit-branch-create (options checkout-p)
  (alexandria:when-let
      ((arguments
         (legit-branch-read-create-arguments
          (if checkout-p "Create and checkout branch" "Create branch"))))
    (destructuring-bind (name start) arguments
      (legit-branch-run
       (if checkout-p
           (append (list "checkout")
                   (legit-branch-checkout-arguments options)
                   (list "-b" name start))
           (list "branch" name start))
       (format nil "Created~:[~; and checked out~] ~a."
               checkout-p name)))))

(defun legit-branch-orphan (options)
  (alexandria:when-let
      ((arguments
         (legit-branch-read-create-arguments
          "Create and checkout orphan branch")))
    (destructuring-bind (name start) arguments
      (legit-branch-run
       (append (list "checkout")
               (legit-branch-checkout-arguments options)
               (list "--orphan" name start))
       (format nil "Created orphan branch ~a." name)))))

(defun legit-branch-ancestor-p (ancestor descendant)
  (multiple-value-bind (output error-output status)
      (legit-branch-run-program
       (list "merge-base" "--is-ancestor" ancestor descendant))
    (declare (ignore output))
    (cond
      ((eql status 0) t)
      ((eql status 1) nil)
      (t (editor-error "~a"
                       (legit-command-error-text "" error-output))))))

(defun legit-branch-spin (checkout-p)
  "Implement Magit's ordinary spin-off or spin-out branch lifecycle."
  (let* ((current (or (legit-branch-current)
                      (editor-error "Spin-off requires a current branch.")))
         (selected (legit-log-selected-commits 64))
         (from (car (last selected))))
    (alexandria:when-let
        ((name
           (legit-branch-read-new-name
            (if checkout-p "Spin off branch: " "Spin out branch: "))))
      (let* ((requested-checkout-p checkout-p)
             (dirty-p (legit-reset-tracked-changes-p))
             (checkout-p (or checkout-p dirty-p))
             (upstream (legit-reset-upstream current))
             (base
               (cond
                 (from
                  (unless (legit-branch-ancestor-p from current)
                    (editor-error
                     "Selected spin boundary is not reachable from ~a."
                     current))
                  (when (and upstream
                             (legit-branch-ancestor-p from upstream))
                    (editor-error
                     "Selected spin boundary is already in upstream ~a."
                     upstream))
                  (or (legit-branch-optional-output
                       (list "rev-parse" (format nil "~a^" from)))
                      (editor-error
                       "The oldest selected commit has no parent.")))
                 (upstream
                  (legit-branch-optional-output
                   (list "merge-base" current upstream))))))
        (when (and dirty-p (not requested-checkout-p))
          (message "Staying on the new branch due to uncommitted changes."))
        (legit-branch-checked-output
         (if checkout-p
             (list "checkout" "-b" name current)
             (list "branch" name current)))
        (when upstream
          (legit-branch-checked-output
           (list "branch" (format nil "--set-upstream-to=~a" upstream)
                 name)))
        (when (and base (not (string= base
                                     (str:trim
                                      (legit-branch-checked-output
                                       (list "rev-parse" current))))))
          (if checkout-p
              (legit-branch-checked-output
               (list "update-ref" "-m"
                     (format nil "reset: moving to ~a" base)
                     (format nil "refs/heads/~a" current) base))
              (legit-branch-checked-output
               (list "reset" "--hard" base))))
        (lem/legit::show-legit-status)
        (message "~:[Spun out~;Spun off and checked out~] ~a."
                 checkout-p name)
        t))))

(defun legit-branch-ref-exists-p (ref)
  "Return whether exact REF exists, rejecting unexpected Git failures."
  (multiple-value-bind (output error-output status)
      (legit-branch-run-program (list "show-ref" "--verify" "--quiet" ref))
    (declare (ignore output))
    (cond
      ((eql status 0) t)
      ((eql status 1) nil)
      (t (editor-error "~a"
                       (legit-command-error-text "" error-output))))))

(defun legit-branch-push-remote-for (branch)
  "Return BRANCH's explicit or repository push remote when configured."
  (let ((remote
          (or (legit-branch-config-value
               (format nil "branch.~a.pushRemote" branch))
              (legit-branch-config-value "remote.pushDefault"))))
    (and (member remote (legit-branch-remotes) :test #'string=)
         remote)))

(defun legit-branch-rename-remote-target-p (remote old new)
  "Return whether OLD has a push target on REMOTE and NEW does not."
  (and remote
       (legit-branch-ref-exists-p
        (format nil "refs/remotes/~a/~a" remote old))
       (not (legit-branch-ref-exists-p
             (format nil "refs/remotes/~a/~a" remote new)))))

(defun legit-branch-rename ()
  (alexandria:when-let
      ((old (legit-branch-read-local
             "Rename branch: " :include-current-p t)))
    (alexandria:when-let
        ((new (legit-branch-read-new-name
               (format nil "Rename branch '~a' to: " old))))
      (when (string= old new)
        (editor-error "Old and new branch names are the same."))
      (let* ((push-remote (legit-branch-push-remote-for old))
             (rename-remote-p
               (legit-branch-rename-remote-target-p push-remote old new)))
        (legit-branch-checked-output (list "branch" "-m" old new))
        (if (and rename-remote-p
                 (prompt-for-y-or-n-p
                  (format nil "Also rename ~a to ~a on ~a? "
                          old new push-remote)))
            (legit-branch-run
             (list "push" "--verbose" "--" push-remote
                   (format nil "refs/remotes/~a/~a:refs/heads/~a"
                           push-remote old new)
                   (format nil ":refs/heads/~a" old))
             (format nil "Renamed ~a to ~a locally and on ~a."
                     old new push-remote))
            (progn
              (lem/legit::show-legit-status)
              (message "Renamed ~a to ~a locally." old new)
              t))))))

(defun legit-branch-git-path (relative)
  "Return Git's repository path for RELATIVE as an absolute pathname."
  (let* ((value
           (str:trim
            (legit-branch-checked-output
             (list "rev-parse" "--git-path" relative))))
         (path (pathname value)))
    (if (uiop:absolute-pathname-p path)
        path
        (merge-pathnames path
                         (uiop:ensure-directory-pathname (uiop:getcwd))))))

(defun legit-branch-rename-reflog (old-ref new-ref)
  "Move OLD-REF's reflog to NEW-REF when one exists."
  (let ((old (legit-branch-git-path (format nil "logs/~a" old-ref)))
        (new (legit-branch-git-path (format nil "logs/~a" new-ref))))
    (when (probe-file old)
      (ensure-directories-exist new)
      (uiop:rename-file-overwriting-target old new))))

(defun legit-branch-shelved-branches ()
  (legit-branch-lines
   '("for-each-ref" "--format=%(refname:strip=2)" "refs/shelved")))

(defun legit-branch-shelve ()
  "Move another local branch and its reflog below refs/shelved."
  (alexandria:when-let
      ((branch (legit-branch-read-local "Shelve branch: ")))
    (let* ((old (format nil "refs/heads/~a" branch))
           (date
             (str:trim
              (legit-branch-checked-output
               (list "show" "-s" "--format=%cs" branch))))
           (new (format nil "refs/shelved/~a-~a" date branch)))
      (legit-branch-checked-output (list "update-ref" new old ""))
      (legit-branch-rename-reflog old new)
      (when (legit-branch-config-value
             (format nil "branch.~a.pushRemote" branch))
        (legit-branch-checked-output
         (list "config" "--unset-all"
               (format nil "branch.~a.pushRemote" branch))))
      (legit-branch-run
       (list "branch" "-D" branch)
       (format nil "Shelved ~a as ~a-~a." branch date branch)))))

(defun legit-branch-date-prefix-p (name)
  (and (>= (length name) 11)
       (every #'digit-char-p (subseq name 0 4))
       (char= (char name 4) #\-)
       (every #'digit-char-p (subseq name 5 7))
       (char= (char name 7) #\-)
       (every #'digit-char-p (subseq name 8 10))
       (char= (char name 10) #\-)))

(defun legit-branch-unshelved-name (shelved)
  (if (legit-branch-date-prefix-p shelved)
      (subseq shelved 11)
      shelved))

(defun legit-branch-unshelve ()
  "Restore one refs/shelved entry and its reflog as a local branch."
  (let ((shelved (legit-branch-shelved-branches)))
    (unless shelved
      (editor-error "There is no shelved branch."))
    (alexandria:when-let
        ((branch
           (prompt-for-string
            "Unshelve branch: "
            :history-symbol '*legit-branch-name-history*
            :completion-function
            (lambda (query) (completion-strings query shelved))
            :test-function
            (lambda (value) (member value shelved :test #'string=)))))
      (let* ((name (legit-branch-unshelved-name branch))
             (old (format nil "refs/shelved/~a" branch))
             (new (format nil "refs/heads/~a" name)))
        (unless (legit-branch-name-valid-p name)
          (editor-error "Shelved ref ~a does not produce a valid branch name."
                        branch))
        (when (legit-branch-ref-exists-p new)
          (editor-error "Local branch ~a already exists." name))
        (legit-branch-checked-output (list "update-ref" new old ""))
        (legit-branch-rename-reflog old new)
        (legit-branch-checked-output (list "update-ref" "-d" old))
        (lem/legit::show-legit-status)
        (message "Unshelved ~a as ~a." branch name)
        t))))

(defun legit-branch-primary-remote ()
  "Return Magit's configured primary remote, if present."
  (let ((remotes (legit-branch-remotes)))
    (find-if
     (lambda (remote) (member remote remotes :test #'string=))
     (remove-duplicates
      (remove nil
              (list (legit-branch-config-value "magit.primaryRemote")
                    "upstream" "origin"))
      :test #'string=))))

(defun legit-branch-default-name (remote)
  "Return REMOTE's locally recorded default branch name."
  (let* ((prefix (format nil "~a/" remote))
         (value
           (legit-branch-optional-output
            (list "symbolic-ref" "--quiet" "--short"
                  (format nil "refs/remotes/~a/HEAD" remote)))))
    (and value
         (alexandria:starts-with-subseq prefix value)
         (subseq value (length prefix)))))

(defun legit-branch-upstream-rows ()
  "Return local branch and upstream pairs."
  (mapcar
   (lambda (line)
     (let ((tab (position #\Tab line)))
       (list (if tab (subseq line 0 tab) line)
             (and tab (< tab (1- (length line)))
                  (subseq line (1+ tab))))))
   (legit-branch-lines
    '("for-each-ref" "--format=%(refname:short)%09%(upstream:short)"
      "refs/heads"))))

(defun legit-branch-set-default-locally (remote old new)
  "Rename OLD to NEW when possible and migrate affected upstreams."
  (let ((rows (legit-branch-upstream-rows)))
    (when (and (assoc old rows :test #'string=)
               (not (assoc new rows :test #'string=)))
      (legit-branch-checked-output (list "branch" "-m" old new))
      (setf (car (assoc old rows :test #'string=)) new))
    (let ((new-upstream
            (if (assoc new rows :test #'string=)
                new
                (format nil "~a/~a" remote new))))
      (dolist (row rows)
        (destructuring-bind (branch upstream) row
          (cond
            ((and upstream (string= upstream old))
             (legit-branch-checked-output
              (list "branch" (format nil "--set-upstream-to=~a"
                                     new-upstream)
                    branch)))
            ((and upstream
                  (string= upstream (format nil "~a/~a" remote old)))
             (legit-branch-checked-output
              (list "branch"
                    (format nil "--set-upstream-to=~a/~a" remote new)
                    branch)))))))))

(defun legit-branch-update-default ()
  "Refresh the primary remote's HEAD and migrate matching local names."
  (let* ((remote (or (legit-branch-primary-remote)
                     (editor-error "Cannot determine a primary remote.")))
         (old (legit-branch-default-name remote)))
    (legit-branch-checked-output '("fetch" "--prune"))
    (legit-branch-checked-output
     (list "remote" "set-head" "--auto" remote))
    (let ((new (or (legit-branch-default-name remote)
                   (editor-error "Cannot determine the new default branch."))))
      (cond
        ((and old (string= old new))
         (alexandria:when-let
             ((replaced
                (prompt-for-string
                 (format nil "Default is still ~a; old upstream branch to replace: "
                         new)
                 :initial-value "master"
                 :history-symbol '*legit-branch-name-history*
                 :test-function #'legit-branch-name-valid-p)))
           (legit-branch-set-default-locally remote replaced new)
           (lem/legit::show-legit-status)
           (message "Updated upstreams from ~a to ~a." replaced new)
           t))
        (t
         (let ((old
                 (or old
                     (legit-branch-read-local
                      (format nil "Old default branch to rename to ~a: " new)
                      :include-current-p t
                      :initial-value "master"))))
           (when (prompt-for-y-or-n-p
                  (format nil
                          "Default changed from ~a to ~a on ~a; do the same locally? "
                          old new remote))
             (legit-branch-set-default-locally remote old new)
             (lem/legit::show-legit-status)
             (message "Updated the local default branch from ~a to ~a."
                      old new)
             t)))))))

(defun legit-branch-main-candidate (current)
  (find-if
   (lambda (name)
     (and (not (string= name current))
          (member name (legit-branch-local-branches) :test #'string=)))
   '("main" "master" "trunk" "develop")))

(defun legit-branch-delete-current-target (branch)
  (let* ((locals (remove branch (legit-branch-local-branches)
                         :test #'string=))
         (default (legit-branch-main-candidate branch))
         (choices (append locals '("<detach>")))
         (input
           (prompt-for-string
            (format nil "Branch ~a is checked out; switch before deleting: "
                    branch)
            :initial-value (or default "<detach>")
            :history-symbol '*legit-branch-name-history*
            :completion-function
            (lambda (query) (completion-strings query choices))
            :test-function
            (lambda (value) (member value choices :test #'string=)))))
    input))

(defun legit-branch-delete-aliases (choices remotes)
  "Return safe short-name aliases for remote-tracking branch choices."
  (let ((pairs
          (mapcar
           (lambda (tracking)
             (multiple-value-bind (remote branch)
                 (legit-branch-remote-parts tracking)
               (declare (ignore remote))
               (cons branch tracking)))
           remotes)))
    (remove-if
     (lambda (pair)
       (or (null (car pair))
           (member (car pair) choices :test #'string=)
           (> (count (car pair) pairs :key #'car :test #'string=) 1)))
     pairs)))

(defun legit-branch-read-delete ()
  "Read one unambiguous local or remote-tracking branch."
  (let* ((locals (legit-branch-local-branches))
         (remotes (legit-branch-remote-branches))
         (choices (remove-duplicates (append locals remotes) :test #'string=))
         (aliases (legit-branch-delete-aliases choices remotes))
         (prompt-choices (append choices (mapcar #'car aliases))))
    (unless choices
      (editor-error "There is no branch to delete."))
    (alexandria:when-let
        ((input
           (prompt-for-string
            "Delete branch: "
            :history-symbol '*legit-branch-name-history*
            :completion-function
            (lambda (query) (completion-strings query prompt-choices))
            :test-function
            (lambda (value) (member value prompt-choices :test #'string=)))))
      (let ((branch (or (cdr (assoc input aliases :test #'string=)) input)))
        (when (and (member branch locals :test #'string=)
                   (member branch remotes :test #'string=))
          (editor-error "Branch name ~a is ambiguous; use Git directly."
                        branch))
        branch))))

(defun legit-branch-remote-ref-present-p (remote branch)
  "Return whether BRANCH still exists on REMOTE."
  (multiple-value-bind (output error-output status)
      (legit-branch-run-program
       (list "ls-remote" "--exit-code" "--heads" "--" remote
             (format nil "refs/heads/~a" branch)))
    (declare (ignore output))
    (cond
      ((eql status 0) t)
      ((eql status 2) nil)
      (t (editor-error "~a"
                       (legit-command-error-text "" error-output))))))

(defun legit-branch-delete-remote (tracking)
  "Delete TRACKING locally, optionally deleting its remote branch too."
  (multiple-value-bind (remote branch)
      (legit-branch-remote-parts tracking)
    (unless (and remote branch
                 (member remote (legit-branch-remotes) :test #'string=)
                 (legit-branch-name-valid-p branch))
      (editor-error "Remote-tracking branch ~a is invalid." tracking))
    (let ((ref (format nil "refs/remotes/~a/~a" remote branch)))
      (if (prompt-for-y-or-n-p
           (format nil "Deleting local ~a; also delete on ~a? " ref remote))
          (if (legit-branch-remote-ref-present-p remote branch)
              (multiple-value-bind (output error-output status)
                  (legit-branch-run-program
                   (list "push" "--delete" "--" remote
                         (format nil "refs/heads/~a" branch)))
                (if (and (integerp status) (zerop status))
                    (progn
                      (legit-branch-checked-output
                       (list "update-ref" "-d" ref))
                      (lem/legit::show-legit-status)
                      (message "Deleted ~a locally and on ~a."
                               branch remote)
                      t)
                    (progn
                      (lem/legit::pop-up-message
                       (legit-command-error-text output error-output))
                      nil)))
              (progn
                (legit-branch-checked-output (list "update-ref" "-d" ref))
                (lem/legit::show-legit-status)
                (message "Remote branch was already absent; deleted ~a."
                         ref)
                t))
          (progn
            (legit-branch-checked-output (list "update-ref" "-d" ref))
            (lem/legit::show-legit-status)
            (message "Deleted only local tracking ref ~a." ref)
            t)))))

(defun legit-branch-delete-local (branch)
  "Delete local BRANCH with current and unmerged safety behavior."
  (let ((current (legit-branch-current)))
    (cond
      ((and current (string= branch current))
       (alexandria:when-let
           ((target (legit-branch-delete-current-target branch)))
         (unless (or (string= target "<detach>")
                     (legit-branch-ancestor-p branch target)
                     (prompt-for-y-or-n-p
                      (format nil "Branch ~a is not merged into ~a. Delete anyway? "
                              branch target)))
           (return-from legit-branch-delete-local nil))
         (legit-branch-checked-output
          (if (string= target "<detach>")
              '("checkout" "--detach")
              (list "checkout" target)))
         (legit-branch-run
          (list "branch" "-D" branch)
          (format nil "Deleted ~a." branch))))
      ((or (legit-branch-ancestor-p branch "HEAD")
           (prompt-for-y-or-n-p
            (format nil "Branch ~a is unmerged. Force delete? " branch)))
       (legit-branch-run
        (list "branch"
              (if (legit-branch-ancestor-p branch "HEAD") "-d" "-D")
              branch)
        (format nil "Deleted ~a." branch))))))

(defun legit-branch-delete ()
  "Delete one local or remote-tracking branch with Magit's safeguards."
  (alexandria:when-let
      ((branch (legit-branch-read-delete)))
    (if (member branch (legit-branch-remote-branches) :test #'string=)
        (legit-branch-delete-remote branch)
        (legit-branch-delete-local branch))))

(defun legit-branch-read-config-choice (prompt choices current)
  (let* ((unset "<unset>")
         (all (append choices (list unset)))
         (input
           (prompt-for-string
            prompt
            :initial-value (or current unset)
            :history-symbol '*legit-branch-config-history*
            :completion-function
            (lambda (query) (completion-strings query all))
            :test-function
            (lambda (value) (member value all :test #'string=)))))
    (and input (if (string= input unset) :unset input))))

(defun legit-branch-config-description (branch)
  (let* ((key (format nil "branch.~a.description" branch))
         (value
           (prompt-for-string
            (format nil "Description for ~a (blank unsets): " branch)
            :initial-value (or (legit-branch-config-value key) "")
            :history-symbol '*legit-branch-config-history*)))
    (when value
      (legit-branch-set-config key (unless (str:blankp value) value)))))

(defun legit-branch-config-upstream (branch)
  (let* ((current (legit-reset-upstream branch))
         (choices
           (append
            (remove branch (legit-branch-local-branches) :test #'string=)
            (legit-branch-remote-branches)))
         (value
           (legit-branch-read-config-choice
            (format nil "Upstream for ~a: " branch) choices current)))
    (when value
      (if (eq value :unset)
          (when current
            (legit-branch-checked-output
             (list "branch" "--unset-upstream" branch)))
          (legit-branch-checked-output
           (list "branch" (format nil "--set-upstream-to=~a" value) branch)))
      (lem/legit::show-legit-status))))

(defun legit-branch-config-variable (key prompt choices)
  (alexandria:when-let
      ((value
         (legit-branch-read-config-choice
          prompt choices (legit-branch-config-value key))))
    (legit-branch-set-config key (unless (eq value :unset) value))))

(defun legit-branch-config-action (branch name)
  (cond
    ((string= name "d")
     (legit-branch-config-description branch))
    ((string= name "u")
     (legit-branch-config-upstream branch))
    ((string= name "r")
     (legit-branch-config-variable
      (format nil "branch.~a.rebase" branch)
      (format nil "Rebase when pulling ~a: " branch)
      '("true" "false")))
    ((string= name "p")
     (legit-branch-config-variable
      (format nil "branch.~a.pushRemote" branch)
      (format nil "Push remote for ~a: " branch)
      (legit-branch-remotes)))
    ((string= name "R")
     (legit-branch-config-variable
      "pull.rebase" "Repository pull.rebase: " '("true" "false")))
    ((string= name "P")
     (legit-branch-config-variable
      "remote.pushDefault" "Repository push default: "
      (legit-branch-remotes)))
    ((string= name "B")
     (legit-branch-update-default))
    ((string= name "a m")
     (legit-branch-config-variable
      "branch.autoSetupMerge" "Automatic upstream setup: "
      '("always" "true" "false")))
    ((string= name "a r")
     (legit-branch-config-variable
      "branch.autoSetupRebase" "Automatic rebase setup: "
      '("always" "local" "remote" "never")))
    (t (editor-error "No branch configuration action is bound to ~a" name))))

(defun legit-branch-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-branch-popup-keymap (options current)
  (let ((keymap (make-keymap :description "Branch")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(,(when current
               (list "d" (format nil "description: ~a"
                                  (or (legit-branch-config-value
                                       (format nil "branch.~a.description"
                                               current))
                                      "unset"))))
            ,(when current
               (list "u" (format nil "upstream: ~a"
                                  (or (legit-reset-upstream current) "unset"))))
            ,(when current
               (list "r" (format nil "rebase: ~a"
                                  (or (legit-branch-config-value
                                       (format nil "branch.~a.rebase" current))
                                      "inherit"))))
            ,(when current
               (list "p" (format nil "push remote: ~a"
                                  (or (legit-branch-config-value
                                       (format nil "branch.~a.pushRemote" current))
                                      "inherit"))))
            ("R" "repository pull.rebase")
            ("P" "repository push default")
            ("B" "update default branch")
            ("- r" ,(format nil "[~a] recurse submodules on checkout"
                              (if (legit-branch-options-recurse-submodules-p
                                   options) "x" " ")))
            ("b" "checkout branch/revision")
            ("l" "checkout local branch")
            ("o" "create orphan branch")
            ("c" "create and checkout branch")
            ("s" "spin off and checkout")
            ("n" "create branch without checkout")
            ("S" "spin out without checkout")
            ("C" "configure another branch")
            ("m" "rename branch")
            ("h" "shelve branch")
            ("H" "unshelve branch")
            ("X" "reset branch")
            ("x" "delete branch")
            ("q" "cancel")))
      (when entry
        (legit-branch-add-popup-entry keymap (first entry) (second entry))))
    keymap))

(defun legit-branch-config-popup-keymap (branch)
  (let ((keymap (make-keymap :description "Configure branch")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(("d" ,(format nil "description for ~a" branch))
            ("u" ,(format nil "upstream for ~a" branch))
            ("r" ,(format nil "pull rebase for ~a" branch))
            ("p" ,(format nil "push remote for ~a" branch))
            ("R" "repository pull.rebase")
            ("P" "repository push default")
            ("B" "update default branch")
            ("a m" "automatic upstream setup")
            ("a r" "automatic rebase setup")
            ("q" "return")))
      (legit-branch-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-branch-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (member name '("-" "a") :test #'string=)
        (format nil "~a ~a" name
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun legit-branch-configure (branch)
  (unwind-protect
       (loop
         :for keymap := (legit-branch-config-popup-keymap branch)
         :do
            (let ((lem/transient:*transient-popup-delay* 0))
              (keymap-activate keymap))
            (redraw-display)
            (let ((name (legit-branch-read-popup-key)))
              (lem/transient::hide-transient)
              (when (or (string= name "q") (string= name "Escape"))
                (return nil))
              (legit-branch-config-action branch name)))
    (lem/transient::hide-transient)))

(defun dispatch-legit-branch ()
  "Display and execute the configured Evil Collection Magit branch dispatch."
  (let ((options (make-legit-branch-options)))
    (unwind-protect
         (loop
           :for current := (legit-branch-current)
           :for keymap := (legit-branch-popup-keymap options current)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-branch-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Branch dispatch cancelled.")
                   (return nil))
                  ((string= name "- r")
                   (setf (legit-branch-options-recurse-submodules-p options)
                         (not (legit-branch-options-recurse-submodules-p
                               options))))
                  ((member name '("d" "u" "r" "p" "R" "P")
                           :test #'string=)
                   (unless current
                     (editor-error "This branch configuration requires HEAD."))
                   (legit-branch-config-action current name))
                  ((string= name "b")
                   (legit-branch-checkout-revision options)
                   (return t))
                  ((string= name "l")
                   (legit-branch-checkout-local options)
                   (return t))
                  ((string= name "o")
                   (legit-branch-orphan options)
                   (return t))
                  ((string= name "c")
                   (legit-branch-create options t)
                   (return t))
                  ((string= name "s")
                   (legit-branch-spin t)
                   (return t))
                  ((string= name "n")
                   (legit-branch-create options nil)
                   (return t))
                  ((string= name "S")
                   (legit-branch-spin nil)
                   (return t))
                  ((string= name "C")
                   (alexandria:when-let
                       ((branch
                          (legit-branch-read-local
                           "Configure branch: " :include-current-p t)))
                     (legit-branch-configure branch)))
                  ((string= name "m")
                   (legit-branch-rename)
                   (return t))
                  ((string= name "h")
                   (legit-branch-shelve)
                   (return t))
                  ((string= name "H")
                   (legit-branch-unshelve)
                   (return t))
                  ((string= name "B")
                   (legit-branch-update-default)
                   (return t))
                  ((string= name "X")
                   (legit-reset-branch)
                   (return t))
                  ((string= name "x")
                   (legit-branch-delete)
                   (return t))
                  (t
                   (message "No branch action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-branch () ()
  "Open the configured Evil Collection Magit branch dispatch."
  (lem/legit::with-current-project (vcs)
    (legit-branch-require-git vcs)
    (dispatch-legit-branch)))

(define-command lem-yath-legit-branch-or-todo-toggle () ()
  "Toggle branch TODOs at a TODO section; otherwise open branch dispatch."
  (if (legit-todo-context-root (current-point))
      (lem-yath-legit-todo-branch-list-toggle)
      (lem-yath-legit-branch)))

(define-key lem/legit::*peek-legit-keymap*
  "b" 'lem-yath-legit-branch-or-todo-toggle)
(define-key lem/legit::*legit-diff-mode-keymap* "b" 'lem-yath-legit-branch)
