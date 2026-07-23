(in-package :lem-yath)

(defvar *llm-codex-models-test-report*
  (uiop:getenv "LEM_YATH_LLM_CODEX_MODELS_REPORT"))
(defvar *llm-codex-models-test-initial-source* *llm-codex-model-source*)
(defvar *llm-codex-models-test-initial-models* (copy-list *llm-codex-models*))
(defvar *llm-codex-models-test-initial-timer-p*
  (not (null *llm-codex-model-refresh-timer*)))

(setf *llm-curl-executable*
      (uiop:getenv "LEM_YATH_LLM_CODEX_MODELS_CURL")
      *llm-backend* :chatgpt-codex
      *llm-model* (first *llm-codex-models*))

(defun llm-codex-models-test-log (control &rest arguments)
  (with-open-file (stream *llm-codex-models-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-codex-models-test-values (models)
  (format nil "~{~a~^,~}" models))

(defun llm-codex-models-test-condition-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(define-command lem-yath-test-llm-codex-models-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (llm-codex-models-test-log
                "~a STATIC ~a" (if condition "PASS" "FAIL") name)
               (unless condition (incf failures))))
      (check (eq *llm-codex-models-test-initial-source* :cache)
             "startup-cache-source")
      (check (equal *llm-codex-models-test-initial-models*
                    '("gpt-5.3-codex"))
             "startup-cache-filter-and-deduplication")
      (check *llm-codex-models-test-initial-timer-p*
             "idle-refresh-scheduled")
      (check (equal *llm-codex-model-fallback*
                    '("gpt-5.4" "gpt-5.3-codex"))
             "emacs-fallback-policy")
      (check (equal *llm-codex-model-candidates*
                    '("gpt-5.4" "gpt-5.3-codex"
                      "gpt-5.2-codex" "gpt-5-codex"))
             "emacs-candidate-policy")
      (check (equal
              (llm-codex-normalize-models
               '("unknown" "gpt-5.3-codex" "gpt-5.4"
                 "gpt-5.3-codex"))
              '("gpt-5.3-codex" "gpt-5.4"))
             "known-model-order-and-deduplication")
      (check (llm-codex-models-test-condition-p
              (lambda ()
                (llm-codex-normalize-models
                 '("gpt-5.4" 42) :strict t)))
             "cache-non-string-rejection")
      (check (equal (llm-model-candidates-for-backend :chatgpt-codex)
                    *llm-codex-models*)
             "backend-catalog-dispatch")
      (check (= (llm-codex-model-probe-http-status
                 (format nil "data: ignored~%~%__LEM_YATH_HTTP_STATUS__:429~%"))
                429)
             "probe-status-parser")
      (let* ((body (yason:parse
                    (llm-codex-model-probe-body "gpt-5.4")))
             (input (first (llm-json-elements (gethash "input" body))))
             (content (first
                       (llm-json-elements (gethash "content" input)))))
        (check (and (string= (gethash "model" body) "gpt-5.4")
                    (string= (gethash "instructions" body)
                             *llm-codex-instructions-prefix*)
                    (null (gethash "store" body))
                    (eq (gethash "stream" body) t)
                    (string= (gethash "text" content)
                             "Reply with exactly OK."))
               "minimal-probe-payload"))
      (let ((*llm-codex-models* '("gpt-5.3-codex"))
            (*llm-backend* :openrouter)
            (*llm-model* "openrouter/auto"))
        (llm-load-preset "codex-agentic")
        (check (and (eq *llm-backend* :chatgpt-codex)
                    (string= *llm-model* "gpt-5.3-codex"))
               "preset-compatible-model-fallback"))
      (check (and (eq (llm-menu-command "m") 'lem-yath-llm-full-menu)
                  (eq (nth-value 0 (llm-full-menu-action "m"))
                      'lem-yath-llm-set-model))
             "compact-to-full-model-dispatch")
      (check (find-command "lem-yath-chatgpt-codex-refresh-models")
             "manual-refresh-command")
      (llm-codex-models-test-log
       "SUMMARY STATIC ~a failures=~d"
       (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-llm-codex-models-record () ()
  (llm-codex-models-test-log
   "STATE source=~a count=~d values=~a model=~a running=~a timer=~a"
   (string-upcase (symbol-name *llm-codex-model-source*))
   (length *llm-codex-models*)
   (llm-codex-models-test-values *llm-codex-models*)
   *llm-model*
   (if *llm-codex-model-refresh-running-p* "yes" "no")
   (if *llm-codex-model-refresh-timer* "yes" "no")))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-codex-models-static)
  (define-key keymap "F3" 'lem-yath-test-llm-codex-models-record))

(llm-codex-models-test-log
 "READY source=~a values=~a timer=~a"
 (string-upcase (symbol-name *llm-codex-models-test-initial-source*))
 (llm-codex-models-test-values *llm-codex-models-test-initial-models*)
 (if *llm-codex-models-test-initial-timer-p* "yes" "no"))
