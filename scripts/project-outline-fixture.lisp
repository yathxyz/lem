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

(defvar *project-outline-test-org*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_ORG")))

(defvar *project-outline-test-markdown*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_MARKDOWN")))

(defvar *project-outline-test-python*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_PYTHON")))

(defvar *project-outline-test-python-wide*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_PYTHON_WIDE")))

(defvar *project-outline-test-java*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_JAVA")))

(defvar *project-outline-test-c*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_C")))

(defvar *project-outline-test-cpp*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_CPP")))

(defvar *project-outline-test-rust*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_RUST")))

(defvar *project-outline-test-go*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_GO")))

(defvar *project-outline-test-gdscript*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_GDSCRIPT")))

(defvar *project-outline-test-typst*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_TYPST")))

(defvar *project-outline-test-reader-marker*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PROJECT_OUTLINE_READER_MARKER")))

(defvar *project-outline-test-default-jump-delay*
  *jump-feedback-delay-ms*)

;; Keep the pulse observable across a tmux key round-trip.  The separate
;; configuration assertion below still records the production 30 ms value.
(setf *jump-feedback-delay-ms* 200)

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
      ((and file (uiop:pathname-equal file *project-outline-test-org*)) "org")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-markdown*)) "markdown")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-python*)) "python")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-python-wide*)) "python-wide")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-java*)) "java")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-c*)) "c")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-cpp*)) "cpp")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-rust*)) "rust")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-go*)) "go")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-gdscript*)) "gdscript")
      ((and file (uiop:pathname-equal
                  file *project-outline-test-typst*)) "typst")
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

