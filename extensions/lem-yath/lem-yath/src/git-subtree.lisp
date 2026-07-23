;;;; Evil-Collection-compatible Magit subtree dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-subtree-timeout* 300)
(defparameter *legit-subtree-output-limit* (* 4 1024 1024))
(defparameter *legit-subtree-value-limit* 4096)

(defvar *legit-subtree-prefix-history* nil)
(defvar *legit-subtree-message-history* nil)
(defvar *legit-subtree-repository-history* nil)
(defvar *legit-subtree-ref-history* nil)
(defvar *legit-subtree-revision-history* nil)
(defvar *legit-subtree-annotate-history* nil)
(defvar *legit-subtree-branch-history* nil)
(defvar *legit-subtree-dispatch-window* nil)

(defstruct legit-subtree-import-options
  prefix message squash-p)

(defstruct legit-subtree-export-options
  prefix annotate branch onto ignore-joins-p rejoin-p)

(defun legit-subtree-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Subtree commands are available only in a Git repository.")))

(defun legit-subtree-run-program (arguments)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-subtree-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :output-limit *legit-subtree-output-limit*)))

(defun legit-subtree-refresh ()
  (let ((window (or *legit-subtree-dispatch-window* (current-window))))
    (lem/legit::show-legit-status)
    (when (and window (not (deleted-window-p window)))
      (setf (current-window) window))))

(defun legit-subtree-run (arguments success-message)
  "Run one bounded subtree command, refresh Legit, and report its result."
  (multiple-value-bind (output error-output status)
      (legit-subtree-run-program arguments)
    (legit-subtree-refresh)
    (if (and (integerp status) (zerop status))
        (progn
          (message "~a" success-message)
          (values t (str:trim output)))
        (progn
          (lem/legit::pop-up-message
           (legit-command-error-text output error-output))
          (values nil nil)))))

