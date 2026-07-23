(in-package :lem-yath)

(defvar *llm-models-test-report*
  (uiop:getenv "LEM_YATH_LLM_MODELS_REPORT"))
(defvar *llm-models-test-initial-source* *llm-openrouter-model-source*)
(defvar *llm-models-test-initial-models* (copy-list *llm-openrouter-models*))
(defvar *llm-models-test-initial-timer-p*
  (not (null *llm-openrouter-model-refresh-timer*)))

(setf *llm-curl-executable* (uiop:getenv "LEM_YATH_LLM_MODELS_CURL"))

(defun llm-models-test-log (control &rest arguments)
  (with-open-file (stream *llm-models-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-models-test-values (models)
  (format nil "~{~a~^,~}" models))

(defun llm-models-test-condition-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(define-command lem-yath-test-llm-models-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (llm-models-test-log "~a STATIC ~a"
                                    (if condition "PASS" "FAIL") name)
               (unless condition (incf failures))))
      (check (eq *llm-models-test-initial-source* :cache)
             "startup-cache-source")
      (check (equal *llm-models-test-initial-models*
                    '("cached/model" "openrouter/auto"))
             "startup-cache-order-and-deduplication")
      (check *llm-models-test-initial-timer-p* "idle-refresh-scheduled")
      (check (string= (llm-openrouter-models-url)
                      "https://openrouter.ai/api/v1/models/user")
             "authenticated-model-endpoint")
      (check (equal (llm-openrouter-model-headers)
                    '(("Authorization" .
                       "Bearer model-catalog-test-secret")))
             "authenticated-model-header")
      (check (equal
              (llm-openrouter-normalize-models
               '("first" "duplicate" "first" "last"))
              '("first" "duplicate" "last"))
             "first-seen-order")
      (check (equal
              (llm-openrouter-normalize-models
               (list "valid" "" 42 (format nil "bad~%id")))
              '("valid"))
             "network-invalid-id-filter")
      (check (llm-models-test-condition-p
              (lambda ()
                (llm-openrouter-normalize-models
                 (list "valid" "") :strict t)))
             "cache-invalid-id-rejection")
      (check (not (llm-openrouter-model-id-valid-p
                   (make-string
                    (1+ *llm-openrouter-model-id-limit*)
                    :initial-element #\x)))
             "model-id-size-bound")
      (check (and (eq (llm-menu-command "m") 'lem-yath-llm-full-menu)
                  (eq (nth-value 0 (llm-full-menu-action "m"))
                      'lem-yath-llm-set-model))
             "compact-to-full-model-dispatch")
      (llm-models-test-log "SUMMARY STATIC ~a failures=~d"
                           (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-llm-models-refresh () ()
  (lem-yath-openrouter-refresh-models)
  (llm-models-test-log "REFRESH requested"))

(define-command lem-yath-test-llm-models-record () ()
  (llm-models-test-log
   "STATE source=~a count=~d values=~a model=~a running=~a timer=~a url=~a auth=~a"
   (string-upcase (symbol-name *llm-openrouter-model-source*))
   (length *llm-openrouter-models*)
   (llm-models-test-values *llm-openrouter-models*)
   *llm-model*
   (if *llm-openrouter-model-refresh-running-p* "yes" "no")
   (if *llm-openrouter-model-refresh-timer* "yes" "no")
   (llm-openrouter-models-url)
   (if (llm-openrouter-model-headers) "yes" "no")))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-models-static)
  (define-key keymap "F3" 'lem-yath-test-llm-models-record)
  (define-key keymap "F4" 'lem-yath-test-llm-models-refresh))

(llm-models-test-log
 "READY source=~a values=~a timer=~a"
 (string-upcase (symbol-name *llm-models-test-initial-source*))
 (llm-models-test-values *llm-models-test-initial-models*)
 (if *llm-models-test-initial-timer-p* "yes" "no"))
