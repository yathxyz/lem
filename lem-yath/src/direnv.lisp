;;;; Per-directory process environments, matching the configured Emacs
;;;; `direnv-mode'.  WORKDIR remains startup-cached in workspace.lisp; this
;;;; module follows the active buffer and updates only future subprocesses.

(in-package :lem-yath)

;; UIOP can set variables on SBCL but does not expose an unset operation.
;; Load the bundled SB-POSIX module here as well as in the packaged wrapper so
;; direct source/test loads have the same environment mutation support.
(require :sb-posix)

(defvar *direnv-timeout-seconds* 300
  "Maximum seconds allowed for one direnv invocation.")

(defvar *direnv-output-limit* (* 4 1024 1024)
  "Maximum stdout or stderr characters accepted from direnv.")

(defvar *direnv-hook-weight* 20000
  "Weight for switch/post-command environment reconciliation hooks.")

(defvar *direnv-always-show-summary* t
  "Whether automatic environment changes display a variable-name summary.")

(defvar *direnv-show-paths-in-summary* t
  "Whether summaries identify the directory transition.")

(defvar *direnv-non-file-major-mode-names*
  '("DIRECTORY-MODE"
    "RUN-SHELL-MODE"
    "TERMINAL-MODE"
    "TERMINAL-COPY-MODE"
    "LISP-REPL-MODE"
    "SCHEME-REPL-MODE"
    "CLOJURE-REPL-MODE"
    "RUN-PYTHON-MODE"
    "LEGIT-DIFF-MODE"
    "LEGIT-COMMIT-MODE"
    "LEGIT-REBASE-MODE")
  "Non-file major modes whose buffer directory selects the environment.")

(defvar *direnv-non-file-minor-mode-names*
  '("LISTENER-MODE"
    "PEEK-GREP-MODE"
    "PEEK-LEGIT-MODE"
    "LEGIT-COMMITS-LOG-MODE"
    "LEM-YATH-JJ-VIEW-MODE")
  "Non-file minor modes equivalent to Emacs's process and Magit buffers.")

(defvar *direnv-program* :unknown)
(defvar *direnv-timeout-program* :unknown)
(defvar *direnv-active-directory* nil
  "Directory for which an automatic or manual export was last attempted.")
(defvar *direnv-last-error* nil
  "Last safe diagnostic string, never containing environment values.")
(defvar *direnv-last-exit-status* nil)
(defvar *direnv-last-summary* "")
(defvar *direnv-updating-p* nil)

(defun direnv-resolve-program (name cache-symbol)
  "Resolve NAME and retain its absolute pathname in CACHE-SYMBOL."
  (let ((cached (symbol-value cache-symbol)))
    (cond
      ((or (eq cached :unknown)
           (null cached)
           (not (uiop:file-exists-p cached)))
       (setf (symbol-value cache-symbol) (executable-find name)))
      (t cached))))

(defun direnv-timeout-command (arguments)
  "Wrap argv list ARGUMENTS in a bounded GNU timeout invocation."
  (let ((timeout (direnv-resolve-program "timeout"
                                         '*direnv-timeout-program*)))
    (unless timeout
      (error "GNU timeout is unavailable; refusing an unbounded direnv command"))
    (append (list (namestring timeout)
                  "--signal=TERM"
                  "--kill-after=5s"
                  (format nil "~ds" *direnv-timeout-seconds*))
            arguments)))

(defun direnv-command (arguments)
  "Return a bounded absolute-path direnv command for ARGUMENTS."
  (let ((direnv (direnv-resolve-program "direnv" '*direnv-program*)))
    (unless direnv
      (error "the direnv executable is not on PATH"))
    (direnv-timeout-command
     (cons (namestring direnv) arguments))))

(defun direnv-read-bounded-stream (stream process label)
  "Read STREAM up to the configured limit, terminating PROCESS on overflow."
  (let ((chunk (make-string 8192))
        (count 0)
        (output (make-string-output-stream)))
    (loop :for length := (read-sequence chunk stream)
          :until (zerop length)
          :do (incf count length)
              (when (> count *direnv-output-limit*)
                (ignore-errors (uiop:terminate-process process))
                (error "direnv ~a exceeded ~d characters"
                       label *direnv-output-limit*))
              (write-sequence chunk output :end length))
    (get-output-stream-string output)))

(defun direnv-run (arguments directory)
  "Run direnv ARGUMENTS in DIRECTORY with bounded stdout, stderr, and time."
  (let ((process nil)
        (finished-p nil)
        (error-thread nil))
    (unwind-protect
         (progn
           (setf process
                 (uiop:launch-program
                  (direnv-command arguments)
                  :directory directory
                  :output :stream
                  :error-output :stream))
           (let ((error-output "")
                 (error-failure nil))
             ;; Drain stderr concurrently so neither child pipe can block the
             ;; other before the configured bound is enforced.
             (setf error-thread
                   (bt2:make-thread
                    (lambda ()
                      (handler-case
                          (setf error-output
                                (with-open-stream
                                    (stream
                                      (uiop:process-info-error-output process))
                                  (direnv-read-bounded-stream
                                   stream process "stderr")))
                        (error (condition)
                          (setf error-failure condition))))
                    :name "lem-yath/direnv-stderr"))
             (let ((output
                     (with-open-stream
                         (stream (uiop:process-info-output process))
                       (direnv-read-bounded-stream stream process "stdout")))
                   (status (uiop:wait-process process)))
               (bt2:join-thread error-thread)
               (setf error-thread nil
                     finished-p t)
               (when error-failure
                 (error error-failure))
               (values output error-output status))))
      (when (and process (not finished-p))
        (ignore-errors (uiop:terminate-process process))
        (ignore-errors (uiop:wait-process process)))
      (when error-thread
        (ignore-errors (bt2:join-thread error-thread))))))

(defun direnv-json-start (output)
  "Return the last JSON-object start at the beginning of a line in OUTPUT."
  (loop :for index :downfrom (1- (length output)) :to 0
        :when (and (char= #\{ (char output index))
                   (or (zerop index)
                       (member (char output (1- index))
                               '(#\Newline #\Return))))
          :return index))

(defun direnv-valid-variable-name-p (name)
  (and (stringp name)
       (plusp (length name))
       (not (find #\= name))
       (not (find (code-char 0) name))))

(defun direnv-valid-variable-value-p (value)
  (or (eq value :null)
      (and (stringp value)
           (not (find (code-char 0) value)))))

(defun direnv-parse-export (output)
  "Parse and validate a complete `direnv export json' result.
