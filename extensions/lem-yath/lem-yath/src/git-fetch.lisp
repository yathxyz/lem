;;;; Magit-compatible Git fetch dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-fetch-timeout* 120)
(defparameter *legit-fetch-output-limit* (* 4 1024 1024))
(defparameter *legit-fetch-value-limit* 4096)
(defparameter *legit-fetch-candidate-limit* 200)

(defvar *legit-fetch-remote-history* nil)
(defvar *legit-fetch-branch-history* nil)
(defvar *legit-fetch-refspec-history* nil)

(defstruct legit-fetch-options
  prune-p
  tags-p
  unshallow-p
  force-p)

(defun legit-fetch-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Fetch is available only in a Git repository.")))

(defun legit-fetch-run-program (arguments)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-fetch-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :output-limit *legit-fetch-output-limit*)))

(defun legit-fetch-run (options tail success-message)
  "Run `git fetch' with OPTIONS and command TAIL, then refresh Legit."
  (multiple-value-bind (output error-output status)
      (legit-fetch-run-program
       (append (list "fetch")
               (legit-fetch-option-arguments options)
               tail))
    (lem/legit::show-legit-status)
    (if (and (integerp status) (zerop status))
        (progn
          (message "~a" success-message)
          t)
        (progn
          (lem/legit::pop-up-message
           (legit-command-error-text output error-output))
          nil))))

