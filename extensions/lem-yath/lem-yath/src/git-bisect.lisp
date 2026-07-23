;;;; Magit-compatible Git bisect lifecycle for Legit.

(in-package :lem-yath)

(defparameter *legit-bisect-timeout* 30)
(defparameter *legit-bisect-run-timeout* 300)
(defparameter *legit-bisect-output-limit* (* 4 1024 1024))
(defparameter *legit-bisect-command-limit* 8192)
(defparameter *legit-bisect-log-limit* 40)

(defvar *legit-bisect-revision-history* nil)
(defvar *legit-bisect-command-history* nil)
(defvar *legit-bisect-dispatch-keymap*
  (make-keymap :description "Bisect"))

(defstruct legit-bisect-options
  no-checkout-p
  first-parent-p
  term-old
  term-new)

(defstruct legit-bisect-log-entry
  term
  hash
  subject)

(defun legit-bisect-in-progress-p ()
  "Return true when Git has an active or completed-but-not-reset bisect."
  (legit-git-metadata-path-exists-p "BISECT_LOG"))

(defun legit-bisect-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Bisect is available only in a Git repository.")))

(defun legit-bisect-run-program
    (arguments &key (timeout *legit-bisect-timeout*))
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* timeout))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :output-limit *legit-bisect-output-limit*)))

(defun legit-bisect-run-git (arguments success-message &key timeout)
  "Run a bisect command, refresh Legit, and report its result."
  (multiple-value-bind (output error-output status)
      (legit-bisect-run-program arguments
                                :timeout (or timeout *legit-bisect-timeout*))
    (lem/legit::show-legit-status)
    (if (and (integerp status) (zerop status))
        (progn
          (message "~a" success-message)
          t)
        (progn
          (lem/legit::pop-up-message
           (legit-command-error-text output error-output))
          nil))))

