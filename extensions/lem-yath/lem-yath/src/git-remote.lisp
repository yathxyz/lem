;;;; Evil-Collection-compatible Magit remote dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-remote-timeout* 120)
(defparameter *legit-remote-output-limit* (* 4 1024 1024))
(defparameter *legit-remote-candidate-limit* 5000)
(defparameter *legit-remote-value-limit* 4096)

(defvar *legit-remote-name-history* nil)
(defvar *legit-remote-url-history* nil)
(defvar *legit-remote-config-history* nil)
(defvar *legit-remote-dispatch-window* nil)

(defstruct legit-remote-options
  (fetch-p t))

(defun legit-remote-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Remote commands are available only in a Git repository.")))

(defun legit-remote-run-program (arguments)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-remote-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :output-limit *legit-remote-output-limit*)))

(defun legit-remote-checked-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-remote-run-program arguments)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-remote-refresh ()
  "Refresh Legit while retaining the pane from which the action was invoked."
  (let ((window (or *legit-remote-dispatch-window* (current-window))))
    (lem/legit::show-legit-status)
    (cond
      ((and window (not (deleted-window-p window)))
       (setf (current-window) window))
      ((and lem/legit::*peek-window*
            (not (deleted-window-p lem/legit::*peek-window*)))
       (setf (current-window) lem/legit::*peek-window*)))))

(defun legit-remote-run (arguments success-message)
  "Run Git ARGUMENTS, refresh Legit, and report the bounded result."
  (multiple-value-bind (output error-output status)
      (legit-remote-run-program arguments)
    (legit-remote-refresh)
    (if (and (integerp status) (zerop status))
        (progn
          (message "~a" success-message)
          t)
        (progn
          (lem/legit::pop-up-message
           (legit-command-error-text output error-output))
          nil))))

(defun legit-remote-lines (arguments)
  (let ((lines
          (remove-if #'str:blankp
                     (str:lines (legit-remote-checked-output arguments)))))
    (when (> (length lines) *legit-remote-candidate-limit*)
      (editor-error "Git returned more than ~d remote values."
                    *legit-remote-candidate-limit*))
    lines))