(defun legit-subtree-bounded-value (value description
                                    &key allow-blank-p allow-leading-option-p
                                      allow-whitespace-p)
  "Validate one direct-argument VALUE without changing meaningful spaces."
  (when (or (null value) (and (not allow-blank-p) (str:blankp value)))
    (editor-error "A ~a is required." description))
  (when (> (length value) *legit-subtree-value-limit*)
    (editor-error "The ~a is limited to 4096 characters." description))
  (when (or (find (code-char 0) value) (find #\Newline value)
            (find #\Return value))
    (editor-error "The ~a cannot contain NUL or a newline." description))
  (when (and (not allow-leading-option-p)
             (plusp (length value))
             (char= (char value 0) #\-))
    (editor-error "The ~a cannot begin with an option marker." description))
  (when (and (not allow-whitespace-p)
             (find-if (lambda (character)
                        (member character '(#\Space #\Tab)))
                      value))
    (editor-error "The ~a cannot contain whitespace." description))
  value)

(defun legit-subtree-prefix-valid-p (prefix)
  "Return true for a bounded repository-relative subtree PREFIX."
  (and (stringp prefix)
       (str:non-blank-string-p prefix)
       (<= (length prefix) *legit-subtree-value-limit*)
       (not (find (code-char 0) prefix))
       (not (find #\Newline prefix))
       (not (find #\Return prefix))
       (char/= (char prefix 0) #\/)
       (let ((components (uiop:split-string prefix :separator "/")))
         (and components
              (not (some (lambda (component)
                           (member component '("" "." ".." ".git")
                                   :test #'string=))
                         components))))))

(defun legit-subtree-validate-prefix (prefix)
  (unless (legit-subtree-prefix-valid-p prefix)
    (editor-error "The subtree prefix must be a bounded repository-relative path without .git, . or .. components."))
  prefix)

(defun legit-subtree-read-prefix (prompt &optional initial-value)
  (alexandria:when-let
      ((prefix
         (prompt-for-string
          prompt :initial-value (or initial-value "")
          :history-symbol '*legit-subtree-prefix-history*)))
    (legit-subtree-validate-prefix prefix)))

(defun legit-subtree-read-option (prompt history-symbol description
                                  &optional initial-value)
  "Read an optional value and return VALUE, PROVIDED-P.

Blank input explicitly clears the option; prompt cancellation preserves it."
  (let ((value
          (prompt-for-string prompt :initial-value (or initial-value "")
                             :history-symbol history-symbol)))
    (cond
      ((null value) (values nil nil))
      ((str:blankp value) (values nil t))
      (t
       (values
        (legit-subtree-bounded-value
         value description :allow-leading-option-p t
                           :allow-whitespace-p t)
        t)))))

(defun legit-subtree-read-repository (prompt)
  (legit-fetch-read-value
   prompt (legit-fetch-remotes) '*legit-subtree-repository-history*
   "repository or URL" (legit-fetch-current-remote) t))

(defun legit-subtree-read-ref (prompt)
  (legit-fetch-read-value
   prompt '() '*legit-subtree-ref-history* "reference"))

(defun legit-subtree-read-revision (prompt &optional initial-value)
  (let ((input
          (prompt-for-string
           prompt :initial-value (or initial-value "")
           :history-symbol '*legit-subtree-revision-history*)))
    (when input
      (legit-subtree-bounded-value input "revision")
      (legit-reset-normalize-revision input))))

(defun legit-subtree-import-arguments (options)
  (append
   (when (legit-subtree-import-options-message options)
     (list (format nil "--message=~a"
                   (legit-subtree-import-options-message options))))
   (when (legit-subtree-import-options-squash-p options) '("--squash"))))

(defun legit-subtree-export-arguments (options)
  (append
   (when (legit-subtree-export-options-annotate options)
     (list (format nil "--annotate=~a"
                   (legit-subtree-export-options-annotate options))))
   (when (legit-subtree-export-options-branch options)
     (list (format nil "--branch=~a"
                   (legit-subtree-export-options-branch options))))
   (when (legit-subtree-export-options-onto options)
     (list (format nil "--onto=~a"
                   (legit-subtree-export-options-onto options))))
   (when (legit-subtree-export-options-ignore-joins-p options)
     '("--ignore-joins"))
   (when (legit-subtree-export-options-rejoin-p options) '("--rejoin"))))

(defun legit-subtree-import-prefix (options prompt)
  (or (legit-subtree-import-options-prefix options)
      (legit-subtree-read-prefix prompt)))

(defun legit-subtree-export-prefix (options prompt)
  (or (legit-subtree-export-options-prefix options)
      (legit-subtree-read-prefix prompt)))

(defun legit-subtree-add (options)
  (alexandria:when-let*
      ((prefix (legit-subtree-import-prefix options "Add subtree prefix: "))
       (repository (legit-subtree-read-repository "From repository: "))
       (ref (legit-subtree-read-ref "Ref: ")))
    (legit-subtree-run
     (append (list "subtree" "add" (format nil "--prefix=~a" prefix))
             (legit-subtree-import-arguments options)
             (list repository ref))
     (format nil "Added subtree ~a." prefix))))

(defun legit-subtree-add-commit (options)
  (alexandria:when-let*
      ((prefix (legit-subtree-import-prefix options "Add subtree prefix: "))
       (commit (legit-subtree-read-revision "Commit: ")))
    (legit-subtree-run
     (append (list "subtree" "add" (format nil "--prefix=~a" prefix))
             (legit-subtree-import-arguments options)
             (list commit))
     (format nil "Added commit as subtree ~a." prefix))))

(defun legit-subtree-merge (options)
  (alexandria:when-let*
      ((prefix (legit-subtree-import-prefix options "Merge into subtree: "))
       (commit (legit-subtree-read-revision "Commit: ")))
    (legit-subtree-run
     (append (list "subtree" "merge" (format nil "--prefix=~a" prefix))
             (legit-subtree-import-arguments options)
             (list commit))
     (format nil "Merged into subtree ~a." prefix))))

(defun legit-subtree-pull (options)
  (alexandria:when-let*
      ((prefix (legit-subtree-import-prefix options "Pull into subtree: "))
       (repository (legit-subtree-read-repository "From repository: "))
       (ref (legit-subtree-read-ref "Ref: ")))
    (legit-subtree-run
     (append (list "subtree" "pull" (format nil "--prefix=~a" prefix))
             (legit-subtree-import-arguments options)
             (list repository ref))
     (format nil "Pulled into subtree ~a." prefix))))

(defun legit-subtree-push (options)
  (alexandria:when-let*
      ((prefix (legit-subtree-export-prefix options "Push subtree prefix: "))
       (repository (legit-subtree-read-repository "To repository: "))
       (ref (legit-subtree-read-ref "To reference: ")))
    (legit-subtree-run
     (append (list "subtree" "push" (format nil "--prefix=~a" prefix))
             (legit-subtree-export-arguments options)
             (list repository ref))
     (format nil "Pushed subtree ~a." prefix))))

(defun legit-subtree-split (options)
  (alexandria:when-let*
      ((prefix (legit-subtree-export-prefix options "Split subtree prefix: "))
       (commit (legit-subtree-read-revision "Commit: " "HEAD")))
    (multiple-value-bind (success output)
        (legit-subtree-run
         (append (list "subtree" "split" (format nil "--prefix=~a" prefix))
                 (legit-subtree-export-arguments options)
                 (list commit))
         (format nil "Split subtree ~a." prefix))
      (when (and success (str:non-blank-string-p output))
        (message "Split subtree ~a at ~a." prefix output))
      success)))

(defun legit-subtree-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-subtree-top-popup-keymap ()
  (let ((keymap (make-keymap :description "Subtree")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist (entry '(("i" "import") ("e" "export") ("q" "cancel")))
      (legit-subtree-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-subtree-import-popup-keymap (options)
  (let ((keymap (make-keymap :description "Subtree import")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(("- P" ,(format nil "prefix: ~a"
                            (or (legit-subtree-import-options-prefix options)
                                "<prompt>")))
            ("- m" ,(format nil "message: ~a"
                            (or (legit-subtree-import-options-message options)
                                "unset")))
            ("- s" ,(format nil "[~a] squash"
                            (if (legit-subtree-import-options-squash-p options)
                                "x" " ")))
            ("a" "add") ("c" "add commit") ("m" "merge")
            ("f" "pull") ("q" "return")))
      (legit-subtree-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-subtree-export-popup-keymap (options)
  (let ((keymap (make-keymap :description "Subtree export")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(("- P" ,(format nil "prefix: ~a"
                            (or (legit-subtree-export-options-prefix options)
                                "<prompt>")))
            ("- a" ,(format nil "annotate: ~a"
                            (or (legit-subtree-export-options-annotate options)
                                "unset")))
            ("- b" ,(format nil "branch: ~a"
                            (or (legit-subtree-export-options-branch options)
                                "unset")))
            ("- o" ,(format nil "onto: ~a"
                            (or (legit-subtree-export-options-onto options)
                                "unset")))
            ("- i" ,(format nil "[~a] ignore joins"
                            (if (legit-subtree-export-options-ignore-joins-p options)
                                "x" " ")))
            ("- j" ,(format nil "[~a] rejoin"
                            (if (legit-subtree-export-options-rejoin-p options)
                                "x" " ")))
            ("p" "push") ("s" "split") ("q" "return")))
      (legit-subtree-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-subtree-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (string= name "-")
        (format nil "- ~a"
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun dispatch-legit-subtree-import ()
  (let ((options (make-legit-subtree-import-options)))
    (unwind-protect
         (loop
           :for keymap := (legit-subtree-import-popup-keymap options)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-subtree-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (return nil))
                  ((string= name "- P")
                   (alexandria:when-let
                       ((prefix
                          (legit-subtree-read-prefix
                           "Prefix: "
                           (legit-subtree-import-options-prefix options))))
                     (setf (legit-subtree-import-options-prefix options)
                           prefix)))
                  ((string= name "- m")
                   (multiple-value-bind (value provided-p)
                       (legit-subtree-read-option
                        "Message (blank unsets): "
                        '*legit-subtree-message-history* "message"
                        (legit-subtree-import-options-message options))
                     (when provided-p
                       (setf (legit-subtree-import-options-message options)
                             value))))
                  ((string= name "- s")
                   (setf (legit-subtree-import-options-squash-p options)
                         (not (legit-subtree-import-options-squash-p options))))
                  ((string= name "a") (legit-subtree-add options) (return t))
                  ((string= name "c")
                   (legit-subtree-add-commit options) (return t))
                  ((string= name "m") (legit-subtree-merge options) (return t))
                  ((string= name "f") (legit-subtree-pull options) (return t))
                  (t (message "No subtree import action is bound to ~a" name)
                     (return nil)))))
      (lem/transient::hide-transient))))

(defun legit-subtree-read-branch-option (options)
  (let ((name
          (prompt-for-string
           "Branch (blank unsets): "
           :initial-value (or (legit-subtree-export-options-branch options) "")
           :history-symbol '*legit-subtree-branch-history*)))
    (cond
      ((null name) (legit-subtree-export-options-branch options))
      ((str:blankp name) nil)
      ((legit-branch-name-valid-p name) name)
      (t (editor-error "The subtree branch is not a valid Git branch name.")))))

(defun legit-subtree-read-onto-option (options)
  (let ((input
          (prompt-for-string
           "Onto revision (blank unsets): "
           :initial-value (or (legit-subtree-export-options-onto options) "")
           :history-symbol '*legit-subtree-revision-history*)))
    (cond
      ((null input) (legit-subtree-export-options-onto options))
      ((str:blankp input) nil)
      (t
       (legit-subtree-bounded-value input "onto revision")
       (legit-reset-normalize-revision input)))))

(defun dispatch-legit-subtree-export ()
  (let ((options (make-legit-subtree-export-options)))
    (unwind-protect
         (loop
           :for keymap := (legit-subtree-export-popup-keymap options)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-subtree-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (return nil))
                  ((string= name "- P")
                   (alexandria:when-let
                       ((prefix
                          (legit-subtree-read-prefix
                           "Prefix: "
                           (legit-subtree-export-options-prefix options))))
                     (setf (legit-subtree-export-options-prefix options)
                           prefix)))
                  ((string= name "- a")
                   (multiple-value-bind (value provided-p)
                       (legit-subtree-read-option
                        "Annotate (blank unsets): "
                        '*legit-subtree-annotate-history* "annotation"
                        (legit-subtree-export-options-annotate options))
                     (when provided-p
                       (setf (legit-subtree-export-options-annotate options)
                             value))))
                  ((string= name "- b")
                   (setf (legit-subtree-export-options-branch options)
                         (legit-subtree-read-branch-option options)))
                  ((string= name "- o")
                   (setf (legit-subtree-export-options-onto options)
                         (legit-subtree-read-onto-option options)))
                  ((string= name "- i")
                   (setf (legit-subtree-export-options-ignore-joins-p options)
                         (not (legit-subtree-export-options-ignore-joins-p options))))
                  ((string= name "- j")
                   (setf (legit-subtree-export-options-rejoin-p options)
                         (not (legit-subtree-export-options-rejoin-p options))))
                  ((string= name "p") (legit-subtree-push options) (return t))
                  ((string= name "s") (legit-subtree-split options) (return t))
                  (t (message "No subtree export action is bound to ~a" name)
                     (return nil)))))
      (lem/transient::hide-transient))))

(defun dispatch-legit-subtree ()
  "Display and execute the configured Magit subtree dispatch."
  (unwind-protect
       (progn
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate (legit-subtree-top-popup-keymap)))
         (redraw-display)
         (let ((name (legit-subtree-read-popup-key)))
           (lem/transient::hide-transient)
           (cond
             ((or (string= name "q") (string= name "Escape"))
              (message "Subtree dispatch cancelled.") nil)
             ((string= name "i") (dispatch-legit-subtree-import))
             ((string= name "e") (dispatch-legit-subtree-export))
             (t (message "No subtree action is bound to ~a" name) nil))))
    (lem/transient::hide-transient)))

(define-command lem-yath-legit-subtree () ()
  "Open the configured Evil Collection Magit subtree dispatch."
  (lem/legit::with-current-project (vcs)
    (legit-subtree-require-git vcs)
    (let ((*legit-subtree-dispatch-window* (current-window)))
      (dispatch-legit-subtree))))

;; Reset both maps before binding so a source reload is deterministic.
(undefine-key lem/legit::*peek-legit-keymap* "\"")
(undefine-key lem/legit::*legit-diff-mode-keymap* "\"")
(define-key lem/legit::*peek-legit-keymap* "\"" 'lem-yath-legit-subtree)
(define-key lem/legit::*legit-diff-mode-keymap* "\"" 'lem-yath-legit-subtree)