(defun legit-bisect-normalize-revision (revision)
  "Resolve REVISION to one commit hash without accepting whitespace."
  (let ((revision (str:trim revision)))
    (when (str:blankp revision)
      (editor-error "A Git revision is required."))
    (when (find-if (lambda (character)
                     (member character '(#\Space #\Tab #\Newline #\Return)))
                   revision)
      (editor-error "A Git revision cannot contain whitespace."))
    (multiple-value-bind (output error-output status)
        (legit-bisect-run-program
         (list "rev-parse" "--verify" (format nil "~a^{commit}" revision)))
      (unless (and (integerp status) (zerop status))
        (editor-error "~a" (legit-command-error-text output error-output)))
      (str:trim output))))

(defun legit-bisect-read-revision (prompt initial-value)
  "Read one revision using the same bounded all-ref choices as cherry-pick."
  (let* ((candidates (legit-cherry-pick-candidates))
         (labels (mapcar #'car candidates))
         (input
           (prompt-for-string
            prompt
            :initial-value initial-value
            :history-symbol '*legit-bisect-revision-history*
            :completion-function
            (lambda (query) (completion-strings query labels)))))
    (when input
      (legit-bisect-normalize-revision
       (or (cdr (assoc input candidates :test #'string=)) input)))))

(defun legit-bisect-worktree-clean-p ()
  (multiple-value-bind (output error-output status)
      (legit-bisect-run-program
       '("status" "--porcelain=v1" "--untracked-files=normal"))
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    (str:blankp output)))

(defun legit-bisect-ancestor-p (ancestor descendant)
  (multiple-value-bind (output error-output status)
      (legit-bisect-run-program
       (list "merge-base" "--is-ancestor" ancestor descendant))
    (cond
      ((eql status 0) t)
      ((eql status 1) nil)
      (t (editor-error "~a"
                       (legit-command-error-text output error-output))))))

(defun legit-bisect-valid-term-p (term)
  (and (plusp (length term))
       (<= (length term) 64)
       (every (lambda (character)
                (or (alphanumericp character)
                    (member character '(#\- #\_))))
              term)))

(defun legit-bisect-read-term (prompt current)
  (let ((term (prompt-for-string prompt :initial-value (or current ""))))
    (when term
      (let ((term (str:trim term)))
        (cond
          ((str:blankp term) nil)
          ((legit-bisect-valid-term-p term) term)
          (t (editor-error
              "Bisect terms use at most 64 letters, digits, hyphens, or underscores.")))))))

(defun legit-bisect-start-arguments (options bad good)
  (append
   (list "bisect" "start")
   (when (legit-bisect-options-no-checkout-p options)
     '("--no-checkout"))
   (when (legit-bisect-options-first-parent-p options)
     '("--first-parent"))
   (when (legit-bisect-options-term-old options)
     (list (format nil "--term-old=~a"
                   (legit-bisect-options-term-old options))))
   (when (legit-bisect-options-term-new options)
     (list (format nil "--term-new=~a"
                   (legit-bisect-options-term-new options))))
   (list bad good)))

(defun legit-bisect-read-start-revisions ()
  "Read and validate Magit's bad/new and good/old start revisions."
  (let* ((default (or (text-property-at (current-point) :commit-hash)
                      "HEAD"))
         (bad (legit-bisect-read-revision "Start bisect with bad revision: "
                                          default))
         (good (and bad
                    (legit-bisect-read-revision "Good revision: " ""))))
    (when (and bad good)
      (when (string= bad good)
        (editor-error "The good and bad revisions must differ."))
      (unless (legit-bisect-ancestor-p good bad)
        (editor-error "The good revision must be an ancestor of the bad revision."))
      (unless (legit-bisect-worktree-clean-p)
        (editor-error "Cannot bisect with uncommitted or untracked changes."))
      (values bad good))))

(defun legit-bisect-start-session (options bad good)
  (legit-bisect-run-git
   (legit-bisect-start-arguments options bad good)
   "Bisect started."))

(defun legit-bisect-shell ()
  (or (alexandria:when-let ((shell (uiop:getenv "SHELL")))
        (alexandria:when-let ((executable (executable-find shell)))
          (uiop:native-namestring executable)))
      (alexandria:when-let ((shell (executable-find "sh")))
        (uiop:native-namestring shell))
      (editor-error "No shell is available for git bisect run.")))

(defun legit-bisect-read-command ()
  (let ((command
          (prompt-for-string
           "Bisect shell command: "
           :history-symbol '*legit-bisect-command-history*)))
    (when command
      (let ((command (str:trim command)))
        (when (str:blankp command)
          (editor-error "A bisect command is required."))
        (when (> (length command) *legit-bisect-command-limit*)
          (editor-error "Bisect commands are limited to 8192 characters."))
        command))))

(defun legit-bisect-run-command (command)
  (legit-bisect-run-git
   (list "bisect" "run" (legit-bisect-shell) "-c" command)
   "Bisect script completed."
   :timeout *legit-bisect-run-timeout*))

(defun legit-bisect-terms ()
  "Return Git's active new/bad and old/good terms."
  (labels ((read-term (argument fallback)
             (multiple-value-bind (output error-output status)
                 (legit-bisect-run-program
                  (list "bisect" "terms" argument))
               (declare (ignore error-output))
               (if (and (integerp status) (zerop status)
                        (str:non-blank-string-p output))
                   (str:trim output)
                   fallback))))
    (values (read-term "--term-bad" "bad")
            (read-term "--term-good" "good"))))

(defun legit-bisect-mark-current (which)
  (unless (legit-bisect-in-progress-p)
    (editor-error "No bisect is in progress."))
  (multiple-value-bind (term-new term-old) (legit-bisect-terms)
    (let ((term (ecase which
                  (:new term-new)
                  (:old term-old))))
      (legit-bisect-run-git
       (list "bisect" term)
       (format nil "Marked current revision ~a." term)))))

(defun legit-bisect-mark-prompt ()
  (multiple-value-bind (term-new term-old) (legit-bisect-terms)
    (show-message
     (format nil "Mark current revision as ~a ([n]ew) or ~a ([o]ld): "
             term-new term-old))
    (redraw-display)
    (let ((name (lem-core::keyseq-to-string (list (read-key)))))
      (cond
        ((string= name "n") (legit-bisect-mark-current :new))
        ((string= name "o") (legit-bisect-mark-current :old))
        (t (message "Bisect mark cancelled."))))))

(defun legit-bisect-skip-current ()
  (unless (legit-bisect-in-progress-p)
    (editor-error "No bisect is in progress."))
  (legit-bisect-run-git '("bisect" "skip") "Skipped HEAD."))

(defun legit-bisect-reset-session ()
  (unless (legit-bisect-in-progress-p)
    (editor-error "No bisect is in progress."))
  (when (prompt-for-y-or-n-p "Reset bisect and restore the original HEAD? ")
    (legit-bisect-run-git '("bisect" "reset") "Bisect reset.")))

(defun legit-bisect-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-bisect-popup-keymap (options active-p)
  "Build the current Magit-style bisect transient."
  (let ((keymap
          (make-keymap
           :description
           (if active-p "Bisect (in progress)" "Bisect"))))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (if active-p
        (dolist (entry '(("B" "bad/new")
                         ("g" "good/old")
                         ("m" "mark using terms")
                         ("k" "skip")
                         ("r" "reset")
                         ("s" "run script")))
          (legit-bisect-add-popup-entry keymap (first entry) (second entry)))
        (progn
          (legit-bisect-add-popup-entry
           keymap "- n"
           (format nil "[~a] do not checkout commits"
                   (if (legit-bisect-options-no-checkout-p options) "x" " ")))
          (legit-bisect-add-popup-entry
           keymap "- p"
           (format nil "[~a] follow first parent"
                   (if (legit-bisect-options-first-parent-p options) "x" " ")))
          (legit-bisect-add-popup-entry
           keymap "= o"
           (format nil "old/good term: ~a"
                   (or (legit-bisect-options-term-old options) "good")))
          (legit-bisect-add-popup-entry
           keymap "= n"
           (format nil "new/bad term: ~a"
                   (or (legit-bisect-options-term-new options) "bad")))
          (legit-bisect-add-popup-entry keymap "B" "start")
          (legit-bisect-add-popup-entry keymap "s" "start script")))
    (legit-bisect-add-popup-entry keymap "q" "cancel")
    keymap))

(defun legit-bisect-start-from-popup (options run-script-p)
  (multiple-value-bind (bad good) (legit-bisect-read-start-revisions)
    (when (and bad good)
      (let ((command (and run-script-p (legit-bisect-read-command))))
        (when (or (not run-script-p) command)
          (when (legit-bisect-start-session options bad good)
            (when command (legit-bisect-run-command command))))))))

(defun legit-bisect-read-popup-key ()
  "Read one bisect action, including Magit's two-event argument keys."
  (let* ((first (read-key))
         (first-name (lem-core::keyseq-to-string (list first))))
    (if (member first-name '("-" "=") :test #'string=)
        (let* ((second (read-key))
               (second-name
                 (lem-core::keyseq-to-string (list second))))
          (format nil "~a ~a" first-name second-name))
        first-name)))

(defun dispatch-legit-bisect ()
  "Display and execute one configured Magit bisect action."
  (let ((options (make-legit-bisect-options)))
    (unwind-protect
         (loop
           :for active-p := (legit-bisect-in-progress-p)
           :for keymap := (legit-bisect-popup-keymap options active-p)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-bisect-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Bisect cancelled.")
                   (return nil))
                  ((and (not active-p) (string= name "- n"))
                   (setf (legit-bisect-options-no-checkout-p options)
                         (not (legit-bisect-options-no-checkout-p options))))
                  ((and (not active-p) (string= name "- p"))
                   (setf (legit-bisect-options-first-parent-p options)
                         (not (legit-bisect-options-first-parent-p options))))
                  ((and (not active-p) (string= name "= o"))
                   (setf (legit-bisect-options-term-old options)
                         (legit-bisect-read-term
                          "Old/good term (blank for good): "
                          (legit-bisect-options-term-old options))))
                  ((and (not active-p) (string= name "= n"))
                   (setf (legit-bisect-options-term-new options)
                         (legit-bisect-read-term
                          "New/bad term (blank for bad): "
                          (legit-bisect-options-term-new options))))
                  ((and (not active-p) (string= name "B"))
                   (legit-bisect-start-from-popup options nil)
                   (return t))
                  ((and (not active-p) (string= name "s"))
                   (legit-bisect-start-from-popup options t)
                   (return t))
                  ((and active-p (string= name "B"))
                   (legit-bisect-mark-current :new)
                   (return t))
                  ((and active-p (string= name "g"))
                   (legit-bisect-mark-current :old)
                   (return t))
                  ((and active-p (string= name "m"))
                   (legit-bisect-mark-prompt)
                   (return t))
                  ((and active-p (string= name "k"))
                   (legit-bisect-skip-current)
                   (return t))
                  ((and active-p (string= name "r"))
                   (legit-bisect-reset-session)
                   (return t))
                  ((and active-p (string= name "s"))
                   (alexandria:when-let ((command (legit-bisect-read-command)))
                     (legit-bisect-run-command command))
                   (return t))
                  (t
                   (message "No bisect action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-bisect () ()
  "Open the configured Magit-compatible Git bisect transient."
  (lem/legit::with-current-project (vcs)
    (legit-bisect-require-git vcs)
    (dispatch-legit-bisect)))

(defun parse-legit-bisect-log (output)
  "Parse bounded `git bisect log' OUTPUT for status rendering."
  (let ((entries '()))
    (dolist (line (str:lines output))
      (cl-ppcre:register-groups-bind (term hash subject)
          ("^# (good|bad|skip): \\[([0-9a-f]{7,64})\\] (.*)$" line)
        (when term
          (push (make-legit-bisect-log-entry
                 :term term :hash hash :subject subject)
                entries)))
      (cl-ppcre:register-groups-bind (hash subject)
          ("^# first bad commit: \\[([0-9a-f]{7,64})\\] (.*)$" line)
        (when hash
          (push (make-legit-bisect-log-entry
                 :term "first bad" :hash hash :subject subject)
                entries))))
    (let ((entries (nreverse entries)))
      (subseq entries
              (max 0 (- (length entries) *legit-bisect-log-limit*))))))

(defun legit-bisect-status-data ()
  "Return current HEAD metadata and parsed bisect log entries."
  (let ((revision (if (legit-git-metadata-path-exists-p "BISECT_HEAD")
                      "BISECT_HEAD"
                      "HEAD")))
    (multiple-value-bind (head-output head-error head-status)
        (legit-bisect-run-program
         (list "log" "-1" "--format=%H%x00%s" revision))
    (unless (and (integerp head-status) (zerop head-status))
      (error "~a" (legit-command-error-text head-output head-error)))
    (multiple-value-bind (log-output log-error log-status)
        (legit-bisect-run-program '("bisect" "log"))
      (unless (and (integerp log-status) (zerop log-status))
        (error "~a" (legit-command-error-text log-output log-error)))
      (let ((separator (position #\Null head-output)))
        (unless separator (error "Git returned malformed HEAD metadata."))
        (values (subseq head-output 0 separator)
                (str:trim (subseq head-output (1+ separator)))
                (parse-legit-bisect-log log-output)))))))

(defun insert-legit-bisect-section (vcs collector)
  "Insert active bisect state into Legit status like Magit's sections."
  (declare (ignore collector))
  (unless (and (string-equal "git" (lem/porcelain::vcs-name vcs))
               (legit-bisect-in-progress-p))
    (return-from insert-legit-bisect-section))
  (handler-case
      (multiple-value-bind (head subject entries) (legit-bisect-status-data)
        (multiple-value-bind (term-new term-old) (legit-bisect-terms)
          (lem/legit::collector-insert "")
          (lem/legit::collector-insert "Bisect:" :header t)
          (lem/legit::collector-insert
           (format nil "Testing ~a  ~a  [~a/~a]"
                   (subseq head 0 (min 12 (length head)))
                   (completion-bounded-annotation subject)
                   term-old term-new))
          (lem/legit::collector-insert "Bisect log:" :header t)
          (if entries
              (dolist (entry entries)
                (lem/legit::collector-insert
                 (format nil "~10a ~a  ~a"
                         (legit-bisect-log-entry-term entry)
                         (subseq (legit-bisect-log-entry-hash entry)
                                 0
                                 (min 12
                                      (length
                                       (legit-bisect-log-entry-hash entry))))
                         (completion-bounded-annotation
                          (legit-bisect-log-entry-subject entry)))))
              (lem/legit::collector-insert "<no marks>"))))
    (error (condition)
      (lem/legit::collector-insert "")
      (lem/legit::collector-insert "Bisect (unavailable):" :header t)
      (lem/legit::collector-insert
       (completion-bounded-annotation (princ-to-string condition))))))

(remove-hook lem/legit::*status-section-functions*
             'insert-legit-bisect-section)
(add-hook lem/legit::*status-section-functions*
          'insert-legit-bisect-section)

(define-command lem-yath-legit-bisect-or-todo-base () ()
  "Set the TODO baseline at a TODO section; otherwise open bisect dispatch."
  (if (legit-todo-context-root (current-point))
      (lem-yath-legit-todo-branch-list-set-ref)
      (lem-yath-legit-bisect)))

(define-key lem/legit::*peek-legit-keymap*
  "B" 'lem-yath-legit-bisect-or-todo-base)
(define-key lem/legit::*legit-diff-mode-keymap* "B" 'lem-yath-legit-bisect)
