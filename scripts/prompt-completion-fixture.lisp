(in-package :lem-yath)

(defvar *prompt-completion-fixture-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_PROMPT_COMPLETION_ROOT")))

(defvar *prompt-completion-fixture-report*
  (uiop:getenv "LEM_YATH_PROMPT_COMPLETION_REPORT"))

(defun prompt-completion-fixture-path (relative)
  (merge-pathnames relative *prompt-completion-fixture-root*))

(defun prompt-completion-fixture-log (control &rest arguments)
  (with-open-file (stream *prompt-completion-fixture-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

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
             "buffers/parens/()paired.txt" (format nil "paren buffer~%")))))
    (prompt-completion-fixture-write
     "files/nested/alpha-report.txt" (format nil "alpha~%"))
    (prompt-completion-fixture-write
     "files/nested/alpine-report.txt" (format nil "alpine~%"))
    (dolist (buffer (list first-buffer second-buffer paren-buffer))
      (prompt-completion-fixture-log
       "BUFFER name=~a path=~a"
       (buffer-name buffer)
       (namestring (buffer-filename buffer))))
    (prompt-completion-fixture-log "READY")))

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

(prompt-completion-fixture-setup)
