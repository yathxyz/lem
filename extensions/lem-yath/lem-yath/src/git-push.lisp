;;;; Evil-Collection-compatible Magit push dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-push-timeout* 120)
(defparameter *legit-push-output-limit* (* 4 1024 1024))
(defparameter *legit-push-candidate-limit* 5000)
(defparameter *legit-push-value-limit* 4096)
(defparameter *legit-push-refspec-limit* 64)

(defvar *legit-push-remote-history* nil)
(defvar *legit-push-target-history* nil)
(defvar *legit-push-source-history* nil)
(defvar *legit-push-refspec-history* nil)
(defvar *legit-push-tag-history* nil)
(defvar *legit-push-notes-history* nil)

(defstruct legit-push-options
  force-with-lease-p
  force-p
  no-verify-p
  dry-run-p
  set-upstream-p
  all-tags-p
  follow-tags-p)

(defun legit-push-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Push is available only in a Git repository.")))

(defun legit-push-run-program (arguments)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-push-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :output-limit *legit-push-output-limit*)))

(defun legit-push-checked-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-push-run-program arguments)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-push-lines (arguments)
  (let ((lines
          (remove-if #'str:blankp
                     (str:lines (legit-push-checked-output arguments)))))
    (when (> (length lines) *legit-push-candidate-limit*)
      (editor-error "Git returned more than ~d push candidates."
                    *legit-push-candidate-limit*))
    lines))

