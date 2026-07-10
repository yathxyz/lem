;;;; Project tools: compile (SPC c c), project buffer switching (SPC SPC),
;;;; duplicate-dwim (M-j).

(in-package :lem-yath)

(define-command lem-yath-compile () ()
  "Prompt for a shell command and stream its output into *compilation*.
Runs from the project root; the worker runs on a background thread."
  (let* ((dir (or (ignore-errors
                    (lem-core/commands/project:find-root
                     (buffer-directory (current-buffer))))
                  (ignore-errors (buffer-directory (current-buffer)))
                  (user-homedir-pathname)))
         (command (prompt-for-string (format nil "Compile [~a]: " dir)
                                     :history-symbol 'lem-yath-compile)))
    (when (plusp (length command))
      (stream-to-buffer (list "sh" "-c" command) "*compilation*"
                        :directory dir))))

(define-command lem-yath-project-buffers () ()
  "Switch among buffers of the current project (consult-project-buffer)."
  (let* ((root (ignore-errors
                 (namestring
                  (lem-core/commands/project:find-root
                   (buffer-directory (current-buffer))))))
         (names (loop :for b :in (buffer-list)
                      :for file := (buffer-filename b)
                      :when (and file root
                                 (alexandria:starts-with-subseq
                                  root (namestring file)))
                        :collect (buffer-name b))))
    (unless names
      (message "No file buffers in this project")
      (return-from lem-yath-project-buffers))
    (let ((choice (prompt-for-string
                   "Project buffer: "
                   :completion-function (lambda (s) (orderless-filter s names))
                   :test-function (lambda (s) (member s names :test #'string=)))))
      (when choice
        (switch-to-buffer (get-buffer choice))))))

(define-command lem-yath-kill-current-buffer () ()
  "Kill the current buffer without prompting (kill-current-buffer)."
  (kill-buffer (current-buffer)))

(define-command lem-yath-duplicate-line () ()
  "Duplicate the current line below (duplicate-dwim approximation)."
  (with-point ((p (current-point)))
    (let ((text (line-string p)))
      (line-end p)
      (insert-string p (format nil "~%~a" text)))))
