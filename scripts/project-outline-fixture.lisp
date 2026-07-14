(in-package :lem-yath)

(defvar *project-outline-test-report*
  (or (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_REPORT")
      (error "Project outline report path is unset")))

(defvar *project-outline-test-main*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_MAIN")))

(defvar *project-outline-test-outside*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_OUTSIDE")))

(defvar *project-outline-test-malicious*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_MALICIOUS")))

(defvar *project-outline-test-empty*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_EMPTY")))

(defvar *project-outline-test-reader-marker*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_READER_MARKER")))

(defun project-outline-test-log (control &rest arguments)
  (with-open-file (stream *project-outline-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun project-outline-test-file-label (buffer)
  (let ((file (buffer-filename buffer)))
    (cond
      ((and file (uiop:pathname-equal file *project-outline-test-main*)) "main")
      ((and file (uiop:pathname-equal file *project-outline-test-outside*))
       "outside")
      ((and file (uiop:pathname-equal file *project-outline-test-malicious*))
       "malicious")
      ((and file (uiop:pathname-equal file *project-outline-test-empty*)) "empty")
      (t "other"))))

(defun project-outline-test-command-name (state)
  (lem-vi-mode/core:with-state state
    (let ((command (find-keybind (lem-core::parse-keyspec "C-c i"))))
      (if (symbolp command)
          (symbol-name command)
          (princ-to-string command)))))

(defun project-outline-test-source-buffer ()
  (if (and *project-outline-session*
           (project-outline-session-active-p *project-outline-session*))
      (project-outline-session-source-buffer *project-outline-session*)
      (current-buffer)))

(defun project-outline-test-source-window (buffer)
  (or (and *project-outline-session*
           (project-outline-session-active-p *project-outline-session*)
           (project-outline-session-source-window *project-outline-session*))
      (find buffer (get-buffer-windows buffer)
            :key #'window-buffer :test #'eq)
      (current-window)))

(define-command lem-yath-test-project-outline-report () ()
  (let* ((session (and *project-outline-session*
                       (project-outline-session-active-p
                        *project-outline-session*)
                       *project-outline-session*))
         (buffer (project-outline-test-source-buffer))
         (window (project-outline-test-source-window buffer)))
    (with-current-buffer buffer
      (let ((point (buffer-point buffer)))
        (project-outline-test-log
         (concatenate
          'string
          "STATE file=~a line=~d column=~d view=~a minor=~a regexp=~s "
          "normal=~a emacs=~a insert=~a visual=~a "
          "preview=~s input=~s "
          "reader-marker=~a")
         (project-outline-test-file-label buffer)
         (line-number-at-point point)
         (point-column point)
         (if (and window
                  (not (deleted-window-p window))
                  (eq (window-buffer window) buffer))
             (line-number-at-point (window-view-point window))
             "none")
         (if (mode-active-p buffer 'lem-yath-project-outline-mode)
             "yes" "no")
         (buffer-value buffer 'lem-yath-project-outline-regexp)
         (project-outline-test-command-name
          (lem-vi-mode/core:ensure-state 'lem-vi-mode/states:normal))
         (project-outline-test-command-name *lem-yath-emacs-state*)
         (project-outline-test-command-name
          (lem-vi-mode/core:ensure-state 'lem-vi-mode/states:insert))
         (project-outline-test-command-name
          (lem-vi-mode/core:ensure-state 'lem-vi-mode/visual::visual-char))
         (and session
              (alexandria:when-let
                  ((candidate
                     (project-outline-session-preview-candidate session)))
                (project-outline-candidate-label candidate)))
         (and session (project-outline-current-input))
         (if (uiop:file-exists-p *project-outline-test-reader-marker*)
             "yes" "no"))))))

(define-command lem-yath-test-project-outline-candidates () ()
  (let* ((buffer (current-buffer))
         (regexp
           (buffer-value buffer 'lem-yath-project-outline-regexp))
         (candidates (and regexp
                          (project-outline-candidates buffer regexp))))
    (unwind-protect
         (progn
           (project-outline-test-log "CANDIDATES count=~d"
                                     (length candidates))
           (dolist (candidate candidates)
             (project-outline-test-log
              "CANDIDATE line=~d label=~s"
              (project-outline-candidate-line candidate)
              (project-outline-candidate-label candidate))))
      (project-outline-delete-candidates candidates))))

(define-command lem-yath-test-project-outline-bottom () ()
  (let ((point (buffer-point (current-buffer))))
    (move-point point (buffer-end-point (current-buffer)))
    (when (plusp (position-at-point point))
      (character-offset point -1))
    (line-start point)
    (window-recenter (current-window))))

(define-command lem-yath-test-project-outline-main () ()
  (find-file *project-outline-test-main*))

(define-command lem-yath-test-project-outline-outside () ()
  (find-file *project-outline-test-outside*))

(define-command lem-yath-test-project-outline-malicious () ()
  (find-file *project-outline-test-malicious*))

(define-command lem-yath-test-project-outline-empty () ()
  (find-file *project-outline-test-empty*))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*
                      *lem-yath-emacs-state-keymap*
                      lem/prompt-window::*prompt-mode-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "C-c z r" 'lem-yath-test-project-outline-report)
  (define-key keymap "C-c z c" 'lem-yath-test-project-outline-candidates)
  (define-key keymap "C-c z b" 'lem-yath-test-project-outline-bottom)
  (define-key keymap "C-c z 1" 'lem-yath-test-project-outline-main)
  (define-key keymap "C-c z 2" 'lem-yath-test-project-outline-outside)
  (define-key keymap "C-c z 3" 'lem-yath-test-project-outline-malicious)
  (define-key keymap "C-c z 4" 'lem-yath-test-project-outline-empty))

(project-outline-test-log "READY")