(defun legit-push-option-arguments (options)
  (append
   (when (legit-push-options-force-with-lease-p options)
     '("--force-with-lease"))
   (when (legit-push-options-force-p options) '("--force"))
   (when (legit-push-options-no-verify-p options) '("--no-verify"))
   (when (legit-push-options-dry-run-p options) '("--dry-run"))
   (when (legit-push-options-set-upstream-p options) '("--set-upstream"))
   (when (legit-push-options-all-tags-p options) '("--tags"))
   (when (legit-push-options-follow-tags-p options) '("--follow-tags"))))

(defun legit-push-run (options remote refspecs success-message)
  "Push REFSPECS to REMOTE with OPTIONS, refresh Legit, and report status."
  (multiple-value-bind (output error-output status)
      (legit-push-run-program
       (append (list "push" "--verbose")
               (legit-push-option-arguments options)
               (list "--" remote)
               refspecs))
    (lem/legit::show-legit-status)
    (if (and (integerp status) (zerop status))
        (progn
          (message "~a" success-message)
          t)
        (progn
          (lem/legit::pop-up-message
           (legit-command-error-text output error-output))
          nil))))

(defun legit-push-current-branch ()
  (or (legit-fetch-current-branch)
      (editor-error "No branch is checked out.")))

(defun legit-push-remotes ()
  (let ((remotes (legit-fetch-remotes)))
    (unless remotes
      (editor-error "There are no configured remotes."))
    remotes))

(defun legit-push-read-remote (prompt &optional initial-value)
  (let ((remotes (legit-push-remotes)))
    (alexandria:when-let
        ((remote
           (prompt-for-string
            prompt
            :initial-value (or initial-value
                               (and (= (length remotes) 1) (first remotes))
                               "")
            :history-symbol '*legit-push-remote-history*
            :completion-function
            (lambda (query) (completion-strings query remotes)))))
      (unless (member remote remotes :test #'string=)
        (editor-error "Remote ~a is not configured." remote))
      remote)))

(defun legit-push-configured-remote ()
  "Return the current branch or repository push remote when valid."
  (legit-fetch-push-remote))

(defun legit-push-configure-remote (branch remote)
  "Set BRANCH's configured push remote to REMOTE."
  (legit-push-checked-output
   (list "config" (format nil "branch.~a.pushRemote" branch) remote)))

(defun legit-push-remote-branch-candidates ()
  "Return remote/name candidates plus each remote's current branch name."
  (let* ((current (legit-fetch-current-branch))
         (tracked (legit-branch-remote-branches))
         (prospective
           (when current
             (mapcar (lambda (remote) (format nil "~a/~a" remote current))
                     (legit-push-remotes)))))
    (remove-duplicates (append tracked prospective) :test #'string=)))

(defun legit-push-split-target (target)
  "Validate remote branch TARGET and return its remote and branch name."
  (let ((slash (position #\/ target)))
    (unless (and slash (> slash 0) (< slash (1- (length target))))
      (editor-error "A target must have the form remote/branch."))
    (let ((remote (subseq target 0 slash))
          (branch (subseq target (1+ slash))))
      (unless (member remote (legit-push-remotes) :test #'string=)
        (editor-error "Remote ~a is not configured." remote))
      (unless (legit-branch-name-valid-p branch)
        (editor-error "~a is not a valid remote branch name." branch))
      (values remote branch))))

(defun legit-push-read-target (prompt &optional initial-value)
  (let ((input
          (prompt-for-string
           prompt
           :initial-value (or initial-value "")
           :history-symbol '*legit-push-target-history*
           :completion-function
           (lambda (query)
             (completion-strings
              query (legit-push-remote-branch-candidates))))))
    (when input
      (when (> (length input) *legit-push-value-limit*)
        (editor-error "A push target is limited to 4096 characters."))
      (legit-push-split-target input)
      input)))

(defun legit-push-target-refspec (source branch)
  (format nil "~a:refs/heads/~a" source branch))

(defun legit-push-current-to-push-remote (options)
  (let* ((branch (legit-push-current-branch))
         (configured (legit-push-configured-remote))
         (remote
           (or configured
               (legit-push-read-remote
                (format nil "Set push remote and push ~a there: " branch)))))
    (when remote
      (unless configured
        (unless (prompt-for-y-or-n-p
                 (format nil "Set ~a as push remote and push ~a there? "
                         remote branch))
          (return-from legit-push-current-to-push-remote nil))
        (legit-push-configure-remote branch remote))
      (legit-push-run
       options remote
       (list (legit-push-target-refspec
              (format nil "refs/heads/~a" branch) branch))
       (format nil "Pushed ~a to ~a/~a." branch remote branch)))))

(defun legit-push-upstream-components (branch)
  "Return BRANCH's valid upstream remote and branch name."
  (let ((remote
          (legit-fetch-config-value (format nil "branch.~a.remote" branch)))
        (merge
          (legit-fetch-config-value (format nil "branch.~a.merge" branch))))
    (when (and (member remote (legit-fetch-remotes) :test #'string=)
               merge
               (alexandria:starts-with-subseq "refs/heads/" merge))
      (values remote (subseq merge (length "refs/heads/"))))))

(defun legit-push-current-to-upstream (options)
  (let ((branch (legit-push-current-branch)))
    (multiple-value-bind (remote upstream)
        (legit-push-upstream-components branch)
      (unless (and remote upstream)
        (alexandria:when-let
            ((target
               (legit-push-read-target
                (format nil "Set upstream of ~a and push there: " branch)
                (alexandria:when-let ((fallback (first (legit-push-remotes))))
                  (format nil "~a/~a" fallback branch)))))
          (multiple-value-setq (remote upstream)
            (legit-push-split-target target))
          (unless (prompt-for-y-or-n-p
                   (format nil "Set ~a as upstream and push ~a there? "
                           target branch))
            (return-from legit-push-current-to-upstream nil))
          (setf (legit-push-options-set-upstream-p options) t)))
      (when (and remote upstream)
        (legit-push-run
         options remote
         (list (legit-push-target-refspec branch upstream))
         (format nil "Pushed ~a to upstream ~a/~a."
                 branch remote upstream))))))

(defun legit-push-current-elsewhere (options)
  (let ((branch (legit-push-current-branch)))
    (alexandria:when-let
        ((target
           (legit-push-read-target
            (format nil "Push ~a to: " branch))))
      (multiple-value-bind (remote target-branch)
          (legit-push-split-target target)
        (legit-push-run
         options remote
         (list (legit-push-target-refspec branch target-branch))
         (format nil "Pushed ~a to ~a." branch target))))))

(defun legit-push-source-candidates ()
  (remove-duplicates
   (append (legit-branch-local-branches)
           (mapcar #'car (legit-reset-revision-candidates)))
   :test #'string=))

(defun legit-push-read-source ()
  (let ((input
          (prompt-for-string
           "Push source branch or commit: "
           :initial-value (or (legit-fetch-current-branch) "HEAD")
           :history-symbol '*legit-push-source-history*
           :completion-function
           (lambda (query)
             (completion-strings query (legit-push-source-candidates))))))
    (when input
      (legit-reset-normalize-revision input)
      input)))

(defun legit-push-other (options)
  (alexandria:when-let ((source (legit-push-read-source)))
    (alexandria:when-let
        ((target
           (legit-push-read-target
            (format nil "Push ~a to: " source))))
      (multiple-value-bind (remote target-branch)
          (legit-push-split-target target)
        (legit-push-run
         options remote
         (list (legit-push-target-refspec source target-branch))
         (format nil "Pushed ~a to ~a." source target))))))

(defun legit-push-parse-refspecs (input)
  "Return a bounded list of comma-separated push refspecs."
  (let ((refspecs
          (mapcar #'str:trim (uiop:split-string input :separator '(#\,)))))
    (when (or (null refspecs)
              (> (length refspecs) *legit-push-refspec-limit*))
      (editor-error "Push accepts between 1 and ~d refspecs."
                    *legit-push-refspec-limit*))
    (dolist (refspec refspecs)
      (legit-fetch-validate-value refspec "push refspec"))
    refspecs))

(defun legit-push-refspecs (options)
  (alexandria:when-let ((remote (legit-push-read-remote "Push to remote: ")))
    (alexandria:when-let
        ((input
           (prompt-for-string
            "Push refspecs (comma separated): "
            :history-symbol '*legit-push-refspec-history*)))
      (legit-push-run
       options remote (legit-push-parse-refspecs input)
       (format nil "Pushed explicit refspecs to ~a." remote)))))

(defun legit-push-matching (options)
  (alexandria:when-let
      ((remote (legit-push-read-remote "Push matching branches to: ")))
    (legit-push-run options remote '(":")
                    (format nil "Pushed matching branches to ~a." remote))))

(defun legit-push-tags ()
  (legit-push-lines
   '("for-each-ref" "--format=%(refname:short)" "refs/tags")))

(defun legit-push-read-tag ()
  (let ((tags (legit-push-tags)))
    (unless tags (editor-error "There are no tags to push."))
    (alexandria:when-let
        ((tag
           (prompt-for-string
            "Push tag: "
            :history-symbol '*legit-push-tag-history*
            :completion-function
            (lambda (query) (completion-strings query tags)))))
      (unless (member tag tags :test #'string=)
        (editor-error "Tag ~a does not exist." tag))
      tag)))

(defun legit-push-one-tag (options)
  (alexandria:when-let ((tag (legit-push-read-tag)))
    (alexandria:when-let
        ((remote (legit-push-read-remote
                  (format nil "Push ~a to remote: " tag))))
      (legit-push-run options remote (list tag)
                      (format nil "Pushed tag ~a to ~a." tag remote)))))

(defun legit-push-all-tags (options)
  (alexandria:when-let
      ((remote (legit-push-read-remote "Push all tags to remote: ")))
    (let ((options (copy-legit-push-options options)))
      (setf (legit-push-options-all-tags-p options) t)
      (legit-push-run options remote '()
                      (format nil "Pushed all tags to ~a." remote)))))

(defun legit-push-notes-refs ()
  (legit-push-lines
   '("for-each-ref" "--format=%(refname)" "refs/notes")))

(defun legit-push-notes (options)
  (let ((refs (legit-push-notes-refs)))
    (unless refs (editor-error "There are no notes refs to push."))
    (alexandria:when-let
        ((ref
           (prompt-for-string
            "Push notes ref: "
            :history-symbol '*legit-push-notes-history*
            :completion-function
            (lambda (query) (completion-strings query refs)))))
      (unless (member ref refs :test #'string=)
        (editor-error "Notes ref ~a does not exist." ref))
      (alexandria:when-let
          ((remote (legit-push-read-remote
                    (format nil "Push ~a to remote: " ref))))
        (legit-push-run options remote (list ref)
                        (format nil "Pushed ~a to ~a." ref remote))))))

(defun legit-push-option-description (enabled description)
  (format nil "[~a] ~a" (if enabled "x" " ") description))

(defun legit-push-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-push-popup-keymap (options)
  (let ((keymap (make-keymap :description "Push")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(("- f" ,(legit-push-option-description
                      (legit-push-options-force-with-lease-p options)
                      "force with lease"))
            ("- F" ,(legit-push-option-description
                      (legit-push-options-force-p options) "force"))
            ("- h" ,(legit-push-option-description
                      (legit-push-options-no-verify-p options)
                      "disable hooks"))
            ("- n" ,(legit-push-option-description
                      (legit-push-options-dry-run-p options) "dry run"))
            ("- u" ,(legit-push-option-description
                      (legit-push-options-set-upstream-p options)
                      "set upstream"))
            ("- T" ,(legit-push-option-description
                      (legit-push-options-all-tags-p options)
                      "include all tags"))
            ("- t" ,(legit-push-option-description
                      (legit-push-options-follow-tags-p options)
                      "include related annotated tags"))
            ("p" ,(format nil "push remote: ~a"
                          (or (legit-push-configured-remote) "<configure>")))
            ("u" ,(format nil "upstream: ~a"
                          (or (legit-reset-upstream
                               (or (legit-fetch-current-branch) ""))
                              "<configure>")))
            ("e" "elsewhere")
            ("o" "another branch or commit")
            ("r" "explicit refspecs")
            ("m" "matching branches")
            ("T" "one tag")
            ("t" "all tags")
            ("n" "notes ref")
            ("C" "configure branch")
            ("q" "cancel")))
      (legit-push-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-push-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (string= name "-")
        (format nil "- ~a"
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun legit-push-toggle-force-with-lease (options)
  (setf (legit-push-options-force-with-lease-p options)
        (not (legit-push-options-force-with-lease-p options))
        (legit-push-options-force-p options) nil))

(defun legit-push-toggle-force (options)
  (setf (legit-push-options-force-p options)
        (not (legit-push-options-force-p options))
        (legit-push-options-force-with-lease-p options) nil))

(defun dispatch-legit-push ()
  "Display and execute the configured Evil Collection Magit push dispatch."
  (let ((options (make-legit-push-options)))
    (unwind-protect
         (loop
           :for keymap := (legit-push-popup-keymap options)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-push-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Push cancelled.")
                   (return nil))
                  ((string= name "- f")
                   (legit-push-toggle-force-with-lease options))
                  ((string= name "- F")
                   (legit-push-toggle-force options))
                  ((string= name "- h")
                   (setf (legit-push-options-no-verify-p options)
                         (not (legit-push-options-no-verify-p options))))
                  ((string= name "- n")
                   (setf (legit-push-options-dry-run-p options)
                         (not (legit-push-options-dry-run-p options))))
                  ((string= name "- u")
                   (setf (legit-push-options-set-upstream-p options)
                         (not (legit-push-options-set-upstream-p options))))
                  ((string= name "- T")
                   (setf (legit-push-options-all-tags-p options)
                         (not (legit-push-options-all-tags-p options))))
                  ((string= name "- t")
                   (setf (legit-push-options-follow-tags-p options)
                         (not (legit-push-options-follow-tags-p options))))
                  ((string= name "p")
                   (legit-push-current-to-push-remote options)
                   (return t))
                  ((string= name "u")
                   (legit-push-current-to-upstream options)
                   (return t))
                  ((string= name "e")
                   (legit-push-current-elsewhere options)
                   (return t))
                  ((string= name "o")
                   (legit-push-other options)
                   (return t))
                  ((string= name "r")
                   (legit-push-refspecs options)
                   (return t))
                  ((string= name "m")
                   (legit-push-matching options)
                   (return t))
                  ((string= name "T")
                   (legit-push-one-tag options)
                   (return t))
                  ((string= name "t")
                   (legit-push-all-tags options)
                   (return t))
                  ((string= name "n")
                   (legit-push-notes options)
                   (return t))
                  ((string= name "C")
                   (alexandria:when-let
                       ((branch
                          (legit-branch-read-local
                           "Configure branch: " :include-current-p t)))
                     (legit-branch-configure branch)))
                  (t
                   (message "No push action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-push () ()
  "Open the configured Evil Collection Magit push dispatch."
  (lem/legit::with-current-project (vcs)
    (legit-push-require-git vcs)
    (dispatch-legit-push)))

(define-key lem/legit::*peek-legit-keymap* "p" 'lem-yath-legit-push)
(define-key lem/legit::*legit-diff-mode-keymap* "p" 'lem-yath-legit-push)