(defun legit-remote-optional-lines (arguments)
  "Return lines from ARGUMENTS, treating Git's ordinary no-match status as empty."
  (multiple-value-bind (output error-output status)
      (legit-remote-run-program arguments)
    (cond
      ((and (integerp status) (zerop status))
       (let ((lines (remove-if #'str:blankp (str:lines output))))
         (when (> (length lines) *legit-remote-candidate-limit*)
           (editor-error "Git returned more than ~d remote values."
                         *legit-remote-candidate-limit*))
         lines))
      ((eql status 1) nil)
      (t (editor-error "~a" (legit-command-error-text output error-output))))))

(defun legit-remote-remotes ()
  (legit-remote-lines '("remote")))

(defun legit-remote-value-valid-p (value description
                                   &key allow-leading-option-p)
  (when (> (length value) *legit-remote-value-limit*)
    (editor-error "The ~a is limited to 4096 characters." description))
  (when (find (code-char 0) value)
    (editor-error "The ~a cannot contain NUL." description))
  (when (and (not allow-leading-option-p)
             (plusp (length value))
             (char= (char value 0) #\-))
    (editor-error "The ~a cannot begin with an option marker." description))
  value)

(defun legit-remote-name-valid-p (name)
  (and (str:non-blank-string-p name)
       (<= (length name) *legit-remote-value-limit*)
       (not (char= (char name 0) #\-))
       (not (find (code-char 0) name))
       (multiple-value-bind (output error-output status)
           (legit-remote-run-program
            (list "check-ref-format"
                  (format nil "refs/remotes/~a/probe" name)))
         (declare (ignore output error-output))
         (and (integerp status) (zerop status)))))

(defun legit-remote-read-existing (prompt &optional initial-value)
  (let ((remotes (legit-remote-remotes)))
    (unless remotes
      (editor-error "There are no configured remotes."))
    (prompt-for-string
     prompt
     :initial-value (or initial-value
                        (legit-fetch-current-remote)
                        (and (= (length remotes) 1) (first remotes))
                        "")
     :history-symbol '*legit-remote-name-history*
     :completion-function
     (lambda (query) (completion-strings query remotes))
     :test-function
     (lambda (value) (member value remotes :test #'string=)))))

(defun legit-remote-read-new-name (prompt &optional initial-value)
  (let ((name
          (prompt-for-string
           prompt
           :initial-value (or initial-value "")
           :history-symbol '*legit-remote-name-history*
           :test-function #'legit-remote-name-valid-p)))
    (when (and name (member name (legit-remote-remotes) :test #'string=))
      (editor-error "Remote ~a already exists." name))
    name))

(defun legit-remote-read-url (prompt &optional initial-value)
  (alexandria:when-let
      ((url
         (prompt-for-string
          prompt
          :initial-value (or initial-value "")
          :history-symbol '*legit-remote-url-history*)))
    (when (str:blankp url)
      (editor-error "A remote URL is required."))
    (legit-remote-value-valid-p url "remote URL")
    url))

(defun legit-remote-config-values (remote suffix)
  (legit-remote-optional-lines
   (list "config" "--get-all" (format nil "remote.~a.~a" remote suffix))))

(defun legit-remote-config-value (remote suffix)
  (first (legit-remote-config-values remote suffix)))

(defun legit-remote-set-values (remote suffix values)
  "Replace all REMOTE SUFFIX values with VALUES."
  (let ((key (format nil "remote.~a.~a" remote suffix)))
    (when (legit-remote-config-values remote suffix)
      (legit-remote-checked-output (list "config" "--unset-all" key)))
    (dolist (value values)
      (legit-remote-checked-output (list "config" "--add" key value)))))

(defun legit-remote-read-single-config (remote suffix label)
  "Read one value for REMOTE SUFFIX; a blank value unsets every old value."
  (let ((value
          (prompt-for-string
           (format nil "~a for ~a (blank unsets): " label remote)
           :initial-value (or (legit-remote-config-value remote suffix) "")
           :history-symbol '*legit-remote-config-history*)))
    (when value
      (legit-remote-value-valid-p value label :allow-leading-option-p t)
      (legit-remote-set-values
       remote suffix (unless (str:blankp value) (list value)))
      (message "Updated ~a for ~a." label remote)
      t)))

(defun legit-remote-read-choice-config (remote suffix label choices)
  (let* ((unset "<unset>")
         (current (legit-remote-config-value remote suffix))
         (all (append choices (list unset)))
         (value
           (prompt-for-string
            (format nil "~a for ~a: " label remote)
            :initial-value (or current unset)
            :history-symbol '*legit-remote-config-history*
            :completion-function
            (lambda (query) (completion-strings query all))
            :test-function
            (lambda (candidate) (member candidate all :test #'string=)))))
    (when value
      (legit-remote-set-values
       remote suffix (unless (string= value unset) (list value)))
      (message "Updated ~a for ~a." label remote)
      t)))

(defun legit-remote-config-action (remote name)
  (cond
    ((string= name "u")
     (legit-remote-read-single-config remote "url" "Fetch URL"))
    ((string= name "U")
     (legit-remote-read-single-config remote "fetch" "Fetch refspec"))
    ((string= name "s")
     (legit-remote-read-single-config remote "pushurl" "Push URL"))
    ((string= name "S")
     (legit-remote-read-single-config remote "push" "Push refspec"))
    ((string= name "O")
     (legit-remote-read-choice-config
      remote "tagOpt" "Tag option" '("--no-tags" "--tags")))
    ((string= name "h")
     (legit-remote-read-choice-config
      remote "followRemoteHEAD" "Follow remote HEAD"
      '("create" "always" "warn")))
    (t (editor-error "No remote configuration action is bound to ~a" name))))

(defun legit-remote-clean-push-variables (old &optional new)
  "Migrate or clear repository push variables that name OLD."
  (when (string= (or (legit-fetch-config-value "remote.pushDefault") "") old)
    (if new
        (legit-remote-checked-output
         (list "config" "remote.pushDefault" new))
        (legit-remote-checked-output
         '("config" "--unset-all" "remote.pushDefault"))))
  (dolist
      (key
        (legit-remote-optional-lines
         '("config" "--name-only" "--get-regexp"
           "^branch\\..*\\.pushRemote$")))
    (when (string= (or (legit-fetch-config-value key) "") old)
      (if new
          (legit-remote-checked-output (list "config" key new))
          (legit-remote-checked-output
           (list "config" "--unset-all" key))))))

(defun legit-remote-add (options)
  (alexandria:when-let
      ((remote (legit-remote-read-new-name "Remote name: ")))
    (alexandria:when-let
        ((url (legit-remote-read-url "Remote URL: ")))
      (let ((arguments
              (append (list "remote" "add")
                      (when (legit-remote-options-fetch-p options) '("-f"))
                      (list remote url))))
        (when (legit-remote-run arguments (format nil "Added remote ~a." remote))
          (unless (legit-fetch-config-value "remote.pushDefault")
            (when (prompt-for-y-or-n-p
                   (format nil "Set remote.pushDefault to ~a? " remote))
              (legit-remote-checked-output
               (list "config" "remote.pushDefault" remote))
              (legit-remote-refresh)))
          t)))))

(defun legit-remote-rename ()
  (alexandria:when-let
      ((old (legit-remote-read-existing "Rename remote: ")))
    (alexandria:when-let
        ((new (legit-remote-read-new-name
               (format nil "Rename ~a to: " old))))
      (unless (string= old new)
        (when (legit-remote-run
               (list "remote" "rename" old new)
               (format nil "Renamed remote ~a to ~a." old new))
          (legit-remote-clean-push-variables old new)
          (legit-remote-refresh)
          t)))))

(defun legit-remote-remove ()
  (alexandria:when-let
      ((remote (legit-remote-read-existing "Remove remote: ")))
    (when (prompt-for-y-or-n-p (format nil "Remove remote ~a? " remote))
      (when (legit-remote-run
             (list "remote" "remove" remote)
             (format nil "Removed remote ~a." remote))
        (legit-remote-clean-push-variables remote)
        (legit-remote-refresh)
        t))))

(defun legit-remote-prune ()
  (alexandria:when-let
      ((remote (legit-remote-read-existing "Prune stale branches of remote: ")))
    (when (prompt-for-y-or-n-p
           (format nil "Prune stale branches of ~a? " remote))
      (legit-remote-run
       (list "remote" "prune" remote)
       (format nil "Pruned stale branches of ~a." remote)))))

(defun legit-remote-refspec-parts (refspec)
  (let* ((plain (if (and (plusp (length refspec))
                         (char= (char refspec 0) #\+))
                    (subseq refspec 1)
                    refspec))
         (colon (position #\: plain)))
    (when (and colon (plusp colon) (< colon (1- (length plain))))
      (values (subseq plain 0 colon) (subseq plain (1+ colon))))))

(defun legit-remote-wildcard-match (pattern value)
  "Return the text matched by PATTERN's sole *, or T for an exact match."
  (let ((star (position #\* pattern)))
    (if star
        (let ((prefix (subseq pattern 0 star))
              (suffix (subseq pattern (1+ star))))
          (and (alexandria:starts-with-subseq prefix value)
               (alexandria:ends-with-subseq suffix value)
               (>= (length value) (+ (length prefix) (length suffix)))
               (subseq value (length prefix)
                       (- (length value) (length suffix)))))
        (and (string= pattern value) t))))

(defun legit-remote-remote-refs (remote)
  (mapcar
   (lambda (line)
     (let ((tab (position #\Tab line)))
       (if tab (subseq line (1+ tab)) line)))
   (legit-remote-lines (list "ls-remote" "--heads" remote))))

(defun legit-remote-stale-refspecs (remote)
  "Return stale fetch refspecs paired with their local destination refs."
  (let ((remote-refs (legit-remote-remote-refs remote))
        (local-refs
          (legit-remote-lines
           '("for-each-ref" "--format=%(refname)" "refs/remotes")))
        (stale '()))
    (dolist (refspec (legit-remote-config-values remote "fetch"))
      (multiple-value-bind (source destination)
          (legit-remote-refspec-parts refspec)
        (when (and source
                   (not (find-if
                         (lambda (ref)
                           (legit-remote-wildcard-match source ref))
                         remote-refs)))
          (push
           (cons refspec
                 (remove-if-not
                  (lambda (ref)
                    (legit-remote-wildcard-match destination ref))
                  local-refs))
           stale))))
    (nreverse stale)))

(defun legit-remote-prune-refspecs ()
  (alexandria:when-let
      ((remote (legit-remote-read-existing "Prune refspecs of remote: ")))
    (let* ((key (format nil "remote.~a.fetch" remote))
           (all (legit-remote-config-values remote "fetch"))
           (stale (legit-remote-stale-refspecs remote)))
      (cond
        ((null stale)
         (message "No stale refspecs for remote ~a." remote))
        ((= (length stale) (length all))
         (let* ((choices '("default" "remove" "abort"))
                (choice
                  (prompt-for-string
                   (format nil "All refspecs for ~a are stale (default/remove/abort): "
                           remote)
                   :initial-value "abort"
                   :history-symbol '*legit-remote-config-history*
                   :completion-function
                   (lambda (query) (completion-strings query choices))
                   :test-function
                   (lambda (value) (member value choices :test #'string=)))))
           (cond
             ((or (null choice) (string= choice "abort")) nil)
             ((string= choice "remove")
              (legit-remote-run
               (list "remote" "remove" remote)
               (format nil "Removed remote ~a." remote))
              (legit-remote-clean-push-variables remote))
             ((string= choice "default")
              (legit-remote-set-values
               remote "fetch"
               (list (format nil "+refs/heads/*:refs/remotes/~a/*" remote)))
              (message "Restored the default fetch refspec for ~a." remote)))))
        ((prompt-for-y-or-n-p
          (format nil "Prune ~d stale refspec~:p for ~a? "
                  (length stale) remote))
         (dolist (entry stale)
           (legit-remote-checked-output
            (list "config" "--fixed-value" "--unset-all" key (car entry)))
           (dolist (ref (cdr entry))
             (legit-remote-checked-output (list "update-ref" "-d" ref))))
         (legit-remote-refresh)
         (message "Pruned ~d stale refspec~:p for ~a."
                  (length stale) remote)
         t)))))

(defun legit-remote-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-remote-popup-keymap (options current)
  (let ((keymap (make-keymap :description "Remote")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(,(when current
               (list "u" (format nil "fetch URL: ~a"
                                  (or (legit-remote-config-value current "url")
                                      "unset"))))
            ,(when current (list "U" "fetch refspec"))
            ,(when current (list "s" "push URL"))
            ,(when current (list "S" "push refspec"))
            ,(when current
               (list "O" (format nil "tag option: ~a"
                                  (or (legit-remote-config-value current "tagOpt")
                                      "unset"))))
            ,(when current
               (list "h" (format nil "follow remote HEAD: ~a"
                                  (or (legit-remote-config-value
                                       current "followRemoteHEAD")
                                      "create"))))
            ("- f" ,(format nil "[~a] fetch after add"
                              (if (legit-remote-options-fetch-p options)
                                  "x" " ")))
            ("a" "add remote")
            ("r" "rename remote")
            ("k" "remove remote")
            ("C" "configure another remote")
            ("p" "prune stale branches")
            ("P" "prune stale refspecs")
            ("d u" "update default branch")
            ("q" "cancel")))
      (when entry
        (legit-remote-add-popup-entry keymap (first entry) (second entry))))
    keymap))

(defun legit-remote-config-popup-keymap (remote)
  (let ((keymap (make-keymap :description "Configure remote")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist (entry `(("u" ,(format nil "fetch URL for ~a" remote))
                     ("U" ,(format nil "fetch refspec for ~a" remote))
                     ("s" ,(format nil "push URL for ~a" remote))
                     ("S" ,(format nil "push refspec for ~a" remote))
                     ("O" ,(format nil "tag option for ~a" remote))
                     ("h" ,(format nil "follow remote HEAD for ~a" remote))
                     ("q" "return")))
      (legit-remote-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-remote-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (member name '("-" "d") :test #'string=)
        (format nil "~a ~a" name
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun legit-remote-configure (remote)
  (unwind-protect
       (loop
         :for keymap := (legit-remote-config-popup-keymap remote)
         :do
            (let ((lem/transient:*transient-popup-delay* 0))
              (keymap-activate keymap))
            (redraw-display)
            (let ((name (legit-remote-read-popup-key)))
              (lem/transient::hide-transient)
              (when (or (string= name "q") (string= name "Escape"))
                (return nil))
              (legit-remote-config-action remote name)))
    (lem/transient::hide-transient)))

(defun dispatch-legit-remote ()
  "Display and execute the configured Magit-compatible remote dispatch."
  (let ((options (make-legit-remote-options))
        (*legit-remote-dispatch-window* (current-window)))
    (unwind-protect
         (loop
           :for current := (legit-fetch-current-remote)
           :for keymap := (legit-remote-popup-keymap options current)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-remote-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Remote dispatch cancelled.")
                   (return nil))
                  ((string= name "- f")
                   (setf (legit-remote-options-fetch-p options)
                         (not (legit-remote-options-fetch-p options))))
                  ((member name '("u" "U" "s" "S" "O" "h")
                           :test #'string=)
                   (legit-remote-config-action
                    (or current
                        (legit-remote-read-existing "Configure remote: "))
                    name))
                  ((string= name "a") (legit-remote-add options) (return t))
                  ((string= name "r") (legit-remote-rename) (return t))
                  ((string= name "k") (legit-remote-remove) (return t))
                  ((string= name "C")
                   (alexandria:when-let
                       ((remote
                          (legit-remote-read-existing "Configure remote: ")))
                     (legit-remote-configure remote)))
                  ((string= name "p") (legit-remote-prune) (return t))
                  ((string= name "P")
                   (legit-remote-prune-refspecs) (return t))
                  ((string= name "d u")
                   (legit-branch-update-default) (return t))
                  (t
                   (message "No remote action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-remote () ()
  "Open the configured Magit-compatible Git remote transient."
  (lem/legit::with-current-project (vcs)
    (legit-remote-require-git vcs)
    (dispatch-legit-remote)))

(define-key lem/legit::*peek-legit-keymap* "M" 'lem-yath-legit-remote)
(define-key lem/legit::*legit-diff-mode-keymap* "M" 'lem-yath-legit-remote)