Return a sorted alist whose NIL values mean that a variable must be unset."
  (when (every (lambda (character)
                 (member character '(#\Space #\Tab #\Newline #\Return)))
               output)
    (return-from direnv-parse-export '()))
  (let ((start (direnv-json-start output)))
    (unless start
      (error "direnv did not return a JSON object"))
    (with-open-stream (stream
                        (make-string-input-stream (subseq output start)))
      (let ((object
              (yason:parse stream
                           :object-as :hash-table
                           :json-booleans-as-symbols t
                           :json-nulls-as-keyword t)))
        (loop :for character := (read-char stream nil nil)
              :while character
              :unless (member character '(#\Space #\Tab #\Newline #\Return))
                :do (error "direnv returned trailing non-JSON output"))
        (unless (hash-table-p object)
          (error "direnv JSON root is not an object"))
        (let ((changes nil))
          (maphash
           (lambda (name value)
             (unless (direnv-valid-variable-name-p name)
               (error "direnv returned an invalid environment variable name"))
             (unless (direnv-valid-variable-value-p value)
               (error "direnv returned a non-string value for ~a" name))
             ;; Yason strings may be adjustable; SBCL's POSIX environment API
             ;; requires SIMPLE-STRING arguments.
             (push (cons (coerce name 'simple-string)
                         (unless (eq value :null)
                           (coerce value 'simple-string)))
                   changes))
           object)
          (sort changes #'string-lessp :key #'car))))))

(defun direnv-merge-runtime-path (path)
  "Append configured Lem runtime bins to PATH without shadowing the project."
  (let ((runtime (uiop:getenv "LEM_YATH_RUNTIME_PATH"))
        (seen '()))
    (when (or path runtime)
      (format nil "~{~a~^:~}"
              (loop :for directory
                      :in (append
                           (uiop:split-string (or path "") :separator ":")
                           (uiop:split-string (or runtime "") :separator ":"))
                    :when (and (plusp (length directory))
                               (not (member directory seen :test #'string=)))
                      :collect directory
                      :and :do (push directory seen))))))

(defun direnv-set-environment-value (name value)
  (let ((effective-value
          (if (string= name "PATH")
              (direnv-merge-runtime-path value)
              value)))
    (if effective-value
        (setf (uiop:getenv name) effective-value)
        (uiop:symbol-call :sb-posix :unsetenv name))
    effective-value))

(defun direnv-apply-changes (changes)
  "Apply prevalidated CHANGES and return their inverse.
If one mutation fails, restore every prior value before re-signalling."
  (let ((previous
          (mapcar (lambda (change)
                    (cons (car change) (uiop:getenv (car change))))
                  changes)))
    (handler-case
        (progn
          (dolist (change changes)
            (direnv-set-environment-value (car change) (cdr change)))
          previous)
      (error (condition)
        (let ((rollback-failed-p nil))
          (dolist (entry previous)
            (handler-case
                (direnv-set-environment-value (car entry) (cdr entry))
              (error () (setf rollback-failed-p t))))
          (if rollback-failed-p
              (error "direnv environment mutation and rollback both failed")
              (error condition)))))))

(defun direnv-internal-variable-p (name)
  (eql 0 (search "DIRENV_" name :test #'char=)))

(defun direnv-summary-state-rank (state)
  (ecase state
    (:added 0)
    (:changed 1)
    (:removed 2)))

(defun direnv-change-states (changes)
  "Classify CHANGES against the environment without retaining any values."
  (let ((states
          (loop :for (name . value) :in changes
                :unless (direnv-internal-variable-p name)
                  :collect (cons name
                                 (cond
                                   ((null value) :removed)
                                   ((uiop:getenv name) :changed)
                                   (t :added))))))
    (sort states
          (lambda (left right)
            (let ((left-rank (direnv-summary-state-rank (cdr left)))
                  (right-rank (direnv-summary-state-rank (cdr right))))
              (or (< left-rank right-rank)
                  (and (= left-rank right-rank)
                       (string-lessp (car left) (car right)))))))))

(defun direnv-summary (changes)
  "Summarize CHANGES using variable names only."
  (format nil "~{~a~^ ~}"
          (mapcar
           (lambda (entry)
             (format nil "~a~a"
                     (ecase (cdr entry)
                       (:added "+")
                       (:changed "~")
                       (:removed "-"))
                     (car entry)))
           (direnv-change-states changes))))

(defun direnv-trim-directory (directory)
  (let ((trimmed (string-right-trim '(#\/) directory)))
    (if (zerop (length trimmed)) "/" trimmed)))

(defun direnv-display-directory (directory)
  "Abbreviate DIRECTORY beneath the current home directory."
  (let* ((directory (direnv-trim-directory directory))
         (home (direnv-trim-directory (namestring (user-homedir-pathname)))))
    (cond
      ((string= directory home) "~")
      ((and (> (length directory) (length home))
            (string= home directory :end2 (length home))
            (char= #\/ (char directory (length home))))
       (concatenate 'string "~" (subseq directory (length home))))
      (t directory))))

(defun direnv-summary-paths (old-directory new-directory)
  (if (or (null old-directory) (string= old-directory new-directory))
      (direnv-display-directory new-directory)
      (format nil "~a → ~a"
              (direnv-display-directory old-directory)
              (direnv-display-directory new-directory))))

(defun direnv-show-summary (summary old-directory new-directory)
  (let ((summary (if (plusp (length summary)) summary "no changes")))
    (if *direnv-show-paths-in-summary*
        (message "direnv: ~a (~a)"
                 summary
                 (direnv-summary-paths old-directory new-directory))
        (message "direnv: ~a" summary))))

(defun direnv-mode-derived-from-names-p (mode names)
  "Whether MODE's CLOS ancestry contains one of the symbol NAMES."
  (alexandria:when-let ((object (ignore-errors (ensure-mode-object mode))))
    (some (lambda (class)
            (let ((name (class-name class)))
              (and (symbolp name)
                   (member (symbol-name name) names :test #'string=))))
          (c2mop:class-precedence-list (class-of object)))))

(defun direnv-mode-name-active-p (buffer names)
  (some (lambda (mode)
          (direnv-mode-derived-from-names-p mode names))
        (cons (buffer-major-mode buffer) (buffer-minor-modes buffer))))

(defun direnv-non-file-buffer-p (buffer)
  (or (buffer-value buffer 'lem-yath-direnv-process-buffer)
      (direnv-mode-name-active-p buffer
                                 *direnv-non-file-major-mode-names*)
      (direnv-mode-name-active-p buffer
                                 *direnv-non-file-minor-mode-names*)))

(defun direnv-normalize-local-directory (directory)
  (when directory
    (let* ((expanded (expand-file-name directory))
           (existing (ignore-errors (uiop:directory-exists-p expanded))))
      (when existing
        (namestring (uiop:ensure-directory-pathname expanded))))))

(defun direnv-relevant-directory (&optional (buffer (current-buffer)))
  "Return BUFFER's local file or eligible non-file directory, or NIL."
  (when (and (typep buffer 'lem:buffer)
             (not (deleted-buffer-p buffer)))
    (direnv-normalize-local-directory
     (cond
       ((buffer-filename buffer)
        (directory-namestring (buffer-filename buffer)))
       ((direnv-non-file-buffer-p buffer)
        (buffer-directory buffer))))))

(defun direnv-export (directory)
  "Return changes, parse-success-p, status, and a safe diagnostic."
  (handler-case
      (multiple-value-bind (output error-output status)
          (direnv-run '("export" "json") directory)
        (declare (ignore error-output))
        (cond
          ((member status '(124 137))
           (values nil nil status
                   (format nil "export timed out after ~d seconds"
                           *direnv-timeout-seconds*)))
          ((not (integerp status))
           (values nil nil status "export returned no numeric exit status"))
          (t
           (handler-case
               (values (direnv-parse-export output)
                       t
                       status
                       (unless (zerop status)
                         (format nil "export exited with status ~d" status)))
             (error (condition)
               (declare (ignore condition))
               (values nil nil status
                       "direnv returned malformed or invalid JSON"))))))
    (error (condition)
      (values nil nil nil (princ-to-string condition)))))

(defun direnv-report-error (diagnostic)
  (setf *direnv-last-error* diagnostic)
  (ignore-errors (message "direnv: ~a" diagnostic)))

(defun direnv-update-directory-environment
    (&optional directory force-summary)
  "Update the process environment for DIRECTORY.
FORCE-SUMMARY also reports an empty change set, as the Emacs command does."
  (let ((directory
          (direnv-normalize-local-directory
           (or directory (buffer-directory (current-buffer))))))
    (unless directory
      (direnv-report-error "current buffer has no existing local directory")
      (return-from direnv-update-directory-environment nil))
    (when *direnv-updating-p*
      (return-from direnv-update-directory-environment nil))
    (let ((old-directory *direnv-active-directory*)
          (*direnv-updating-p* t))
      ;; emacs-direnv records the attempted directory before invoking direnv,
      ;; so a failed automatic update is not retried after every command.
      (setf *direnv-active-directory* directory)
      (multiple-value-bind (changes parsed-p status diagnostic)
          (direnv-export directory)
        (setf *direnv-last-exit-status* status)
        (unless parsed-p
          (direnv-report-error diagnostic)
          (return-from direnv-update-directory-environment nil))
        (handler-case
            (let ((summary (direnv-summary changes)))
              (let ((inverse (direnv-apply-changes changes)))
                (setf *direnv-last-summary* summary
                      *direnv-last-error* diagnostic)
                (when (or force-summary
                          (and *direnv-always-show-summary*
                               (plusp (length summary))))
                  (direnv-show-summary summary old-directory directory))
                ;; A nonzero status may still carry a valid unload diff.  Apply
                ;; it first (as emacs-direnv does), then surface the failure.
                (when diagnostic
                  (direnv-report-error diagnostic))
                (values t inverse)))
          (error (condition)
            (declare (ignore condition))
            (direnv-report-error "could not apply environment changes")
            nil))))))

(defun direnv-maybe-update-buffer (&optional (buffer (current-buffer)))
  "Refresh Direnv when BUFFER selects a different eligible directory."
  (let ((directory (direnv-relevant-directory buffer)))
    (when (and directory
               (not *direnv-updating-p*)
               (not (string= directory
                             (or *direnv-active-directory* ""))))
      (direnv-update-directory-environment directory))))

(defstruct direnv-process-state
  active-directory
  last-error
  last-exit-status
  last-summary)

(defun direnv-capture-process-state ()
  (make-direnv-process-state
   :active-directory *direnv-active-directory*
   :last-error *direnv-last-error*
   :last-exit-status *direnv-last-exit-status*
   :last-summary *direnv-last-summary*))

(defun direnv-restore-process-state (state inverse)
  "Restore INVERSE environment changes and Direnv metadata from STATE."
  (when inverse
    (direnv-apply-changes inverse))
  (setf *direnv-active-directory*
        (direnv-process-state-active-directory state)
        *direnv-last-error*
        (direnv-process-state-last-error state)
        *direnv-last-exit-status*
        (direnv-process-state-last-exit-status state)
        *direnv-last-summary*
        (direnv-process-state-last-summary state)))

(defun direnv-mode-enabled-p ()
  (ignore-errors (mode-active-p (current-buffer) 'direnv-mode)))

(defun call-with-provisional-direnv (pathname function)
  "Call FUNCTION with PATHNAME's environment, then restore the visible one.
This scope exists so first mode hooks and a synchronously launched LSP server
see the file's environment before the caller selects its new buffer."
  (let ((directory
          (ignore-errors
            (direnv-normalize-local-directory
             (directory-namestring (expand-file-name pathname))))))
    (if (or (not (direnv-mode-enabled-p))
            (null directory)
            (string= directory (or *direnv-active-directory* "")))
        (funcall function)
        (let ((state (direnv-capture-process-state))
              (inverse nil))
          (unwind-protect
               (progn
                 (multiple-value-bind (updated-p previous)
                     (let ((*direnv-always-show-summary* nil))
                       (direnv-update-directory-environment directory))
                   (when updated-p
                     (setf inverse previous)))
                 (funcall function))
            (handler-case
                (direnv-restore-process-state state inverse)
              (error (condition)
                (declare (ignore condition))
                (direnv-report-error
                 "could not restore the environment after opening a file"))))))))

(defmethod execute-find-file :around
    ((executor find-file-executor) mode pathname)
  (declare (ignore executor mode))
  (call-with-provisional-direnv pathname (lambda () (call-next-method))))

(defun direnv-remove-hooks ()
  "Remove all automatic environment hooks."
  (remove-hook *switch-to-buffer-hook* 'direnv-maybe-update-buffer)
  (remove-hook *post-command-hook* 'direnv-maybe-update-buffer))

(defun direnv-install-hooks ()
  "Install reload-idempotent automatic environment hooks."
  (direnv-remove-hooks)
  (add-hook *switch-to-buffer-hook* 'direnv-maybe-update-buffer
            *direnv-hook-weight*)
  (add-hook *post-command-hook* 'direnv-maybe-update-buffer
            *direnv-hook-weight*)
  (ignore-errors (direnv-maybe-update-buffer (current-buffer))))

(define-minor-mode direnv-mode
    (:name "Direnv"
     :global t
     :enable-hook 'direnv-install-hooks
     :disable-hook 'direnv-remove-hooks
     :hide-from-modeline t)
  "Continuously match Lem's process environment to the active local buffer.")

(define-command direnv-update-environment () ()
  "Manually refresh the current buffer's Direnv environment."
  (let ((directory
          (or (direnv-relevant-directory (current-buffer))
              (direnv-normalize-local-directory
               (buffer-directory (current-buffer))))))
    (direnv-update-directory-environment directory t)))

(define-command direnv-allow () ()
  "Explicitly authorize the current .envrc, then refresh its environment."
  (let ((directory
          (or (direnv-relevant-directory (current-buffer))
              (direnv-normalize-local-directory
               (buffer-directory (current-buffer))))))
    (unless directory
      (direnv-report-error "current buffer has no existing local directory")
      (return-from direnv-allow))
    (handler-case
        (multiple-value-bind (output error-output status)
            (direnv-run '("allow") directory)
          (declare (ignore output error-output))
          (if (and (integerp status) (zerop status))
              (direnv-update-directory-environment directory t)
              (direnv-report-error
               (if (member status '(124 137))
                   (format nil "allow timed out after ~d seconds"
                           *direnv-timeout-seconds*)
                   (format nil "allow exited with status ~a" status)))))
      (error (condition)
        (declare (ignore condition))
        (direnv-report-error "allow could not run")))))

;; emacs-direnv treats .envrc as shell source.  Lem's POSIX shell mode is
;; already part of the ncurses image, so the ordinary extension association is
;; enough without introducing a dedicated mode.
(define-file-type ("envrc") lem-posix-shell-mode:posix-shell-mode)

(direnv-mode t)
