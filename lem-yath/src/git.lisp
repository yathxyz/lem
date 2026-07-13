;;;; Git/VCS: Magit -> Legit, Majutsu -> a read-only jj status/log view, and
;;;; prog-mode-local git-gutter behavior.

(in-package :lem-yath)

(defvar *lem-yath-jj-root-key* 'lem-yath-jj-root)
(defvar *lem-yath-git-gutter-synced-mode-key*
  'lem-yath-git-gutter-synced-mode)

;; Defined later in the serial system, in ui.lisp.  Git state can be prepared
;; before the UI module loads, but rendering only happens after startup.
(declaim (ftype function join-left-display-content))
(declaim (ftype function run-project-program))
(declaim (special *project-process-timeout*))

(defparameter *legit-todo-result-limit* 200)
(defparameter *legit-todo-output-limit* (* 1024 1024))
(defparameter *legit-todo-timeout* 5)

(defstruct legit-todo
  path
  line
  text)

(defun parse-legit-todos (output)
  "Parse Git grep's NUL-delimited path, line, and text records."
  (let ((start 0)
        (length (length output))
        (results '()))
    (loop :while (and (< start length)
                      (< (length results) *legit-todo-result-limit*))
          :for path-end := (position #\Null output :start start)
          :for line-end := (and path-end
                                (position #\Null output
                                          :start (1+ path-end)))
          :for text-end := (and line-end
                                (or (position #\Newline output
                                              :start (1+ line-end))
                                    length))
          :while (and path-end line-end text-end)
          :for path := (subseq output start path-end)
          :for line := (parse-integer output
                                      :start (1+ path-end)
                                      :end line-end
                                      :junk-allowed t)
          :for text := (subseq output (1+ line-end) text-end)
          :when (and line (plusp line) (plusp (length path)))
            :do (push (make-legit-todo :path path :line line :text text)
                      results)
          :do (setf start (min length (1+ text-end))))
    (nreverse results)))

(defun collect-legit-todos (root)
  "Return bounded TODO/FIXME matches from tracked Git files below ROOT."
  (let ((git (or (executable-find "git")
                 (error "Git is unavailable"))))
    (let ((*project-process-timeout* *legit-todo-timeout*))
      (multiple-value-bind (output error-output status)
          (run-project-program
           (list (uiop:native-namestring git)
                 "grep" "-n" "-I" "-z" "-E" "(TODO|FIXME)" "--")
           :directory root
           :output-limit *legit-todo-output-limit*)
        (cond
          ((eql status 0) (parse-legit-todos output))
          ((eql status 1) '())
          (t
           (error "git grep failed (~a): ~a"
                  status
                  (completion-bounded-annotation error-output))))))))

(defun make-legit-todo-move-function (root todo)
  (let ((pathname (merge-pathnames (legit-todo-path todo) root))
        (line (legit-todo-line todo)))
    (lambda ()
      (let* ((buffer (find-file-buffer pathname))
             (point (buffer-point buffer)))
        (move-to-line point line)
        (line-start point)
        point))))

(defun insert-legit-todo-section (vcs collector)
  "Append a navigable tracked-file TODO/FIXME section to Legit status."
  (declare (ignore collector))
  (unless (string-equal "git" (lem/porcelain::vcs-name vcs))
    (return-from insert-legit-todo-section))
  (let ((root (uiop:ensure-directory-pathname (truename (uiop:getcwd)))))
    (handler-case
        (let ((todos (collect-legit-todos root)))
          (lem/legit::collector-insert "")
          (lem/legit::collector-insert
           (format nil "TODO/FIXME (~d):" (length todos)) :header t)
          (if todos
              (dolist (todo todos)
                (lem/legit::with-appending-source
                    (point
                     :move-function
                     (make-legit-todo-move-function root todo)
                     :visit-file-function
                     (let ((path (legit-todo-path todo)))
                       (lambda () path)))
                  (insert-string
                   point
                   (format nil "~a:~d: ~a"
                           (legit-todo-path todo)
                           (legit-todo-line todo)
                           (completion-bounded-annotation
                            (legit-todo-text todo)))
                   :attribute 'lem/legit::filename-attribute
                   :read-only t)))
              (lem/legit::collector-insert "<none>")))
      (error (condition)
        (lem/legit::collector-insert "")
        (lem/legit::collector-insert "TODO/FIXME (unavailable):" :header t)
        (lem/legit::collector-insert
         (completion-bounded-annotation (princ-to-string condition)))))))

(remove-hook lem/legit::*status-section-functions*
             'insert-legit-todo-section)
(add-hook lem/legit::*status-section-functions*
          'insert-legit-todo-section)

(defun vcs-directory (&optional (buffer (current-buffer)))
  "Return BUFFER's file directory, local directory, or Lem process directory."
  (or (and (buffer-filename buffer)
           (uiop:pathname-directory-pathname (buffer-filename buffer)))
      (ignore-errors (buffer-directory buffer))
      (uiop:getcwd)))

(defun jj-root (&optional directory)
  "Return the enclosing Jujutsu workspace root for DIRECTORY."
  (find-up (or directory (vcs-directory)) ".jj"))

(defun git-root (&optional directory)
  "Return the enclosing Git repository root for DIRECTORY."
  (find-up (or directory (vcs-directory)) ".git"))

(defun call-with-vcs-buffer-directory (directory function)
  "Call FUNCTION while the current buffer directory is temporarily DIRECTORY."
  (let* ((buffer (current-buffer))
         (old-directory
           (lem/buffer/internal::buffer-%directory buffer))
         (directory (uiop:ensure-directory-pathname directory)))
    (unwind-protect
         (progn
           (setf (buffer-directory buffer) directory)
           (funcall function))
      (unless (deleted-buffer-p buffer)
        (setf (lem/buffer/internal::buffer-%directory buffer)
              old-directory)))))

(defun run-jj (root arguments)
  "Run jj with direct ARGUMENTS at ROOT and return stdout, or signal an editor error."
  (let ((executable (executable-find "jj")))
    (unless executable
      (editor-error "The jj executable is unavailable"))
    (handler-case
        (multiple-value-bind (stdout stderr code)
            (uiop:run-program
             (append (list (namestring executable) "--color=never" "--no-pager")
                     arguments)
             :directory root
             :output :string
             :error-output :string
             :ignore-error-status t)
          (if (eql code 0)
              stdout
              (editor-error "jj ~a failed (~d): ~a"
                            (first arguments) code
                            (string-trim '(#\Space #\Tab #\Newline #\Return)
                                         stderr))))
      (editor-error (condition)
        (error condition))
      (error (condition)
        (editor-error "Could not run jj: ~a" condition)))))

(defun jj-status-text (root)
  "Return a bounded status and log report for Jujutsu workspace ROOT."
  (let ((status (run-jj root '("status")))
        (log (run-jj root '("log" "-n" "30"))))
    (format nil "Jujutsu: ~a~%~%Status~%~a~%Log (30 revisions)~%~a"
            (namestring root) status log)))

(defun jj-buffer-name (root)
  "Return a repository-specific buffer name for Jujutsu workspace ROOT."
  (format nil "*lem-yath-jj: ~a*"
          (namestring (or (ignore-errors (truename root)) root))))

(define-minor-mode lem-yath-jj-view-mode
    (:name "Jujutsu"
     :keymap *lem-yath-jj-view-keymap*)
  "Navigation keys for the read-only Jujutsu status/log buffer.")

(defun render-jj-buffer (buffer root)
  "Refresh BUFFER with Jujutsu data from ROOT."
  (let ((text (jj-status-text root)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer) text)
      (buffer-start (buffer-point buffer)))
    (buffer-unmark buffer)
    (setf (buffer-directory buffer) root
          (buffer-value buffer *lem-yath-jj-root-key*) root
          (buffer-read-only-p buffer) t)
    buffer))

(defun lem-yath-jj-log-at (directory)
  "Show Jujutsu status/log for the workspace enclosing DIRECTORY."
  (let ((root (jj-root directory)))
    (unless root
      (message "Not inside a Jujutsu workspace")
      (return-from lem-yath-jj-log-at))
    (let ((buffer (make-buffer (jj-buffer-name root) :directory root)))
      (change-buffer-mode
       buffer 'lem/buffer/fundamental-mode:fundamental-mode)
      (save-excursion
        (setf (current-buffer) buffer)
        (enable-minor-mode 'lem-yath-jj-view-mode))
      (render-jj-buffer buffer root)
      (switch-to-buffer buffer))))

(define-command lem-yath-jj-log () ()
  "Show Jujutsu status and a bounded log in a read-only buffer."
  (lem-yath-jj-log-at (vcs-directory)))

(define-command lem-yath-jj-refresh () ()
  "Refresh the current Jujutsu status/log buffer."
  (alexandria:if-let ((root (buffer-value (current-buffer)
                                          *lem-yath-jj-root-key*)))
    (progn
      (render-jj-buffer (current-buffer) root)
      (message "Jujutsu status refreshed"))
    (message "This is not a Jujutsu status buffer")))

(define-command lem-yath-jj-quit () ()
  "Quit the current Jujutsu status/log window."
  (if (buffer-value (current-buffer) *lem-yath-jj-root-key*)
      (quit-active-window)
      (message "This is not a Jujutsu status buffer")))

(defun jj-normal-g-keymap ()
  "Return vi normal state's existing `g' suffix keymap, if available."
  (alexandria:when-let
      ((prefix
         (lem-core::keymap-find lem-vi-mode:*normal-keymap*
                                (lem-core::parse-keyspec "g"))))
    (let ((suffix (lem-core::prefix-suffix prefix)))
      (when (typep suffix 'lem-core::keymap)
        suffix))))

;; Majutsu's Evil collection binds refresh at g r and leaves the rest of the
;; ordinary normal-state g prefix available.  Rebuild this subtree on reload.
(undefine-key *lem-yath-jj-view-keymap* "g")
(undefine-key *lem-yath-jj-view-keymap* "q")
(defparameter *lem-yath-jj-g-keymap*
  (make-keymap :description '*lem-yath-jj-g-keymap*
               :base (jj-normal-g-keymap)))
(define-key *lem-yath-jj-g-keymap* "r" 'lem-yath-jj-refresh)
(define-key *lem-yath-jj-view-keymap* "g" *lem-yath-jj-g-keymap*)
(define-key *lem-yath-jj-view-keymap* "q" 'lem-yath-jj-quit)

(defun lem-yath-legit-status-at (directory)
  "Open Legit at the Git root enclosing DIRECTORY."
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (root (or (git-root directory) directory)))
    (call-with-vcs-buffer-directory
     root
     (lambda () (uiop:symbol-call :lem/legit :legit-status)))))

(define-command lem-yath-legit-status () ()
  "Open Legit at the enclosing Git root, like the configured Magit command."
  (lem-yath-legit-status-at (vcs-directory)))

(defun lem-yath-vcs-status-at (directory)
  "Dispatch to Jujutsu or Git for the repository enclosing DIRECTORY."
  (cond
    ((jj-root directory) (lem-yath-jj-log-at directory))
    ((git-root directory) (lem-yath-legit-status-at directory))
    (t (lem-yath-legit-status-at directory))))

(define-command lem-yath-vcs-status () ()
  "Smart VCS dispatch: jj repo -> jj log view, otherwise legit (git)."
  (lem-yath-vcs-status-at (vcs-directory)))

;;; Git gutter ---------------------------------------------------------------

(defun lem-yath-git-gutter-enable-buffer ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer *lem-yath-git-gutter-synced-mode-key*)
          (buffer-major-mode buffer))
    (when (buffer-filename buffer)
      (lem-git-gutter::update-git-gutter-for-buffer buffer))))

(defun lem-yath-git-gutter-clear-buffer (buffer)
  (lem-git-gutter::cancel-buffer-git-gutter-timer buffer)
  (setf (lem-git-gutter::buffer-git-gutter-changes buffer) nil)
  (lem-git-gutter::clear-git-gutter-overlays buffer))

(defun lem-yath-git-gutter-disable-buffer ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer *lem-yath-git-gutter-synced-mode-key*) nil)
    (lem-yath-git-gutter-clear-buffer buffer)))

(define-minor-mode lem-yath-git-gutter-mode
    (:name "GitGutter"
     :enable-hook 'lem-yath-git-gutter-enable-buffer
     :disable-hook 'lem-yath-git-gutter-disable-buffer)
  "Show Git changes only in buffers equivalent to Emacs `prog-mode'.")

(defun lem-yath-git-gutter-mode-active-p (buffer)
  (member 'lem-yath-git-gutter-mode (buffer-minor-modes buffer)))

(defun lem-yath-git-gutter-sync-buffer (buffer)
  "Enable or disable the buffer-local gutter according to BUFFER's major mode."
  (unless (deleted-buffer-p buffer)
    (let* ((wanted (programming-buffer-p buffer))
           (active (lem-yath-git-gutter-mode-active-p buffer))
           (mode (buffer-major-mode buffer))
           (synced-mode
             (buffer-value buffer *lem-yath-git-gutter-synced-mode-key*)))
      (cond
        ((and wanted (not active))
         (save-excursion
           (setf (current-buffer) buffer)
           (lem-yath-git-gutter-mode t)))
        ((and wanted (not (eq mode synced-mode)))
         (save-excursion
           (setf (current-buffer) buffer)
           (setf (buffer-value buffer
                               *lem-yath-git-gutter-synced-mode-key*)
                 mode)
           (when (buffer-filename buffer)
             (lem-git-gutter::update-git-gutter-for-buffer buffer))))
        ((and (not wanted) active)
         (save-excursion
           (setf (current-buffer) buffer)
           (lem-yath-git-gutter-mode nil)))))))

(defun lem-yath-git-gutter-find-file (buffer)
  (lem-yath-git-gutter-sync-buffer buffer))

(defun lem-yath-git-gutter-post-command ()
  (lem-yath-git-gutter-sync-buffer (current-buffer)))

(defun lem-yath-git-gutter-after-save (&optional (buffer (current-buffer)))
  (when (lem-yath-git-gutter-mode-active-p buffer)
    (lem-git-gutter::cancel-buffer-git-gutter-timer buffer)
    (lem-git-gutter::update-git-gutter-for-buffer buffer)))

(defun lem-yath-git-gutter-after-change (start end old-length)
  (declare (ignore end old-length))
  (let ((buffer (point-buffer start)))
    (when (and (buffer-filename buffer)
               (lem-yath-git-gutter-mode-active-p buffer))
      (alexandria:when-let
          ((existing (lem-git-gutter::buffer-git-gutter-timer buffer)))
        (stop-timer existing))
      (let (timer)
        (setf timer
              (start-timer
               (make-idle-timer
                (lambda ()
                  (when (and (not (deleted-buffer-p buffer))
                             (eq timer
                                 (lem-git-gutter::buffer-git-gutter-timer
                                  buffer)))
                    (setf (lem-git-gutter::buffer-git-gutter-timer buffer)
                          nil)
                    (when (and (buffer-filename buffer)
                               (programming-buffer-p buffer)
                               (lem-yath-git-gutter-mode-active-p buffer))
                      (lem-git-gutter::update-git-gutter-for-buffer buffer))))
                :name "lem-yath-git-gutter-update")
               lem-git-gutter:*git-gutter-update-delay*
               :repeat nil)
              (lem-git-gutter::buffer-git-gutter-timer buffer) timer)))))

(defun lem-yath-git-gutter-kill-buffer (&optional (buffer (current-buffer)))
  (when (or (lem-yath-git-gutter-mode-active-p buffer)
            (lem-git-gutter::buffer-git-gutter-timer buffer)
            (lem-git-gutter::buffer-git-gutter-changes buffer))
    (lem-yath-git-gutter-clear-buffer buffer)))

(defmethod lem-core:compute-left-display-area-content
    ((mode lem-yath-git-gutter-mode) buffer point)
  (declare (ignore mode))
  (let* ((other-content (call-next-method))
         (changes (lem-git-gutter::buffer-git-gutter-changes buffer))
         (line-number (line-number-at-point point))
         (change-type (and changes (gethash line-number changes))))
    (if change-type
        (join-left-display-content
         (lem-git-gutter::make-gutter-content change-type)
         other-content)
        other-content)))

(defun enable-lem-yath-git-gutter ()
  "Install the buffer-local prog-mode gutter lifecycle idempotently."
  (when (member 'lem-git-gutter::git-gutter-mode
                (lem-core::active-global-minor-modes))
    (uiop:symbol-call :lem-git-gutter :git-gutter-mode nil))
  (pushnew ".git" lem-core/commands/project:*root-files* :test #'string=)
  (remove-hook *find-file-hook* 'lem-yath-git-gutter-find-file)
  (remove-hook *post-command-hook* 'lem-yath-git-gutter-post-command)
  (remove-hook (variable-value 'kill-buffer-hook :global t)
               'lem-yath-git-gutter-kill-buffer)
  (remove-hook (variable-value 'after-save-hook :global t)
               'lem-yath-git-gutter-after-save)
  (remove-hook (variable-value 'after-change-functions :global t)
               'lem-yath-git-gutter-after-change)
  (add-hook *find-file-hook* 'lem-yath-git-gutter-find-file)
  (add-hook *post-command-hook* 'lem-yath-git-gutter-post-command)
  (add-hook (variable-value 'kill-buffer-hook :global t)
            'lem-yath-git-gutter-kill-buffer)
  (add-hook (variable-value 'after-save-hook :global t)
            'lem-yath-git-gutter-after-save)
  (add-hook (variable-value 'after-change-functions :global t)
            'lem-yath-git-gutter-after-change)
  (dolist (buffer (buffer-list))
    (lem-yath-git-gutter-sync-buffer buffer)))

(initialize-editor-feature 'enable-lem-yath-git-gutter)