(defun project-outline-test-pulse-state (buffer)
  (let* ((pulse *jump-feedback-current-pulse*)
         (overlay (and pulse (jump-feedback-pulse-overlay pulse)))
         (attribute (and overlay (overlay-attribute overlay))))
    (values
     (and pulse (jump-feedback-pulse-active-p pulse))
     (and pulse (jump-feedback-pulse-stage pulse))
     (and overlay
          (eq buffer (overlay-buffer overlay))
          (line-number-at-point (overlay-start overlay)))
     (and attribute
          (find attribute *jump-feedback-stage-attributes*
                :key #'ensure-attribute :test #'attribute-equal)
          (symbol-name
           (find attribute *jump-feedback-stage-attributes*
                 :key #'ensure-attribute :test #'attribute-equal)))
     (count-if
      (lambda (candidate)
        (find (overlay-attribute candidate)
              *jump-feedback-stage-attributes*
              :key #'ensure-attribute :test #'attribute-equal))
      (lem-core::buffer-overlays buffer)))))

(define-command lem-yath-test-project-outline-report () ()
  (let* ((session (and *project-outline-session*
                       (project-outline-session-active-p
                        *project-outline-session*)
                       *project-outline-session*))
         (buffer (project-outline-test-source-buffer))
         (window (project-outline-test-source-window buffer)))
    (with-current-buffer buffer
      (let ((point (buffer-point buffer)))
        (multiple-value-bind
            (pulse stage pulse-line pulse-attribute pulse-overlays)
            (project-outline-test-pulse-state buffer)
          (project-outline-test-log
           (concatenate
            'string
            "STATE file=~a line=~d column=~d view=~a minor=~a regexp=~s "
            "normal=~a emacs=~a insert=~a visual=~a "
            "preview=~s input=~s pulse=~a pulse-stage=~a "
            "pulse-line=~a pulse-attribute=~a pulse-overlays=~d "
            "folds=~d hidden=~a reader-marker=~a")
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
            (lem-vi-mode/core:ensure-state
             'lem-vi-mode/visual::visual-char))
           (and session
                (alexandria:when-let
                    ((candidate
                       (project-outline-session-preview-candidate session)))
                  (project-outline-candidate-label candidate)))
           (and session (project-outline-current-input))
           (if pulse "yes" "no")
           (or stage "none")
           (or pulse-line "none")
           (or pulse-attribute "none")
           pulse-overlays
           (length (org-buffer-folds buffer))
           (if (and (mode-active-p buffer 'org-mode)
                    (org-hidden-range-at-point point))
               "yes" "no")
           (if (uiop:file-exists-p *project-outline-test-reader-marker*)
               "yes" "no")))))))

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

(defun project-outline-test-log-imenu-candidate (candidate prefix)
  (let ((path (if prefix
                  (concatenate 'string prefix "/"
                               (imenu-candidate-label candidate))
                  (imenu-candidate-label candidate))))
    (project-outline-test-log "IMENU-PATH file=~a path=~s"
                              (project-outline-test-file-label
                               (current-buffer))
                              (concatenate 'string path))
    (dolist (child (imenu-candidate-children candidate))
      (project-outline-test-log-imenu-candidate child path))))

(define-command lem-yath-test-project-outline-imenu-index () ()
  (let ((candidates (imenu-candidates (current-buffer))))
    (unwind-protect
         (progn
           (project-outline-test-log "IMENU-INDEX file=~a count=~d"
                                     (project-outline-test-file-label
                                      (current-buffer))
                                     (labels ((count-tree (items)
                                                (loop :for item :in items
                                                      :sum (+ 1
                                                              (count-tree
                                                               (imenu-candidate-children
                                                                item))))))
                                       (count-tree candidates)))
           (dolist (candidate candidates)
             (project-outline-test-log-imenu-candidate candidate nil)))
      (imenu-delete-candidates candidates))))

(define-command lem-yath-test-project-outline-mode () ()
  (project-outline-test-log
   "MODE file=~a major=~a tree=~a"
   (project-outline-test-file-label (current-buffer))
   (buffer-major-mode (current-buffer))
   (or (buffer-value (current-buffer) 'lem-yath-tree-sitter-language)
       "none")))

(define-command lem-yath-test-project-outline-provider () ()
  (let* ((buffer (current-buffer))
         (workspace (lem-lsp-mode::buffer-workspace buffer nil))
         (provider
           (cdr (assoc (buffer-major-mode buffer)
                       *imenu-native-providers* :test #'eq))))
    (project-outline-test-log
     "PROVIDER file=~a native=~a lsp=~a"
     (project-outline-test-file-label buffer)
     (or provider "none")
     (if workspace
         (lem-lsp-mode::workspace-state workspace)
         "none"))))

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

(define-command lem-yath-test-project-outline-org () ()
  (find-file *project-outline-test-org*))

(define-command lem-yath-test-project-outline-markdown () ()
  ;; The production Eglot override has separate fake-server coverage.  This
  ;; fixture deliberately exercises markdown-mode's native fallback.
  (lem-lsp-mode:without-lsp-mode ()
    (find-file *project-outline-test-markdown*)))

(define-command lem-yath-test-project-outline-python () ()
  ;; Exercise the native python-ts-mode fallback without starting pyright.
  (lem-lsp-mode:without-lsp-mode ()
    (find-file *project-outline-test-python*)))

(define-command lem-yath-test-project-outline-python-wide () ()
  (lem-lsp-mode:without-lsp-mode ()
    (find-file *project-outline-test-python-wide*)))

(define-command lem-yath-test-project-outline-java () ()
  ;; Exercise the native java-ts-mode fallback without starting JDTLS.
  (lem-lsp-mode:without-lsp-mode ()
    (find-file *project-outline-test-java*)))

(define-command lem-yath-test-project-outline-c () ()
  ;; Exercise the native c-ts-mode fallback without starting clangd.
  (lem-lsp-mode:without-lsp-mode ()
    (find-file *project-outline-test-c*)))

(define-command lem-yath-test-project-outline-cpp () ()
  (lem-lsp-mode:without-lsp-mode ()
    (find-file *project-outline-test-cpp*)))

(define-command lem-yath-test-project-outline-rust () ()
  (lem-lsp-mode:without-lsp-mode ()
    (find-file *project-outline-test-rust*))
  ;; Rust is normally auto-managed.  Keep this fixture on the explicit native
  ;; fallback path even if a previously ready workspace adopts the new file.
  (when (mode-active-p (current-buffer) 'lem-lsp-mode::lsp-mode)
    (lem-lsp-mode::lsp-mode nil)))

(define-command lem-yath-test-project-outline-go () ()
  (lem-lsp-mode:without-lsp-mode ()
    (find-file *project-outline-test-go*))
  (when (mode-active-p (current-buffer) 'lem-lsp-mode::lsp-mode)
    (lem-lsp-mode::lsp-mode nil)))

(define-command lem-yath-test-project-outline-gdscript () ()
  (lem-lsp-mode:without-lsp-mode ()
    (find-file *project-outline-test-gdscript*))
  (when (mode-active-p (current-buffer) 'lem-lsp-mode::lsp-mode)
    (lem-lsp-mode::lsp-mode nil)))

(define-command lem-yath-test-project-outline-typst () ()
  (find-file *project-outline-test-typst*))

(define-command lem-yath-test-project-outline-imenu-count () ()
  (let ((candidates (imenu-candidates (current-buffer))))
    (unwind-protect
         (project-outline-test-log "IMENU-WIDE file=~a count=~d"
                                   (project-outline-test-file-label
                                    (current-buffer))
                                   (length candidates))
      (imenu-delete-candidates candidates))))

(define-command lem-yath-test-project-outline-fold-org () ()
  (unless (eq (buffer-major-mode (current-buffer)) 'org-mode)
    (editor-error "The Org Imenu fixture is not current"))
  (with-point ((heading (buffer-start-point (current-buffer))))
    (line-offset heading 2)
    (org-fold-subtree heading))
  (lem-yath-test-project-outline-bottom))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*
                      *lem-yath-emacs-state-keymap*
                      lem/prompt-window::*prompt-mode-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "C-c z r" 'lem-yath-test-project-outline-report)
  (define-key keymap "C-c z c" 'lem-yath-test-project-outline-candidates)
  (define-key keymap "C-c z i" 'lem-yath-test-project-outline-imenu-index)
  (define-key keymap "C-c z m" 'lem-yath-test-project-outline-mode)
  (define-key keymap "C-c z v" 'lem-yath-test-project-outline-provider)
  (define-key keymap "C-c z b" 'lem-yath-test-project-outline-bottom)
  (define-key keymap "C-c z 1" 'lem-yath-test-project-outline-main)
  (define-key keymap "C-c z 2" 'lem-yath-test-project-outline-outside)
  (define-key keymap "C-c z 3" 'lem-yath-test-project-outline-malicious)
  (define-key keymap "C-c z 4" 'lem-yath-test-project-outline-empty)
  (define-key keymap "C-c z 5" 'lem-yath-test-project-outline-org)
  (define-key keymap "C-c z 6" 'lem-yath-test-project-outline-markdown)
  (define-key keymap "C-c z 7" 'lem-yath-test-project-outline-python)
  (define-key keymap "C-c z 8" 'lem-yath-test-project-outline-python-wide)
  (define-key keymap "C-c z 9" 'lem-yath-test-project-outline-java)
  (define-key keymap "C-c z 0" 'lem-yath-test-project-outline-c)
  (define-key keymap "C-c z p" 'lem-yath-test-project-outline-cpp)
  (define-key keymap "C-c z u" 'lem-yath-test-project-outline-rust)
  (define-key keymap "C-c z g" 'lem-yath-test-project-outline-go)
  (define-key keymap "C-c z d" 'lem-yath-test-project-outline-gdscript)
  (define-key keymap "C-c z t" 'lem-yath-test-project-outline-typst)
  (define-key keymap "C-c z w" 'lem-yath-test-project-outline-imenu-count)
  (define-key keymap "C-c z f" 'lem-yath-test-project-outline-fold-org))

(project-outline-test-log
 "JUMP-CONFIG delay=~d stages=~d colors=~{~a~^,~}"
 *project-outline-test-default-jump-delay*
 (length *jump-feedback-stage-attributes*)
 (mapcar (lambda (name)
           (or (attribute-background (ensure-attribute name)) "none"))
         *jump-feedback-stage-attributes*))
(project-outline-test-log "READY")
