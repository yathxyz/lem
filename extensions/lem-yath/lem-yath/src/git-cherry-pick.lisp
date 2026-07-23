;;;; Magit-compatible cherry-pick dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-cherry-pick-timeout* 120)
(defparameter *legit-cherry-pick-output-limit* (* 4 1024 1024))
(defparameter *legit-cherry-pick-message-limit* (* 1024 1024))
(defparameter *legit-cherry-pick-candidate-limit* 200)
(defparameter *legit-cherry-pick-commit-limit* 64)
(defparameter *legit-cherry-pick-value-limit* 4096)

(defvar *legit-cherry-pick-history* nil)
(defvar *legit-cherry-branch-history* nil)
(defvar *legit-cherry-strategy-history* nil)
(defvar *legit-cherry-gpg-history* nil)
(defvar *legit-cherry-operation-key* 'lem-yath-legit-cherry-operation)
(defvar *legit-cherry-gpg-key* 'lem-yath-legit-cherry-gpg)

(defstruct (legit-cherry-options
             (:constructor make-legit-cherry-options
                 (&key mainline strategy (fast-forward-p t) reference-p
                       edit-p gpg-sign signoff-p)))
  mainline
  strategy
  fast-forward-p
  reference-p
  edit-p
  gpg-sign
  signoff-p)

(defstruct legit-cherry-move
  commits
  source
  source-tip
  destination
  checkout-destination-p
  options)

(defvar *legit-cherry-pending-move* nil)
(setf *legit-cherry-pending-move* nil)

(defun legit-git-metadata-path-exists-p (relative-path)
  "Return true when RELATIVE-PATH exists below Git's effective metadata dir."
  (multiple-value-bind (output error-output status)
      (lem/porcelain/git::run-git
       (list "rev-parse" "--git-path" relative-path))
    (declare (ignore error-output))
    (and (zerop status)
         (uiop:file-exists-p
          (merge-pathnames (str:trim output) (uiop:getcwd))))))

(defun legit-cherry-pick-in-progress-p ()
  "Return true for a stopped single or multi-commit cherry-pick."
  (or (legit-git-metadata-path-exists-p "CHERRY_PICK_HEAD")
      (legit-git-metadata-path-exists-p "sequencer/todo")))

(defun legit-cherry-sequencer-edit-p ()
  "Return whether Git's live cherry-pick sequencer retains edit mode."
  (multiple-value-bind (output error-output status)
      (legit-cherry-run-program
       '("rev-parse" "--git-path" "sequencer/opts"))
    (declare (ignore error-output))
    (when (and (integerp status) (zerop status)
               (str:non-blank-string-p output))
      (let* ((path (str:trim output))
             (absolute
               (merge-pathnames path (uiop:getcwd))))
        (when (uiop:file-exists-p absolute)
          (multiple-value-bind (value config-error config-status)
              (legit-cherry-run-program
               (list "config" "--file" path "--bool" "--get"
                     "options.edit"))
            (declare (ignore config-error))
            (and (integerp config-status)
                 (zerop config-status)
                 (string-equal "true" (str:trim value)))))))))

(defun legit-cherry-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Cherry-pick is available only in a Git repository.")))

(defun legit-cherry-run-program (arguments &key editor)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-cherry-pick-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :environment
     (when editor
       (legit-rebase-child-environment
        "GIT_EDITOR" editor "LC_ALL" "C"))
     :output-limit *legit-cherry-pick-output-limit*)))

(defun legit-cherry-checked-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-cherry-run-program arguments)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-cherry-optional-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-cherry-run-program arguments)
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

(defun legit-cherry-current-branch ()
  (legit-cherry-optional-output
   '("symbolic-ref" "--quiet" "--short" "HEAD")))

(defun legit-cherry-normalize-commit (revision)
  "Return REVISION's full commit hash without permitting option injection."
  (let ((token (str:trim revision)))
    (when (or (str:blankp token)
              (> (length token) *legit-cherry-pick-value-limit*)
              (find-if (lambda (character)
                         (member character '(#\Space #\Tab #\Newline
                                             #\Return)))
                       token))
      (editor-error "A bounded whitespace-free Git revision is required."))
    (str:trim
     (legit-cherry-checked-output
      (list "rev-parse" "--verify" "--end-of-options"
            (format nil "~a^{commit}" token))))))

(defun legit-cherry-ref-tip (revision)
  (legit-cherry-normalize-commit revision))

(defun legit-cherry-ancestor-p (ancestor descendant)
  (multiple-value-bind (output error-output status)
      (legit-cherry-run-program
       (list "merge-base" "--is-ancestor" ancestor descendant))
    (declare (ignore output))
    (cond
      ((eql status 0) t)
      ((eql status 1) nil)
      (t (editor-error "~a"
                       (legit-command-error-text "" error-output))))))

(defun legit-cherry-local-branches ()
  (let ((branches
          (remove-if
           #'str:blankp
           (str:lines
            (legit-cherry-checked-output
             '("for-each-ref" "--format=%(refname:short)" "refs/heads"))))))
    (when (> (length branches) *legit-cherry-pick-candidate-limit*)
      (editor-error "Git returned more than ~d local branches."
                    *legit-cherry-pick-candidate-limit*))
    branches))

(defun legit-cherry-pick-candidates ()
  "Return bounded display/hash pairs for commits reachable from every ref."
  (let ((output
          (legit-cherry-checked-output
           (list "log" "--all" "--pretty=format:%H%x00%s"
                 "-n" (princ-to-string
                        *legit-cherry-pick-candidate-limit*)))))
    (loop :for line :in (str:lines output)
          :for separator := (position #\Null line)
          :when (and separator (plusp separator))
            :collect
            (let ((hash (subseq line 0 separator))
                  (subject (subseq line (1+ separator))))
              (cons (format nil "~a  ~a"
                            (subseq hash 0 (min 12 (length hash)))
                            subject)
                    hash)))))

(defun legit-cherry-read-commits (prompt &key (allow-region-p t))
  "Read verified commits, preferring a valid Magit-style commit region."
  (alexandria:when-let
      ((selected
         (and allow-region-p
              (legit-log-selected-commits
               *legit-cherry-pick-commit-limit*))))
    ;; Git applies commits in argv order.  Logs display newest first, while
    ;; Magit reverses the selected section values for cherry operations.
    (return-from legit-cherry-read-commits
      (mapcar #'legit-cherry-normalize-commit (reverse selected))))
  (let* ((default (text-property-at (current-point) :commit-hash))
         (candidates (legit-cherry-pick-candidates))
         (labels (mapcar #'car candidates))
         (input
           (prompt-for-string
            prompt
            :initial-value (or default "")
            :history-symbol '*legit-cherry-pick-history*
            :completion-function
            (lambda (query) (completion-strings query labels)))))
    (when input
      (let ((exact (cdr (assoc input candidates :test #'string=))))
        (if exact
            (list exact)
            (let ((parts
                    (remove-if #'str:blankp
                               (mapcar #'str:trim (str:split "," input)))))
              (when (null parts)
                (editor-error "At least one commit is required."))
              (when (> (length parts) *legit-cherry-pick-commit-limit*)
                (editor-error "A cherry-pick is limited to 64 commits."))
              (mapcar #'legit-cherry-normalize-commit parts)))))))

(defun legit-cherry-merge-commit-p (commit)
  (> (length
      (remove-if
       #'str:blankp
       (str:split
        " "
        (str:trim
         (legit-cherry-checked-output
          (list "rev-list" "--parents" "-n" "1" commit))))))
     2))

(defun legit-cherry-effective-mainline (commits configured)
  "Validate merge/non-merge COMMITS and return the effective mainline."
  (let ((merge-count (count-if #'legit-cherry-merge-commit-p commits)))
    (cond
      ((zerop merge-count) nil)
      ((/= merge-count (length commits))
       (editor-error
        "Cannot cherry-pick merge and non-merge commits together."))
      (configured configured)
      (t
       (let* ((input
                (prompt-for-string "Replay merges relative to parent: "))
              (number
                (and input
                     (ignore-errors
                       (parse-integer input :junk-allowed nil)))))
         (unless (and number (plusp number))
           (editor-error "A positive mainline parent number is required."))
         number)))))

(defun legit-cherry-option-arguments (options commits &key no-commit-p)
  (when (and (legit-cherry-options-fast-forward-p options)
             (legit-cherry-options-edit-p options))
    (editor-error "Cherry-pick cannot combine fast-forward and message editing."))
  (let ((mainline
          (legit-cherry-effective-mainline
           commits (legit-cherry-options-mainline options))))
    (append
     (when no-commit-p '("--no-commit"))
     (when mainline (list (format nil "--mainline=~d" mainline)))
     (alexandria:when-let ((strategy (legit-cherry-options-strategy options)))
       (list (format nil "--strategy=~a" strategy)))
     (when (and (not no-commit-p)
                (legit-cherry-options-fast-forward-p options))
       '("--ff"))
     (when (legit-cherry-options-reference-p options) '("-x"))
     (when (legit-cherry-options-edit-p options) '("--edit"))
     (alexandria:when-let ((key (legit-cherry-options-gpg-sign options)))
       (list (if (str:blankp key)
                 "--gpg-sign"
                 (format nil "--gpg-sign=~a" key))))
     (when (legit-cherry-options-signoff-p options) '("--signoff")))))

(defun legit-cherry-unmerged-p ()
  (str:non-blank-string-p
   (legit-cherry-checked-output '("ls-files" "--unmerged"))))

(defun legit-cherry-index-changes-p ()
  (multiple-value-bind (output error-output status)
      (legit-cherry-run-program '("diff" "--cached" "--quiet"))
    (declare (ignore output))
    (cond
      ((eql status 0) nil)
      ((eql status 1) t)
      (t (editor-error "~a"
                       (legit-command-error-text "" error-output))))))

(defun legit-cherry-read-bounded-file (git-path)
  "Read a bounded UTF-8 file named by GIT-PATH below Git's metadata dir."
  (let* ((relative
           (str:trim
            (legit-cherry-checked-output
             (list "rev-parse" "--git-path" git-path))))
         (pathname (merge-pathnames relative (uiop:getcwd))))
    (unless (uiop:file-exists-p pathname)
      (editor-error "Git did not prepare a cherry-pick message."))
    (with-open-file (stream pathname :direction :input :external-format :utf-8)
      (let ((chunk (make-string 8192))
            (count 0)
            (output (make-string-output-stream)))
        (loop :for length := (read-sequence chunk stream)
              :until (zerop length)
              :do (incf count length)
                  (when (> count *legit-cherry-pick-message-limit*)
                    (editor-error "Cherry-pick message exceeds 1 MiB."))
                  (write-sequence chunk output :end length))
        (get-output-stream-string output)))))

(defun legit-cherry-message-buffer-p (&optional (buffer (current-buffer)))
  (eq (buffer-value buffer *legit-cherry-operation-key*) :cherry-pick))

(defun legit-cherry-show-message-buffer (gpg-sign directory)
  "Open Legit's commit mode with Git's exact prepared cherry-pick message."
  (when (get-buffer "*legit-cherry-pick*")
    (editor-error "A cherry-pick message buffer is already open."))
  (let ((message (legit-cherry-read-bounded-file "COMMIT_EDITMSG"))
        (buffer (make-buffer "*legit-cherry-pick*")))
    (setf (buffer-directory buffer) directory
          (buffer-read-only-p buffer) nil
          (buffer-value buffer *legit-cherry-operation-key*) :cherry-pick
          (buffer-value buffer *legit-cherry-gpg-key*) gpg-sign)
    (erase-buffer buffer)
    (insert-string
     (buffer-point buffer)
     (format nil "~a~a"
             (string-right-trim '(#\Newline #\Return) message)
             (format nil lem/legit::*commit-buffer-message*)))
    (change-buffer-mode buffer 'lem/legit::legit-commit-mode)
    (buffer-start (buffer-point buffer))
    (next-window)
    (switch-to-buffer buffer)))

(defun legit-cherry-clean-worktree-p ()
  (str:blankp
   (legit-cherry-checked-output
    '("status" "--porcelain=v1" "--untracked-files=normal"))))

(defun legit-cherry-assert-clean-worktree ()
  (unless (legit-cherry-clean-worktree-p)
    (editor-error
     "Moving cherries requires a clean index, worktree, and untracked set.")))

(defun legit-cherry-run-checked (arguments)
  (legit-cherry-checked-output arguments)
  t)

(defun legit-cherry-commit-distance (commit source)
  (parse-integer
   (str:trim
    (legit-cherry-checked-output
     (list "rev-list" "--count" "--ancestry-path"
           (format nil "~a..~a" commit source))))
   :junk-allowed nil))

(defun legit-cherry-removal-order (commits source)
  "Return COMMITS from SOURCE tip toward its ancestors."
  (mapcar
   #'cdr
   (stable-sort
    (mapcar (lambda (commit)
              (cons (legit-cherry-commit-distance commit source) commit))
            commits)
    #'< :key #'car)))

(defun legit-cherry-remove-source-commits (commits source)
  "Remove COMMITS from checked-out SOURCE, newest first."
  (when (some #'legit-cherry-merge-commit-p commits)
    (editor-error
     "Moving merge commits off their source branch is not topology-safe."))
  (dolist (commit (legit-cherry-removal-order commits source))
    (let ((tip (legit-cherry-ref-tip "HEAD"))
          (parent (legit-cherry-ref-tip (format nil "~a^" commit))))
      (if (string= tip commit)
          (legit-cherry-run-checked (list "reset" "--hard" parent))
          (multiple-value-bind (output error-output status)
              (legit-cherry-run-program
               (list "rebase" "--onto" parent commit)
               :editor "true")
            (unless (and (integerp status) (zerop status))
              (lem/legit::show-legit-status)
              (editor-error
               "Source cleanup stopped in rebase; finish it manually. ~a"
               (legit-command-error-text output error-output)))))))
  t)

(defun legit-cherry-finish-pending-move ()
  "Remove successfully transplanted commits from their source branch."
  (alexandria:when-let ((move *legit-cherry-pending-move*))
    (setf *legit-cherry-pending-move* nil)
    (let ((source (legit-cherry-move-source move)))
      (when source
        (handler-case
            (progn
              (unless (string=
                       (legit-cherry-ref-tip source)
                       (legit-cherry-move-source-tip move))
                (editor-error
                 "The source moved during cherry-pick; it was not rewritten."))
              (if (member source (legit-cherry-local-branches)
                          :test #'string=)
                  (legit-cherry-run-checked (list "checkout" source))
                  (legit-cherry-run-checked
                   (list "checkout" "--detach" source)))
              (legit-cherry-remove-source-commits
               (legit-cherry-move-commits move) source)
              (when (legit-cherry-move-checkout-destination-p move)
                (legit-cherry-run-checked
                 (list "checkout"
                       (legit-cherry-move-destination move))))
              (lem/legit::show-legit-status)
              (message "Moved cherry commit(s) from ~a to ~a."
                       source (legit-cherry-move-destination move))
              t)
          (error (condition)
            (lem/legit::show-legit-status)
            (lem/legit::pop-up-message (princ-to-string condition))
            nil))))))

(defun legit-cherry-edit-stop-p ()
  "Return whether an editing cherry-pick stopped before committing.

Use Git's sequencer state instead of matching version- and locale-dependent
editor diagnostics.  The caller already knows that editing was requested and
the bounded message reader validates Git's prepared COMMIT_EDITMSG."
  (and (legit-cherry-pick-in-progress-p)
       (not (legit-cherry-unmerged-p))))

(defun run-legit-cherry-pick
    (arguments success-message &key edit-p gpg-sign pending-move)
  "Run Git cherry-pick ARGUMENTS and preserve edit/conflict state."
  (let ((move-p (or pending-move *legit-cherry-pending-move*))
        (directory (uiop:getcwd)))
    (when pending-move
      (setf *legit-cherry-pending-move* pending-move))
    (multiple-value-bind (output error-output status)
        (legit-cherry-run-program
         (cons "cherry-pick" arguments)
         :editor (if edit-p "false" "true"))
      (lem/legit::show-legit-status)
      (cond
        ((and (integerp status) (zerop status))
         (when (or (not move-p) (legit-cherry-finish-pending-move))
           (message "~a" success-message)
           t))
        ((legit-cherry-unmerged-p)
         (message
          "Cherry-pick stopped; resolve conflicts, then continue, abort, or skip from A.")
         nil)
        ((and edit-p (legit-cherry-edit-stop-p))
         (legit-cherry-show-message-buffer gpg-sign directory)
         nil)
        ((legit-cherry-pick-in-progress-p)
         (message "Cherry-pick stopped; continue, abort, or skip from A.")
         nil)
        (t
         (setf *legit-cherry-pending-move* nil)
         (lem/legit::pop-up-message
          (legit-command-error-text output error-output))
         nil)))))

(defun legit-cherry-start (options no-commit-p)
  (alexandria:when-let
      ((commits
         (legit-cherry-read-commits
          (if no-commit-p
              "Apply changes from commit: "
              "Cherry-pick: "))))
    (run-legit-cherry-pick
     (append (legit-cherry-option-arguments
              options commits :no-commit-p no-commit-p)
             commits)
     (if no-commit-p
         "Applied commit(s) without committing."
         "Cherry-picked commit(s).")
     :edit-p (and (not no-commit-p)
                  (legit-cherry-options-edit-p options))
     :gpg-sign (legit-cherry-options-gpg-sign options))))

(defun legit-cherry-active-continue ()
  (unless (legit-cherry-pick-in-progress-p)
    (editor-error "No cherry-pick is in progress."))
  (when (legit-cherry-unmerged-p)
    (editor-error "Cannot continue while conflicts remain unresolved."))
  (let* ((move *legit-cherry-pending-move*)
         (options (and move (legit-cherry-move-options move))))
    (run-legit-cherry-pick
     '("--continue") "Cherry-pick continued."
     :edit-p (or (and options (legit-cherry-options-edit-p options))
                 (legit-cherry-sequencer-edit-p))
     :gpg-sign (and options (legit-cherry-options-gpg-sign options)))))

(defun legit-cherry-active-abort ()
  (unless (legit-cherry-pick-in-progress-p)
    (editor-error "No cherry-pick is in progress."))
  (when (prompt-for-y-or-n-p "Abort cherry-pick? ")
    (setf *legit-cherry-pending-move* nil)
    (run-legit-cherry-pick '("--abort") "Cherry-pick aborted.")))

(defun legit-cherry-active-skip ()
  (unless (legit-cherry-pick-in-progress-p)
    (editor-error "No cherry-pick is in progress."))
  (let* ((move *legit-cherry-pending-move*)
         (options (and move (legit-cherry-move-options move))))
    (run-legit-cherry-pick
     '("--skip") "Skipped cherry-pick commit."
     :edit-p (or (and options (legit-cherry-options-edit-p options))
                 (legit-cherry-sequencer-edit-p))
     :gpg-sign (and options (legit-cherry-options-gpg-sign options)))))

(defun legit-cherry-message-continue ()
  "Commit the prepared message and advance the exact Git sequence."
  (let* ((buffer (current-buffer))
         (message (lem/legit::clean-commit-message (buffer-text buffer)))
         (gpg-sign (buffer-value buffer *legit-cherry-gpg-key*)))
    (when (str:blankp message)
      (message "No commit message; cherry-pick remains stopped.")
      (return-from legit-cherry-message-continue nil))
    (lem/legit::with-current-project (vcs)
      (legit-cherry-require-git vcs)
      (multiple-value-bind (output error-output status)
          (legit-cherry-run-program
           (append
            (list "commit" "-m" message)
            (when gpg-sign
              (list (if (str:blankp gpg-sign)
                        "--gpg-sign"
                        (format nil "--gpg-sign=~a" gpg-sign)))))
           :editor "true")
        (if (and (integerp status) (zerop status))
            (progn
              (buffer-unmark buffer)
              (kill-buffer buffer)
              (when (lem/legit::legit-status-active-p)
                (setf (current-window) lem/legit::*peek-window*))
              (lem/legit::show-legit-status)
              (if (legit-cherry-pick-in-progress-p)
                  (legit-cherry-active-continue)
                  (progn
                    (legit-cherry-finish-pending-move)
                    (message "Committed edited cherry-pick."))))
            (lem/legit::pop-up-message
             (legit-command-error-text output error-output)))))))

(defun legit-cherry-message-abort ()
  "Close the message editor while retaining Git's stopped operation."
  (when (or (not lem/legit::*prompt-to-abort-commit*)
            (prompt-for-y-or-n-p "Close cherry-pick message? "))
    (let ((buffer (current-buffer)))
      (buffer-unmark buffer)
      (kill-buffer buffer)
      (when (lem/legit::legit-status-active-p)
        (setf (current-window) lem/legit::*peek-window*))
      (message "Cherry-pick remains stopped; use A a to abort it."))))

(defun legit-cherry-read-existing-branch (prompt &key exclude)
  (let ((branches
          (remove exclude (legit-cherry-local-branches) :test #'string=)))
    (unless branches
      (editor-error "There is no eligible local branch."))
    (prompt-for-string
     prompt
     :history-symbol '*legit-cherry-branch-history*
     :completion-function
     (lambda (query) (completion-strings query branches))
     :test-function
     (lambda (input) (member input branches :test #'string=)))))

(defun legit-cherry-new-branch-valid-p (name)
  (and (str:non-blank-string-p name)
       (<= (length name) *legit-cherry-pick-value-limit*)
       (not (member name (legit-cherry-local-branches) :test #'string=))
       (multiple-value-bind (output error-output status)
           (legit-cherry-run-program
            (list "check-ref-format" "--branch" name))
         (declare (ignore output error-output))
         (and (integerp status) (zerop status)))))

(defun legit-cherry-read-new-branch (prompt)
  (prompt-for-string
   prompt
   :history-symbol '*legit-cherry-branch-history*
   :test-function #'legit-cherry-new-branch-valid-p))

(defun legit-cherry-upstream (branch)
  (legit-cherry-optional-output
   (list "rev-parse" "--abbrev-ref" "--symbolic-full-name"
         (format nil "~a@{upstream}" branch))))

(defun legit-cherry-read-start-point (current commits)
  (let* ((upstream (legit-cherry-upstream current))
         (default (or upstream
                      (format nil "~a^" (car (last commits)))))
         (input
           (prompt-for-string
            "Starting point for new branch: "
            :initial-value default
            :history-symbol '*legit-cherry-pick-history*)))
    (when input
      (legit-cherry-normalize-commit input)
      input)))

(defun legit-cherry-containing-branches (commits current)
  (remove-if-not
   (lambda (branch)
     (and (not (string= branch current))
          (every (lambda (commit)
                   (legit-cherry-ancestor-p commit branch))
                 commits)))
   (legit-cherry-local-branches)))

(defun legit-cherry-read-containing-branch (commits current)
  (let ((branches (legit-cherry-containing-branches commits current)))
    (case (length branches)
      (0 nil)
      (1 (car branches))
      (t
       (prompt-for-string
        "Remove cherries from branch: "
        :history-symbol '*legit-cherry-branch-history*
        :completion-function
        (lambda (query) (completion-strings query branches))
        :test-function
        (lambda (input) (member input branches :test #'string=)))))))

(defun legit-cherry-assert-reachability (commits revision reachable-p verb)
  (dolist (commit commits)
    (unless (eq (legit-cherry-ancestor-p commit revision) reachable-p)
      (editor-error "Cannot ~a cherries that ~:[are~;are not~] reachable from HEAD."
                    verb reachable-p))))

(defun legit-cherry-transplant
    (commits source destination options &key checkout-destination-p)
  "Copy COMMITS to DESTINATION, then safely remove them from SOURCE."
  (legit-cherry-assert-clean-worktree)
  (let ((move
          (and source
               (make-legit-cherry-move
                :commits commits
                :source source
                :source-tip (legit-cherry-ref-tip source)
                :destination destination
                :checkout-destination-p checkout-destination-p
                :options options))))
    (legit-cherry-run-checked (list "checkout" destination))
    (run-legit-cherry-pick
     (append (legit-cherry-option-arguments options commits) commits)
     "Moved cherry commit(s)."
     :edit-p (legit-cherry-options-edit-p options)
     :gpg-sign (legit-cherry-options-gpg-sign options)
     :pending-move move)))

(defun legit-cherry-harvest (options)
  (alexandria:when-let ((commits (legit-cherry-read-commits "Harvest cherry: ")))
    (let ((current
            (or (legit-cherry-current-branch)
                (editor-error "Cannot harvest cherries while HEAD is detached."))))
      (legit-cherry-assert-reachability commits current nil "harvest")
      (let ((source (legit-cherry-read-containing-branch commits current)))
        (legit-cherry-transplant
         commits source current options :checkout-destination-p t)))))

(defun legit-cherry-donate (options)
  (alexandria:when-let ((commits (legit-cherry-read-commits "Donate cherry: ")))
    (let* ((current (legit-cherry-current-branch))
           (source (or current (legit-cherry-ref-tip "HEAD"))))
      (legit-cherry-assert-reachability commits source t "donate")
      (alexandria:when-let
          ((destination
             (legit-cherry-read-existing-branch
              "Move cherry to branch: " :exclude current)))
        (legit-cherry-transplant commits source destination options)))))

(defun legit-cherry-spin (options checkout-destination-p)
  (alexandria:when-let ((commits (legit-cherry-read-commits "Move cherry: ")))
    (let ((current
            (or (legit-cherry-current-branch)
                (editor-error "Cannot spin cherries while HEAD is detached."))))
      (legit-cherry-assert-reachability commits current t "spin")
      (alexandria:when-let
          ((branch
             (legit-cherry-read-new-branch
              (if checkout-destination-p
                  "Spin off to new branch: "
                  "Spin out to new branch: "))))
        (alexandria:when-let
            ((start (legit-cherry-read-start-point current commits)))
          (legit-cherry-run-checked (list "branch" branch start))
          (alexandria:when-let ((upstream (legit-cherry-upstream current)))
            (when (string= start upstream)
              (legit-cherry-run-checked
               (list "branch" "--set-upstream-to" upstream branch))))
          (legit-cherry-transplant
           commits current branch options
           :checkout-destination-p checkout-destination-p))))))

(defun legit-cherry-squash ()
  (legit-cherry-assert-clean-worktree)
  (alexandria:when-let
      ((commit
         (car (legit-cherry-read-commits
               "Squash: " :allow-region-p nil))))
    (multiple-value-bind (output error-output status)
        (legit-cherry-run-program (list "merge" "--squash" commit)
                                  :editor "true")
      (lem/legit::show-legit-status)
      (cond
        ((and (integerp status) (zerop status))
         (message "Squashed ~a into the index." commit)
         t)
        ((legit-cherry-unmerged-p)
         (message "Squash stopped with conflicts; resolve them in Legit.")
         nil)
        (t
         (lem/legit::pop-up-message
          (legit-command-error-text output error-output))
         nil)))))

(defun legit-cherry-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-cherry-popup-keymap (options active-p)
  (let ((keymap (make-keymap :description "Apply")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (if active-p
        (dolist (entry '(("A" "continue cherry-pick")
                         ("s" "skip commit")
                         ("a" "abort cherry-pick")
                         ("q" "cancel")))
          (legit-cherry-add-popup-entry keymap (first entry) (second entry)))
        (dolist
            (entry
              `(("- m" ,(format nil "mainline parent: ~a"
                                  (or (legit-cherry-options-mainline options)
                                      "auto")))
                ("= s" ,(format nil "strategy: ~a"
                                  (or (legit-cherry-options-strategy options)
                                      "default")))
                ("- F" ,(format nil "[~a] attempt fast-forward"
                                  (if (legit-cherry-options-fast-forward-p
                                       options) "x" " ")))
                ("- x" ,(format nil "[~a] reference original commit"
                                  (if (legit-cherry-options-reference-p options)
                                      "x" " ")))
                ("- e" ,(format nil "[~a] edit commit messages"
                                  (if (legit-cherry-options-edit-p options)
                                      "x" " ")))
                ("- S" ,(format nil "GPG sign: ~a"
                                  (let ((key
                                          (legit-cherry-options-gpg-sign
                                           options)))
                                    (cond ((null key) "off")
                                          ((str:blankp key) "default key")
                                          (t key)))))
                ("+ s" ,(format nil "[~a] add Signed-off-by"
                                  (if (legit-cherry-options-signoff-p options)
                                      "x" " ")))
                ("A" "pick here")
                ("a" "apply here without commit")
                ("h" "harvest from another branch")
                ("m" "squash into index")
                ("d" "donate to another branch")
                ("n" "spin out to new branch")
                ("s" "spin off to new branch")
                ("q" "cancel")))
          (legit-cherry-add-popup-entry keymap (first entry) (second entry))))
    keymap))

(defun legit-cherry-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (member name '("-" "+" "=") :test #'string=)
        (format nil "~a ~a" name
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun legit-cherry-read-strategy ()
  (let ((choices '("resolve" "recursive" "ort" "octopus" "ours"
                   "subtree")))
    (prompt-for-string
     "Cherry-pick strategy: "
     :history-symbol '*legit-cherry-strategy-history*
     :completion-function
     (lambda (query) (completion-strings query choices))
     :test-function
     (lambda (input) (member input choices :test #'string=)))))

(defun dispatch-legit-cherry-pick ()
  "Display and execute one configured Magit cherry-pick action."
  (let ((options (make-legit-cherry-options)))
    (unwind-protect
         (loop
           :for active-p := (legit-cherry-pick-in-progress-p)
           :for keymap := (legit-cherry-popup-keymap options active-p)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-cherry-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Cherry-pick cancelled.")
                   (return nil))
                  ((and active-p (string= name "A"))
                   (legit-cherry-active-continue)
                   (return t))
                  ((and active-p (string= name "a"))
                   (legit-cherry-active-abort)
                   (return t))
                  ((and active-p (string= name "s"))
                   (legit-cherry-active-skip)
                   (return t))
                  (active-p
                   (message "No in-progress cherry-pick action is bound to ~a"
                            name)
                   (return nil))
                  ((string= name "- m")
                   (let* ((input (prompt-for-string "Mainline parent: "))
                          (number
                            (and input
                                 (not (str:blankp input))
                                 (ignore-errors
                                   (parse-integer input :junk-allowed nil)))))
                     (cond
                       ((or (null input) (str:blankp input))
                        (setf (legit-cherry-options-mainline options) nil))
                       ((and number (plusp number))
                        (setf (legit-cherry-options-mainline options) number))
                       (t
                        (editor-error
                         "A positive mainline parent number is required.")))))
                  ((string= name "= s")
                   (setf (legit-cherry-options-strategy options)
                         (legit-cherry-read-strategy)))
                  ((string= name "- F")
                   (setf (legit-cherry-options-fast-forward-p options)
                         (not (legit-cherry-options-fast-forward-p options)))
                   (when (legit-cherry-options-fast-forward-p options)
                     (setf (legit-cherry-options-reference-p options) nil
                           (legit-cherry-options-edit-p options) nil)))
                  ((string= name "- x")
                   (setf (legit-cherry-options-reference-p options)
                         (not (legit-cherry-options-reference-p options)))
                   (when (legit-cherry-options-reference-p options)
                     (setf (legit-cherry-options-fast-forward-p options) nil)))
                  ((string= name "- e")
                   (setf (legit-cherry-options-edit-p options)
                         (not (legit-cherry-options-edit-p options)))
                   (when (legit-cherry-options-edit-p options)
                     (setf (legit-cherry-options-fast-forward-p options) nil)))
                  ((string= name "- S")
                   (setf (legit-cherry-options-gpg-sign options)
                         (if (legit-cherry-options-gpg-sign options)
                             nil
                             (or (prompt-for-string
                                  "GPG signing key (blank uses default): "
                                  :history-symbol '*legit-cherry-gpg-history*)
                                 ""))))
                  ((string= name "+ s")
                   (setf (legit-cherry-options-signoff-p options)
                         (not (legit-cherry-options-signoff-p options))))
                  ((string= name "A")
                   (legit-cherry-start options nil)
                   (return t))
                  ((string= name "a")
                   (legit-cherry-start options t)
                   (return t))
                  ((string= name "h")
                   (legit-cherry-harvest options)
                   (return t))
                  ((string= name "m")
                   (legit-cherry-squash)
                   (return t))
                  ((string= name "d")
                   (legit-cherry-donate options)
                   (return t))
                  ((string= name "n")
                   (legit-cherry-spin options nil)
                   (return t))
                  ((string= name "s")
                   (legit-cherry-spin options t)
                   (return t))
                  (t
                   (message "No cherry-pick action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-cherry-pick () ()
  "Open the configured Magit-compatible cherry-pick transient."
  (lem/legit::with-current-project (vcs)
    (legit-cherry-require-git vcs)
    (dispatch-legit-cherry-pick)))

(define-key lem/legit::*peek-legit-keymap*
  "A" 'lem-yath-legit-cherry-pick)
(define-key lem/legit::*legit-diff-mode-keymap*
  "A" 'lem-yath-legit-cherry-pick)
