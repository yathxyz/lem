(in-package :lem-yath)

(defvar *llm-workflow-report* (uiop:getenv "LEM_YATH_LLM_WORKFLOW_REPORT"))
(defvar *llm-workflow-source-buffer* (current-buffer))

(setf *llm-handoff-browser-commands*
      (list (uiop:getenv "LEM_YATH_LLM_WORKFLOW_BROWSER"))
      *llm-handoff-browser-arguments* '("--new-window"))

(defun llm-workflow-log (control &rest arguments)
  (with-open-file (stream *llm-workflow-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-workflow-mode-bits (pathname)
  #+sbcl
  (format nil "~3,'0o"
          (logand (sb-posix:stat-mode
                   (sb-posix:stat (uiop:native-namestring pathname)))
                  #o777))
  #-sbcl "unsupported")

(defun llm-workflow-killring-head ()
  (or (lem/common/killring:peek-killring-item (current-killring) 0) ""))

(define-command lem-yath-test-llm-workflow-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (llm-workflow-log "~a STATIC ~a"
                                 (if condition "PASS" "FAIL") name)
               (unless condition (incf failures))))
      (check (and (eq 'lem-yath-llm-menu
                      (leader-binding-command
                       lem-vi-mode:*normal-keymap* "g l"))
                  (eq 'lem-yath-llm-menu
                      (leader-binding-command
                       lem-vi-mode:*visual-keymap* "g l"))
                  (eq 'lem-yath-llm-menu
                      (leader-binding-command
                       lem-vi-mode:*normal-keymap* "g L")))
             "preset-menu-leader")
      (check (eq 'lem-yath-llm-ask
                 (leader-binding-command lem-vi-mode:*normal-keymap* "g i"))
             "ad-hoc-instruction-retained")
      (check (and (eq 'lem-yath-llm-save-preset (llm-menu-command "s"))
                  (eq 'lem-yath-llm-handoff-claude (llm-menu-command "c"))
                  (eq 'lem-yath-llm-handoff-chatgpt-search
                      (llm-menu-command "w")))
             "menu-dispatch")
      (check (and (assoc "quick-lookup" *llm-builtin-presets* :test #'string=)
                  (assoc "grok-build" *llm-builtin-presets* :test #'string=))
             "implemented-builtins")
      (let* ((body (yason:parse (llm-request-body "body prompt")))
             (messages (gethash "messages" body)))
        (check (and (string= (gethash "model" body) "openrouter/auto")
                    (= (gethash "temperature" body) 0.2)
                    (= (gethash "max_tokens" body) 800)
                    (string= (gethash "content" (elt messages 0))
                             *llm-system-message*))
               "quick-lookup-request-settings"))
      (let* ((text (concatenate 'string "old" (make-string 14000
                                                            :initial-element #\x)))
             (truncated (llm-handoff-truncate text 13000)))
        (check (and (= (length truncated) 13000)
                    (string= "[Truncated by Lem" truncated
                             :end2 (length "[Truncated by Lem"))
                    (char= (char truncated (1- (length truncated))) #\x))
               "bounded-tail-context"))
      (check (and (not (llm-preset-name-valid-p ""))
                  (not (llm-preset-name-valid-p (format nil "bad~%name"))))
             "reject-invalid-preset-names")
      (llm-workflow-log "SUMMARY STATIC ~a failures=~d"
                        (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-llm-workflow-settings () ()
  (setf *llm-backend* :codex
        *llm-model* "fixture-model"
        *llm-system-message* "fixture system"
        *llm-temperature* 0.7
        *llm-max-tokens* 1234
        *llm-current-preset* "fixture-preset")
  (llm-workflow-log "SETTINGS ready"))

(define-command lem-yath-test-llm-workflow-region () ()
  (switch-to-buffer *llm-workflow-source-buffer*)
  (setf (buffer-read-only-p *llm-workflow-source-buffer*) nil)
  (buffer-mark-cancel *llm-workflow-source-buffer*)
  (erase-buffer *llm-workflow-source-buffer*)
  (insert-string (buffer-start-point *llm-workflow-source-buffer*)
                 (format nil "prefix HANDOFFREGION suffix~%"))
  (buffer-start (buffer-point *llm-workflow-source-buffer*))
  (clear-buffer-edit-history *llm-workflow-source-buffer*)
  (llm-workflow-log "REGION ready"))

(define-command lem-yath-test-llm-workflow-long () ()
  (switch-to-buffer *llm-workflow-source-buffer*)
  (setf (buffer-read-only-p *llm-workflow-source-buffer*) nil)
  (buffer-mark-cancel *llm-workflow-source-buffer*)
  (erase-buffer *llm-workflow-source-buffer*)
  (insert-string (buffer-start-point *llm-workflow-source-buffer*)
                 (make-string 14000 :initial-element #\x))
  (buffer-start (buffer-point *llm-workflow-source-buffer*))
  (clear-buffer-edit-history *llm-workflow-source-buffer*)
  (llm-workflow-log "LONG ready"))

(define-command lem-yath-test-llm-workflow-record () ()
  (let* ((preset-file (llm-preset-pathname))
         (preset-directory (uiop:pathname-directory-pathname preset-file))
         (saved (assoc "fixture-preset" (llm-read-user-presets)
                       :test #'string=))
         (kill (llm-workflow-killring-head)))
    (llm-workflow-log
     (concatenate
      'string
      "STATE current=~a backend=~a model=~a system=~a temperature=~a max=~a "
      "saved=~a file-mode=~a dir-mode=~a kill-length=~d kill-truncated=~a")
     *llm-current-preset* *llm-backend* *llm-model* *llm-system-message*
     *llm-temperature* (or *llm-max-tokens* "none")
     (if saved "yes" "no")
     (if (uiop:file-exists-p preset-file)
         (llm-workflow-mode-bits preset-file) "none")
     (if (uiop:directory-exists-p preset-directory)
         (llm-workflow-mode-bits preset-directory) "none")
     (length kill)
     (if (and (<= (length "[Truncated by Lem") (length kill))
              (string= "[Truncated by Lem" kill
                       :end2 (length "[Truncated by Lem")))
         "yes" "no"))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-workflow-static)
  (define-key keymap "F3" 'lem-yath-test-llm-workflow-settings)
  (define-key keymap "F5" 'lem-yath-test-llm-workflow-region)
  (define-key keymap "F6" 'lem-yath-test-llm-workflow-long)
  (define-key keymap "F12" 'lem-yath-test-llm-workflow-record))

(llm-workflow-log "READY")