(defun legit-fetch-lines (arguments)
  "Return nonblank lines from bounded Git ARGUMENTS, or signal an error."
  (multiple-value-bind (output error-output status)
      (legit-fetch-run-program arguments)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    (remove-if #'str:blankp (str:lines output))))

(defun legit-fetch-optional-value (arguments)
  "Return Git's trimmed scalar output, or NIL for an ordinary missing value."
  (multiple-value-bind (output error-output status)
      (legit-fetch-run-program arguments)
    (cond
      ((and (integerp status) (zerop status)
            (str:non-blank-string-p output))
       (str:trim output))
      ((eql status 1) nil)
      ((and (integerp status) (zerop status)) nil)
      (t (editor-error "~a"
                       (legit-command-error-text output error-output))))))

(defun legit-fetch-remotes ()
  (let ((remotes (legit-fetch-lines '("remote"))))
    (subseq remotes 0 (min *legit-fetch-candidate-limit*
                           (length remotes)))))

(defun legit-fetch-current-branch ()
  (legit-fetch-optional-value
   '("symbolic-ref" "--quiet" "--short" "HEAD")))

(defun legit-fetch-config-value (name)
  (legit-fetch-optional-value (list "config" "--get" name)))

(defun legit-fetch-remote-valid-p (remote remotes)
  (and remote (member remote remotes :test #'string=)))

(defun legit-fetch-current-remote ()
  "Return Magit's upstream-style current remote fallback."
  (let* ((branch (legit-fetch-current-branch))
         (remotes (legit-fetch-remotes))
         (configured
           (and branch
                (legit-fetch-config-value
                 (format nil "branch.~a.remote" branch)))))
    (cond
      ((legit-fetch-remote-valid-p configured remotes) configured)
      ((= (length remotes) 1) (first remotes))
      ((member "origin" remotes :test #'string=) "origin")
      (t nil))))

(defun legit-fetch-push-remote ()
  "Return an explicitly configured branch or repository push remote."
  (let* ((branch (legit-fetch-current-branch))
         (remotes (legit-fetch-remotes))
         (branch-remote
           (and branch
                (legit-fetch-config-value
                 (format nil "branch.~a.pushRemote" branch))))
         (default-remote
           (legit-fetch-config-value "remote.pushDefault")))
    (cond
      ((legit-fetch-remote-valid-p branch-remote remotes) branch-remote)
      ((legit-fetch-remote-valid-p default-remote remotes) default-remote)
      (t nil))))

(defun legit-fetch-validate-value (value description &optional allow-whitespace-p)
  "Validate one direct-argv fetch VALUE and return its trimmed form."
  (let ((value (str:trim value)))
    (when (str:blankp value)
      (editor-error "A ~a is required." description))
    (when (> (length value) *legit-fetch-value-limit*)
      (editor-error "The ~a is limited to 4096 characters." description))
    (when (char= (char value 0) #\-)
      (editor-error "The ~a cannot begin with an option marker." description))
    (when (and (not allow-whitespace-p)
               (find-if
                (lambda (character)
                  (member character '(#\Space #\Tab #\Newline #\Return)))
                value))
      (editor-error "The ~a cannot contain whitespace." description))
    value))

(defun legit-fetch-read-value (prompt choices history-symbol description
                                &optional initial-value allow-whitespace-p)
  (let ((input
          (prompt-for-string
           prompt
           :initial-value (or initial-value "")
           :history-symbol history-symbol
           :completion-function
           (lambda (query) (completion-strings query choices)))))
    (when input
      (legit-fetch-validate-value input description allow-whitespace-p))))

(defun legit-fetch-read-remote (prompt &optional initial-value)
  (legit-fetch-read-value
   prompt (legit-fetch-remotes) '*legit-fetch-remote-history* "remote or URL"
   initial-value t))

(defun legit-fetch-remote-branches (remote)
  "Return bounded locally known branch names for REMOTE."
  (let* ((prefix (format nil "refs/remotes/~a/" remote))
         (refs
           (legit-fetch-lines
            (list "for-each-ref" "--format=%(refname)" prefix)))
         (branches
           (loop :for ref :in refs
                 :when (alexandria:starts-with-subseq prefix ref)
                   :collect (subseq ref (length prefix)))))
    (subseq branches 0 (min *legit-fetch-candidate-limit*
                            (length branches)))))

(defun legit-fetch-option-arguments (options)
  (append
   (when (legit-fetch-options-prune-p options) '("--prune"))
   (when (legit-fetch-options-tags-p options) '("--tags"))
   (when (legit-fetch-options-unshallow-p options) '("--unshallow"))
   (when (legit-fetch-options-force-p options) '("--force"))))

(defun legit-fetch-configure-push-remote (remote)
  "Persist REMOTE where Magit would configure a missing push remote."
  (let* ((branch (legit-fetch-current-branch))
         (key (if branch
                  (format nil "branch.~a.pushRemote" branch)
                  "remote.pushDefault")))
    (multiple-value-bind (output error-output status)
        (legit-fetch-run-program (list "config" key remote))
      (unless (and (integerp status) (zerop status))
        (editor-error "~a" (legit-command-error-text output error-output))))))

(defun legit-fetch-from-push-remote (options)
  (let* ((remotes (legit-fetch-remotes))
         (configured (legit-fetch-push-remote))
         (remote
           (if (legit-fetch-remote-valid-p configured remotes)
               configured
               (legit-fetch-read-remote "Set push remote and fetch: "))))
    (when remote
      (unless (legit-fetch-remote-valid-p configured remotes)
        (unless (member remote remotes :test #'string=)
          (editor-error "A push remote must name a configured remote."))
        (legit-fetch-configure-push-remote remote))
      (legit-fetch-run options (list remote)
                       (format nil "Fetched from ~a." remote)))))

(defun legit-fetch-from-upstream (options)
  (let ((remote (or (legit-fetch-current-remote)
                    (editor-error "No current remote could be determined."))))
    (legit-fetch-run options (list remote)
                     (format nil "Fetched from ~a." remote))))

(defun legit-fetch-from-elsewhere (options)
  (alexandria:when-let ((remote (legit-fetch-read-remote "Fetch remote: ")))
    (legit-fetch-run options (list remote)
                     (format nil "Fetched from ~a." remote))))

(defun legit-fetch-all-remotes (options)
  (legit-fetch-run options '("--all") "Fetched all remotes."))

(defun legit-fetch-one-branch (options)
  (alexandria:when-let ((remote (legit-fetch-read-remote
                                 "Fetch from remote or URL: ")))
    (alexandria:when-let
        ((branch
           (legit-fetch-read-value
            "Fetch branch: "
            (if (member remote (legit-fetch-remotes) :test #'string=)
                (legit-fetch-remote-branches remote)
                '())
            '*legit-fetch-branch-history* "branch")))
      (legit-fetch-run options (list remote branch)
                       (format nil "Fetched ~a from ~a." branch remote)))))

(defun legit-fetch-explicit-refspec (options)
  (alexandria:when-let ((remote (legit-fetch-read-remote
                                 "Fetch from remote or URL: ")))
    (alexandria:when-let
        ((refspec
           (legit-fetch-read-value
            "Fetch using refspec: " '() '*legit-fetch-refspec-history*
            "refspec")))
      (legit-fetch-run options (list remote refspec)
                       (format nil "Fetched refspec from ~a." remote)))))

(defun legit-fetch-submodules (options)
  (legit-fetch-run options
                   '("--recurse-submodules" "--verbose" "--jobs=4")
                   "Fetched repository and populated submodules."))

(defun legit-fetch-configure-current-branch ()
  "Open Magit's branch-variable surface for the current branch."
  (let ((branch (or (legit-fetch-current-branch)
                    (editor-error "Branch configuration requires a named HEAD."))))
    ;; git-branch.lisp is intentionally loaded later because it reuses the
    ;; fetch helpers above.  Resolve this runtime-only reverse edge explicitly.
    (funcall (symbol-function 'legit-branch-configure) branch)))

(defun legit-fetch-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-fetch-popup-keymap (options)
  "Build the configured Magit fetch transient."
  (let ((keymap (make-keymap :description "Fetch")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(("- p" ,(format nil "[~a] prune deleted branches"
                            (if (legit-fetch-options-prune-p options) "x" " ")))
            ("- t" ,(format nil "[~a] fetch all tags"
                            (if (legit-fetch-options-tags-p options) "x" " ")))
            ("- u" ,(format nil "[~a] fetch full history"
                            (if (legit-fetch-options-unshallow-p options) "x" " ")))
            ("- F" ,(format nil "[~a] force"
                            (if (legit-fetch-options-force-p options) "x" " ")))
            ("p" ,(format nil "push remote: ~a"
                          (or (legit-fetch-push-remote) "<configure>")))
            ("u" ,(format nil "upstream: ~a"
                          (or (legit-fetch-current-remote) "<unavailable>")))
            ("e" "elsewhere")
            ("a" "all remotes")
            ("o" "another branch")
            ("r" "explicit refspec")
            ("m" "submodules")
            ("C" "configure current branch")
            ("q" "cancel")))
      (legit-fetch-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-fetch-read-popup-key ()
  "Read one fetch action, including Magit's two-event option keys."
  (let* ((first (read-key))
         (first-name (lem-core::keyseq-to-string (list first))))
    (if (string= first-name "-")
        (let* ((second (read-key))
               (second-name
                 (lem-core::keyseq-to-string (list second))))
          (format nil "- ~a" second-name))
        first-name)))

(defun dispatch-legit-fetch ()
  "Display and execute one configured Magit fetch action."
  (let ((options (make-legit-fetch-options)))
    (unwind-protect
         (loop
           :for keymap := (legit-fetch-popup-keymap options)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-fetch-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Fetch cancelled.")
                   (return nil))
                  ((string= name "- p")
                   (setf (legit-fetch-options-prune-p options)
                         (not (legit-fetch-options-prune-p options))))
                  ((string= name "- t")
                   (setf (legit-fetch-options-tags-p options)
                         (not (legit-fetch-options-tags-p options))))
                  ((string= name "- u")
                   (setf (legit-fetch-options-unshallow-p options)
                         (not (legit-fetch-options-unshallow-p options))))
                  ((string= name "- F")
                   (setf (legit-fetch-options-force-p options)
                         (not (legit-fetch-options-force-p options))))
                  ((string= name "p")
                   (legit-fetch-from-push-remote options)
                   (return t))
                  ((string= name "u")
                   (legit-fetch-from-upstream options)
                   (return t))
                  ((string= name "e")
                   (legit-fetch-from-elsewhere options)
                   (return t))
                  ((string= name "a")
                   (legit-fetch-all-remotes options)
                   (return t))
                  ((string= name "o")
                   (legit-fetch-one-branch options)
                   (return t))
                  ((string= name "r")
                   (legit-fetch-explicit-refspec options)
                   (return t))
                  ((string= name "m")
                   (legit-fetch-submodules options)
                   (return t))
                  ((string= name "C")
                   (legit-fetch-configure-current-branch))
                  (t
                   (message "No fetch action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-fetch () ()
  "Open the configured Magit-compatible Git fetch transient."
  (lem/legit::with-current-project (vcs)
    (legit-fetch-require-git vcs)
    (dispatch-legit-fetch)))

(define-key lem/legit::*peek-legit-keymap* "f" 'lem-yath-legit-fetch)
(define-key lem/legit::*legit-diff-mode-keymap* "f" 'lem-yath-legit-fetch)
