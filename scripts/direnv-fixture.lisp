(in-package :lem-yath)

;; Loaded from the test's real LEM_HOME init before Lem opens its command-line
;; Python file.  The Python mode hook below therefore observes whether the
;; production file-open scope installed the direnv environment early enough
;; for mode hooks, language servers, and their child processes.

(defvar *direnv-test-report*
  (or (uiop:getenv "LEM_YATH_DIRENV_REPORT")
      (error "LEM_YATH_DIRENV_REPORT is not set")))

(defvar *direnv-test-mode-hook-count* 0)

(defun direnv-test-log (control &rest arguments)
  (with-open-file (stream *direnv-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun direnv-test-env (name)
  (or (uiop:getenv name) "unset"))

(defun direnv-test-path (name)
  (or (uiop:getenv name)
      (error "Missing direnv fixture path ~a" name)))

(defun direnv-test-directory-path (name)
  (uiop:ensure-directory-pathname (direnv-test-path name)))

(defun direnv-test-same-directory-p (left right)
  (and left
       right
       (handler-case
           (uiop:pathname-equal
            (uiop:ensure-directory-pathname left)
            (uiop:ensure-directory-pathname right))
         (error () nil))))

(defun direnv-test-directory-id (directory)
  (or (loop :for (name . label)
              :in '(("LEM_YATH_DIRENV_A_DIR" . "A")
                    ("LEM_YATH_DIRENV_NESTED_DIR" . "NESTED")
                    ("LEM_YATH_DIRENV_B_DIR" . "B")
                    ("LEM_YATH_DIRENV_BACKGROUND_DIR" . "BACKGROUND")
                    ("LEM_YATH_DIRENV_THROW_DIR" . "THROW")
                    ("LEM_YATH_DIRENV_OUTSIDE_DIR" . "OUTSIDE")
                    ("LEM_YATH_DIRENV_BLOCKED_DIR" . "BLOCKED")
                    ("LEM_YATH_DIRENV_TIMEOUT_DIR" . "TIMEOUT")
                    ("LEM_YATH_DIRENV_MALFORMED_DIR" . "MALFORMED"))
            :for expected := (uiop:getenv name)
            :when (and expected
                       (direnv-test-same-directory-p directory expected))
              :return label)
      (if directory "OTHER" "none")))

(defun direnv-test-run-program (program)
  (handler-case
      (multiple-value-bind (output error-output status)
          (uiop:run-program (list program)
                            :output :string
                            :error-output :string
                            :ignore-error-status t)
        (declare (ignore error-output))
        (if (and (integerp status) (zerop status))
            (string-trim '(#\Space #\Tab #\Newline #\Return) output)
            (format nil "status-~a" status)))
    (error () "error")))

(defun direnv-test-project-tool ()
  (alexandria:if-let ((program (executable-find "direnv-project-tool")))
    (direnv-test-run-program (namestring program))
    "none"))

(defun direnv-test-child-environment ()
  (direnv-test-run-program (direnv-test-path "LEM_YATH_DIRENV_CHILD")))

(defun direnv-test-mode-name (&optional (buffer (current-buffer)))
  (string-upcase (symbol-name (buffer-major-mode buffer))))

(defun direnv-test-error-id ()
  (let ((diagnostic
          (and (boundp '*direnv-last-error*) *direnv-last-error*)))
    (cond
      ((null diagnostic) "none")
      ((search "malformed" diagnostic :test #'char-equal) "malformed")
      ((search "apply" diagnostic :test #'char-equal) "apply")
      ((search "status" diagnostic :test #'char-equal) "status")
      ((or (search "timeout" diagnostic :test #'char-equal)
           (search "timed out" diagnostic :test #'char-equal))
       "timeout")
      (t "other"))))

(defun direnv-test-record-state (label &optional (buffer (current-buffer)))
  (let* ((relevant
           (handler-case
               (direnv-relevant-directory buffer)
             (error () nil)))
         (active (and (boundp '*direnv-active-directory*)
                      *direnv-active-directory*)))
    (direnv-test-log
     (concatenate
      'string
      "STATE label=~a file=~a mode=~a listener=~a process=~a relevant=~a active=~a "
      "case=~a base=~a drop=~a nested=~a blocked=~a tool=~a child=~a "
      "status=~a error=~a")
     label
     (if (buffer-filename buffer) "yes" "no")
     (direnv-test-mode-name buffer)
     (if (mode-active-p buffer 'lem/listener-mode:listener-mode) "yes" "no")
     (if (buffer-value buffer 'lem-yath-direnv-process-buffer) "yes" "no")
     (direnv-test-directory-id relevant)
     (direnv-test-directory-id active)
     (direnv-test-env "LEM_YATH_DIRENV_CASE")
     (direnv-test-env "LEM_YATH_DIRENV_BASE")
     (direnv-test-env "LEM_YATH_DIRENV_DROP")
     (direnv-test-env "LEM_YATH_DIRENV_NESTED")
     (direnv-test-env "LEM_YATH_DIRENV_BLOCKED")
     (direnv-test-project-tool)
     (direnv-test-child-environment)
     (if (boundp '*direnv-last-exit-status*)
         *direnv-last-exit-status*
         "unbound")
     (direnv-test-error-id))))

(defun direnv-test-hook-function (entry)
  (if (consp entry) (car entry) entry))

(defun direnv-test-hook-count (hook function)
  (count function
         (symbol-value hook)
         :key #'direnv-test-hook-function
         :test #'eq))

(defun direnv-test-record-hooks (label)
  (direnv-test-log
   "HOOKS label=~a find=~d switch=~d post=~d"
   label
   (direnv-test-hook-count '*find-file-hook* 'direnv-maybe-update-buffer)
   (direnv-test-hook-count '*switch-to-buffer-hook* 'direnv-maybe-update-buffer)
   (direnv-test-hook-count '*post-command-hook* 'direnv-maybe-update-buffer)))

(defun direnv-test-record-preferences (label)
  (direnv-test-log
   "PREFERENCES label=~a timeout=~d summary=~a paths=~a"
   label
   *direnv-timeout-seconds*
   (if *direnv-always-show-summary* "yes" "no")
   (if *direnv-show-paths-in-summary* "yes" "no")))

(defun direnv-test-python-mode-probe ()
  (incf *direnv-test-mode-hook-count*)
  (direnv-test-log "MODE-HOOK count=~d" *direnv-test-mode-hook-count*)
  (direnv-test-record-state "mode-initial"))

;; Avoid launching Pyright in this isolated environment.  The probe occupies
;; the same mode-hook phase and additionally launches a real child process.
(ignore-errors
  (remove-hook lem-python-mode:*python-mode-hook*
               'lem-lsp-mode::enable-lsp-mode))
(remove-hook lem-python-mode:*python-mode-hook* 'direnv-test-python-mode-probe)
(add-hook lem-python-mode:*python-mode-hook* 'direnv-test-python-mode-probe)

(define-major-mode lem-yath-direnv-throw-mode ()
    (:name "Direnv Throw Fixture"
     :mode-hook *lem-yath-direnv-throw-mode-hook*))

(define-file-type ("direnvthrow") lem-yath-direnv-throw-mode)

(defun direnv-test-throw-mode-hook ()
  (direnv-test-log
   "THROW-HOOK case=~a base=~a tool=~a child=~a"
   (direnv-test-env "LEM_YATH_DIRENV_CASE")
   (direnv-test-env "LEM_YATH_DIRENV_BASE")
   (direnv-test-project-tool)
   (direnv-test-child-environment))
  (error "intentional direnv fixture mode-hook failure"))

(remove-hook *lem-yath-direnv-throw-mode-hook* 'direnv-test-throw-mode-hook)
(add-hook *lem-yath-direnv-throw-mode-hook* 'direnv-test-throw-mode-hook)

(defun direnv-test-open-file (variable label)
  (multiple-value-bind (buffer new-file-p)
      (find-file-buffer (direnv-test-path variable))
    (declare (ignore new-file-p))
    (switch-to-buffer buffer)
    (direnv-test-record-state label buffer)))

(define-command lem-yath-test-direnv-static () ()
  "Record the production API, hook multiplicity, and current environment."
  (direnv-test-log
   (concatenate
    'string
    "STATIC update-command=~a allow-command=~a relevant=~a maybe=~a "
    "update-directory=~a active-var=~a program=~a timeout=~a empty-export=~a mode-hooks=~d")
   (if (fboundp 'direnv-update-environment) "yes" "no")
   (if (fboundp 'direnv-allow) "yes" "no")
   (if (fboundp 'direnv-relevant-directory) "yes" "no")
   (if (fboundp 'direnv-maybe-update-buffer) "yes" "no")
   (if (fboundp 'direnv-update-directory-environment) "yes" "no")
   (if (boundp '*direnv-active-directory*) "yes" "no")
   (if (and (boundp '*direnv-program*) *direnv-program*) "yes" "no")
   (if (and (boundp '*direnv-timeout-program*) *direnv-timeout-program*)
       "yes"
       "no")
   (if (null (direnv-parse-export (format nil " ~%~c" #\Tab)))
       "yes"
       "no")
   *direnv-test-mode-hook-count*)
  (direnv-test-record-hooks "initial")
  (direnv-test-record-state "static-current"))

(define-command lem-yath-test-direnv-open-a-sibling () ()
  "Open a second file in the already active directory."
  (direnv-test-open-file "LEM_YATH_DIRENV_A_SIBLING" "a-sibling"))

(define-command lem-yath-test-direnv-open-nested () ()
  "Open the file controlled by the nested envrc."
  (direnv-test-open-file "LEM_YATH_DIRENV_NESTED_FILE" "nested"))

(define-command lem-yath-test-direnv-switch-project-b () ()
  "Open the file controlled by project B's envrc."
  (direnv-test-open-file "LEM_YATH_DIRENV_B_FILE" "b"))

(define-command lem-yath-test-direnv-background-find () ()
  "Create an unselected file buffer without changing the visible environment."
  (let* ((filename (direnv-test-path "LEM_YATH_DIRENV_BACKGROUND_FILE"))
         (origin (current-buffer))
         (buffer (find-file-buffer filename)))
    (direnv-test-log
     "BACKGROUND created=~a selected=~a file=~a"
     (if buffer "yes" "no")
     (if (eq buffer (current-buffer)) "yes" "no")
     (if (and buffer (buffer-filename buffer)) "yes" "no"))
    (direnv-test-record-state "background-retained" origin)
    (when (and buffer (not (eq buffer origin)))
      (delete-buffer buffer))))

(define-command lem-yath-test-direnv-throwing-open () ()
  "Exercise execute-find-file restoration when a target mode hook throws."
  (let ((filename (direnv-test-path "LEM_YATH_DIRENV_THROW_FILE"))
        (threw nil))
    (handler-case
        (execute-find-file lem-core/commands/file::*find-file-executor*
                           (lem-core/commands/file::get-file-mode filename)
                           filename)
      (error () (setf threw t)))
    (direnv-test-log "THROW caught=~a" (if threw "yes" "no"))
    (direnv-test-record-state "throw-restored")
    (dolist (buffer (buffer-list))
      (when (and (buffer-filename buffer)
                 (string= (buffer-filename buffer) filename)
                 (not (eq buffer (current-buffer))))
        (delete-buffer buffer)))))

(define-command lem-yath-test-direnv-open-outside () ()
  "Open a file outside every envrc."
  (direnv-test-open-file "LEM_YATH_DIRENV_OUTSIDE_FILE" "outside"))

(define-command lem-yath-test-direnv-open-blocked () ()
  "Open a file whose envrc has not been authorized."
  (direnv-test-open-file "LEM_YATH_DIRENV_BLOCKED_FILE" "blocked"))

(define-command lem-yath-test-direnv-open-malformed () ()
  "Open a file while the test wrapper emits malformed JSON."
  (direnv-test-open-file "LEM_YATH_DIRENV_MALFORMED_FILE" "malformed-failed"))

(define-command lem-yath-test-direnv-open-timeout () ()
  "Open a file while the test wrapper exceeds the hard timeout."
  (direnv-test-open-file "LEM_YATH_DIRENV_TIMEOUT_FILE" "timeout-failed"))

(define-command lem-yath-test-direnv-open-directory () ()
  "Open a real non-file directory-mode buffer rooted in project A."
  (let ((buffer
          (lem/directory-mode/internal:directory-buffer
           (direnv-test-directory-path "LEM_YATH_DIRENV_A_DIR"))))
    (switch-to-buffer buffer)
    (direnv-test-record-state "directory-a" buffer)))

(defun direnv-test-call-in-buffer (buffer function)
  (let ((old-buffer (current-buffer)))
    (unwind-protect
         (progn
           (setf (current-buffer) buffer)
           (funcall function))
      (setf (current-buffer) old-buffer))))

(define-command lem-yath-test-direnv-open-listener () ()
  "Open a non-file listener-mode buffer rooted in project B."
  (let ((buffer (make-buffer "*Direnv Listener*")))
    (setf (buffer-directory buffer)
          (direnv-test-directory-path "LEM_YATH_DIRENV_B_DIR"))
    (direnv-test-call-in-buffer
     buffer
     (lambda () (lem/listener-mode:listener-mode t)))
    (switch-to-buffer buffer)
    (direnv-test-record-state "listener-b" buffer)))

(define-command lem-yath-test-direnv-retarget-listener () ()
  "Change the current listener directory for the production post hook."
  (setf (buffer-directory (current-buffer))
        (direnv-test-directory-path "LEM_YATH_DIRENV_NESTED_DIR"))
  (direnv-test-log "RETARGET listener=NESTED"))

(define-command lem-yath-test-direnv-open-scratch () ()
  "Open an ineligible scratch buffer whose directory points at project B."
  (let ((buffer (make-buffer "*Direnv Ineligible Scratch*")))
    (setf (buffer-directory buffer)
          (direnv-test-directory-path "LEM_YATH_DIRENV_B_DIR"))
    (switch-to-buffer buffer)
    (direnv-test-record-state "scratch-retained" buffer)))

(define-command lem-yath-test-direnv-open-process-buffer () ()
  "Open a marked non-file process buffer rooted in project A."
  (let ((buffer (make-buffer "*Direnv Process Buffer*")))
    (setf (buffer-directory buffer)
          (direnv-test-directory-path "LEM_YATH_DIRENV_A_DIR")
          (buffer-value buffer 'lem-yath-direnv-process-buffer) t)
    (switch-to-buffer buffer)
    (direnv-test-record-state "process-a" buffer)))

(define-command lem-yath-test-direnv-record-retargeted () ()
  "Record the listener environment after its post-command retarget."
  (direnv-test-record-state "listener-retargeted"))

(define-command lem-yath-test-direnv-record-allowed () ()
  "Record the environment after explicit direnv authorization."
  (direnv-test-record-state "blocked-allowed"))

(define-command lem-yath-test-direnv-record-updated () ()
  "Record the environment after a forced same-directory refresh."
  (direnv-test-record-state "blocked-updated"))

(define-command lem-yath-test-direnv-record-malformed () ()
  "Record the environment retained after malformed output."
  (direnv-test-record-state "malformed-retained"))

(define-command lem-yath-test-direnv-record-timeout () ()
  "Record the environment retained after a timed-out export."
  (direnv-test-record-state "timeout-retained"))

(define-command lem-yath-test-direnv-record-recovered () ()
  "Record the environment after recovery from malformed output."
  (direnv-test-record-state "malformed-recovered"))

(define-command lem-yath-test-direnv-use-short-timeout () ()
  "Use a one-second timeout for the isolated slow-process assertion."
  (setf *direnv-timeout-seconds* 1)
  (direnv-test-log "TIMEOUT seconds=1"))

(define-command lem-yath-test-direnv-restore-timeout () ()
  "Restore the production timeout after the isolated slow-process assertion."
  (setf *direnv-timeout-seconds* 300)
  (direnv-test-log "TIMEOUT seconds=300"))

(define-command lem-yath-test-direnv-reload () ()
  "Reload the production module twice and report global hook multiplicity."
  (let ((source
          (merge-pathnames
           "src/direnv.lisp"
           (uiop:ensure-directory-pathname
            (direnv-test-path "LEM_YATH_SOURCE")))))
    (load source)
    (load source)
    (direnv-test-record-hooks "reload")
    (direnv-test-record-preferences "reload")
    (direnv-test-record-state "reload-current")))

(define-command lem-yath-test-direnv-use-custom-preferences () ()
  "Set nondefault user-facing values that source reloads must preserve."
  (setf *direnv-timeout-seconds* 17
        *direnv-always-show-summary* nil
        *direnv-show-paths-in-summary* nil)
  (direnv-test-record-preferences "custom"))

(define-command lem-yath-test-direnv-restore-preferences () ()
  "Restore production preference defaults after the reload assertion."
  (setf *direnv-timeout-seconds* 300
        *direnv-always-show-summary* t
        *direnv-show-paths-in-summary* t)
  (direnv-test-record-preferences "restored"))

(direnv-test-log "FIXTURE READY")
