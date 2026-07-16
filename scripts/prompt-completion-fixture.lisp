(in-package :lem-yath)

(defvar *prompt-completion-fixture-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_PROMPT_COMPLETION_ROOT")))

(defvar *prompt-completion-fixture-report*
  (uiop:getenv "LEM_YATH_PROMPT_COMPLETION_REPORT"))

(defparameter *prompt-completion-prescient-candidates*
  '("Alpha"
    "alpha"
    "axbyc"
    "café"
    "find-file-at-point"
    "needle"
    "phantom"
    "string-repeat"))

(defparameter *prompt-completion-edit-candidates*
  '("fixture-preset" "quick-lookup" "project-readonly"))

(defun prompt-completion-fixture-path (relative)
  (merge-pathnames relative *prompt-completion-fixture-root*))

(defun prompt-completion-fixture-log (control &rest arguments)
  (with-open-file (stream *prompt-completion-fixture-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun prompt-completion-fixture-log-prescient-state ()
  "Record physical toggle dispatch, including Lem's raw prefix argument."
  (let* ((command (this-command))
         (name (and command
                    (string-upcase (string (command-name command))))))
    (when (and name
               (completion-prompt-active-p)
               (search "LEM-YATH-PRESCIENT-TOGGLE-" name))
      (let ((state (completion-prompt-prescient-state)))
        (prompt-completion-fixture-log
         "PRESCIENT-STATE command=~a argument=~s methods=~{~a~^,~} case=~s char=~s"
         name
         (universal-argument-of-this-command)
         (and state (completion-prescient-state-methods state))
         (and state (completion-prescient-state-case-folding state))
         (and state
              (completion-prescient-state-character-folding-p state)))))))

(defun prompt-completion-fixture-write (relative contents)
  (let ((path (prompt-completion-fixture-path relative)))
    (ensure-directories-exist path)
    (alexandria:write-string-into-file contents path :if-exists :supersede)
    path))

(defun prompt-completion-fixture-setup ()
  (with-open-file (stream *prompt-completion-fixture-report*
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (format stream "SETUP~%"))
  (let* ((first-path
           (prompt-completion-fixture-write
            "buffers/one/shared.txt" (format nil "first shared buffer~%")))
         (second-path
           (prompt-completion-fixture-write
            "buffers/two/shared.txt" (format nil "second shared buffer~%")))
         (first-buffer (find-file-buffer first-path))
         (second-buffer (find-file-buffer second-path))
         (paren-buffer
           (find-file-buffer
            (prompt-completion-fixture-write
             "buffers/parens/()paired.txt" (format nil "paren buffer~%"))))
         (dirty-buffer
           (find-file-buffer
            (prompt-completion-fixture-write
             "buffers/annotation-dirty.py" "dirty\n")))
         (read-only-buffer
           (find-file-buffer
            (prompt-completion-fixture-write
             "buffers/annotation-readonly.txt" "readonly\n")))
         (read-only-modified-buffer
           (find-file-buffer
            (prompt-completion-fixture-write
             "buffers/annotation-readonly-modified.txt" "both\n"))))
    (insert-string (buffer-end-point dirty-buffer) "x")
    (setf (buffer-read-only-p read-only-buffer) t)
    (insert-string (buffer-end-point read-only-modified-buffer) "x")
    (setf (buffer-read-only-p read-only-modified-buffer) t)
    (prompt-completion-fixture-write
     "files/nested/alpha-report.txt" (format nil "alpha~%"))
    (prompt-completion-fixture-write
     "files/nested/alpine-report.txt" (format nil "alpine~%"))
    (dolist (buffer (list first-buffer second-buffer paren-buffer
                          dirty-buffer read-only-buffer
                          read-only-modified-buffer))
      (prompt-completion-fixture-log
       "BUFFER name=~a path=~a"
       (buffer-name buffer)
       (namestring (buffer-filename buffer))))
    (prompt-completion-fixture-log "READY")))

(defun prompt-completion-fixture-check-wrapper-installation ()
  "Exercise fresh-provider capture and annotation-only reload idempotence."
  (unless (= 1 (count 'completion-reset-prompt-undo-history
                      *prompt-after-activate-hook*
                      :key #'car :test #'eq))
    (error "Prompt undo baseline hook was not installed exactly once"))
  (let ((original *completion-unannotated-buffer-function*)
        (replacement (lambda (input &rest arguments)
                       (declare (ignore input arguments))
                       nil)))
    (setf *prompt-buffer-completion-function* replacement)
    (completion-install-prompt-producers)
    (unless (and (eq *completion-unannotated-buffer-function* replacement)
                 (eq *prompt-buffer-completion-function*
                     'completion-annotated-buffer-function))
      (error "Annotation wrapper did not capture a fresh provider"))
    (completion-install-prompt-producers)
    (unless (eq *completion-unannotated-buffer-function* replacement)
      (error "Annotation-only reinstall wrapped its own provider"))
    (setf *completion-unannotated-buffer-function* original)))

(defun prompt-completion-fixture-check-size-cache ()
  "Prove repeated size reads are cached and content edits invalidate them."
  (let ((buffer (make-buffer "*completion-size-cache*")))
    (unwind-protect
         (progn
           (insert-string (buffer-end-point buffer) "a")
           (unless (= 1 (completion-buffer-size buffer))
             (error "Initial completion size cache was wrong"))
           (let* ((tick (buffer-modified-tick buffer))
                  (cache (buffer-value
                          buffer 'lem-yath-completion-size-cache)))
             (unless (and (consp cache)
                          (= tick (car cache))
                          (= 1 (cdr cache)))
               (error "Completion size cache did not retain the tick and size")))
           (insert-string (buffer-end-point buffer) "b")
           (unless (= 2 (completion-buffer-size buffer))
             (error "Completion size cache survived a content edit")))
      (delete-buffer buffer))))

(define-command lem-yath-test-buffer-prompt () ()
  "Open the configured buffer prompt over the fixture buffers."
  (let* ((choice (prompt-for-buffer "Fixture buffer: " :existing t))
         (buffer (and choice (get-buffer choice))))
    (when buffer
      (prompt-completion-fixture-log
       "BUFFER-SELECT name=~a path=~a"
       choice
       (namestring (buffer-filename buffer)))
      (switch-to-buffer buffer))))

(define-command lem-yath-test-file-prompt () ()
  "Open the configured path-aware file prompt at the fixture root."
  (let ((choice
          (prompt-for-file
           "Fixture file: "
           :directory (namestring
                       (prompt-completion-fixture-path "files/"))
           :default nil
           :existing t)))
    (when choice
      (prompt-completion-fixture-log
       "FILE-SELECT value=~a directory=~a"
       choice
       (not (null (uiop:directory-pathname-p (pathname choice))))))))

(define-command lem-yath-test-prescient-toggle-prompt () ()
  "Open a stable candidate corpus for physical Prescient toggle tests."
  (let ((choice
          (prompt-for-string
           "Prescient fixture: "
           :completion-function
           (lambda (input)
             (mapcar
              (lambda (label)
                (lem/completion-mode:make-completion-item
                 :label label :detail "toggle-candidate"))
              (prescient-filter
               input *prompt-completion-prescient-candidates* :rank-p nil)))
           :test-function
           (lambda (input)
             (member input *prompt-completion-prescient-candidates*
                     :test #'string=)))))
    (prompt-completion-fixture-log "PRESCIENT-SELECT value=~a" choice)))

(defun prompt-completion-fixture-read-edit (initial-value)
  (let ((choice
          (prompt-for-string
           "Prompt edit: "
           :initial-value initial-value
           :completion-function
           (lambda (input)
             (prescient-filter input *prompt-completion-edit-candidates*
                               :rank-p nil))
           :test-function
           (lambda (input)
             (member input *prompt-completion-edit-candidates*
                     :test #'string=)))))
    (prompt-completion-fixture-log "PROMPT-EDIT-SELECT value=~a" choice)))

(define-command lem-yath-test-prompt-line-editing () ()
  "Open a nonempty prompt for physical Emacs line-editing coverage."
  (prompt-completion-fixture-read-edit "quick-lookup"))

(define-command lem-yath-test-prompt-kill-ring () ()
  "Open an empty prompt with two deterministic kill-ring entries."
  (lem/common/killring:push-killring-item
   (current-killring) "quick-lookup")
  (lem/common/killring:push-killring-item
   (current-killring) "fixture-preset")
  (prompt-completion-fixture-read-edit ""))

(prompt-completion-fixture-check-wrapper-installation)
(prompt-completion-fixture-check-size-cache)
(remove-hook *post-command-hook*
             'prompt-completion-fixture-log-prescient-state)
(add-hook *post-command-hook*
          'prompt-completion-fixture-log-prescient-state)
(prompt-completion-fixture-setup)
