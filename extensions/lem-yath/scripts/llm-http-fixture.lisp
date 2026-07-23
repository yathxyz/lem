(in-package :lem-yath)

(defvar *llm-http-test-report* (uiop:getenv "LEM_YATH_LLM_HTTP_REPORT"))
(defvar *llm-http-test-machine-id* *llm-copilot-machine-id*)

(setf *llm-curl-executable*
      (uiop:getenv "LEM_YATH_LLM_HTTP_CURL")
      *llm-copilot-open-browser* nil)

(defun llm-http-test-log (control &rest arguments)
  (with-open-file (stream *llm-http-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-http-test-buffer-text (name)
  (let ((buffer (get-buffer name)))
    (if (and buffer (not (deleted-buffer-p buffer)))
        (points-to-string (buffer-start-point buffer)
                          (buffer-end-point buffer))
        "")))

(defun llm-http-test-contains-p (name needle)
  (not (null (search needle (llm-http-test-buffer-text name)))))

(defun llm-http-test-mode (pathname)
  #+sbcl (logand (sb-posix:stat-mode
                  (sb-posix:stat (uiop:native-namestring pathname)))
                 #o777)
  #-sbcl 0)

(define-command lem-yath-test-llm-http-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (llm-http-test-log "~a STATIC ~a"
                                  (if condition "PASS" "FAIL") name)
               (unless condition (incf failures))))
      (check (equal (subseq (llm-available-backends) 0 3)
                    '(:openrouter :perplexity :copilot))
             "provider-backend-selection")
      (check (string= (cdr (assoc :perplexity *llm-backend-default-models*))
                      "sonar")
             "perplexity-default-model")
      (check (string= (cdr (assoc :copilot *llm-backend-default-models*))
                      "gpt-4.1")
             "copilot-default-model")
      (check (llm-preset-valid-p
              "perplexity-test"
              '(:backend :perplexity :model "sonar" :system "brief"
                :temperature 0.2 :max-tokens 100 :use-tools nil
                :mcp-servers nil))
             "provider-preset-valid")
      (check (not (llm-preset-valid-p
                   "copilot-tools"
                   '(:backend :copilot :model "gpt-4.1" :system "brief"
                     :temperature 0.2 :max-tokens 100 :use-tools t
                     :mcp-servers nil)))
             "unsupported-tools-refused")
      (let ((presets
              '(("perplexity-test"
                 :backend :perplexity :model "sonar" :system "brief"
                 :temperature 0.2 :max-tokens 100 :use-tools nil
                 :mcp-servers nil)
                ("copilot-test"
                 :backend :copilot :model "gpt-4.1" :system "brief"
                 :temperature 0.2 :max-tokens 100 :use-tools nil
                 :mcp-servers nil))))
        (check
         (handler-case
             (progn
               (call-with-llm-preset-lock
                (lambda () (llm-write-user-presets presets)))
               (let ((saved (llm-read-user-presets)))
                 (and (eq (getf (cdr (assoc "perplexity-test" saved
                                             :test #'string=))
                                 :backend)
                          :perplexity)
                      (eq (getf (cdr (assoc "copilot-test" saved
                                            :test #'string=))
                                :backend)
                          :copilot))))
           (error () nil))
         "provider-preset-roundtrip"))
      (let ((response (llm-json-object
                       "citations"
                       (coerce
                        (loop :for index :below 60
                              :collect (format nil "https://example.test/~d"
                                               index))
                        'vector))))
        (check (= (length (llm-http-response-citations response))
                  *llm-http-citation-count-limit*)
               "bounded-citations"))
      (check (equal (rest (llm-curl-arguments 300 :stream-p t))
                    '("--silent" "--show-error" "--fail-with-body"
                      "--no-buffer" "--max-time" "300" "--config" "-"))
             "secret-free-curl-argv")
      (let ((*llm-backend* :copilot))
        (check (handler-case (progn (lem-yath-llm-new-session) t)
                 (error () nil))
               "http-new-session-safe"))
      (llm-http-test-log "SUMMARY STATIC ~a failures=~d"
                         (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-llm-perplexity () ()
  (setf *llm-backend* :perplexity
        *llm-model* "sonar")
  (llm-backend-stream :perplexity "perplexity prompt"))

(define-command lem-yath-test-copilot-login () ()
  (lem-yath-copilot-login))

(define-command lem-yath-test-llm-copilot () ()
  (setf *llm-backend* :copilot
        *llm-model* "gpt-4.1")
  (llm-backend-stream :copilot "copilot prompt"))

(define-command lem-yath-test-llm-copilot-renew () ()
  (llm-copilot-write-token-object
   :session (llm-json-object "token" "expired-secret" "expires_at" 1))
  (setf *llm-backend* :copilot
        *llm-model* "gpt-4.1")
  (llm-backend-stream :copilot "copilot refresh prompt"))

(define-command lem-yath-test-llm-http-reload () ()
  (let ((source (asdf:system-relative-pathname
                 "lem-yath" "src/apps/llm-http.lisp")))
    (handler-case
        (progn
          (load source)
          (load source)
          (llm-http-test-log
           "RELOAD pass machine=~a method=~a"
           (if (string= *llm-http-test-machine-id* *llm-copilot-machine-id*)
               "stable" "changed")
           (if (compute-applicable-methods
                #'llm-backend-stream (list :copilot "probe"))
               "present" "missing")))
      (error (condition)
        (llm-http-test-log "RELOAD fail ~a" condition)))))

(define-command lem-yath-test-llm-http-record () ()
  (let* ((output (llm-output-buffer))
         (github (llm-copilot-token-pathname :github))
         (session (llm-copilot-token-pathname :session))
         (directory (llm-copilot-cache-directory)))
    (llm-http-test-log
     (concatenate
      'string
      "STATE active=~a perplexity=~a citations=~a copilot1=~a copilot2=~a "
      "login-code=~a login-done=~a github=~a session=~a modes=~3,'0o/~3,'0o/~3,'0o")
     (if (llm-active-request output) "yes" "no")
     (if (llm-http-test-contains-p *llm-buffer-name* "Perplexity answer")
         "yes" "no")
     (if (and (llm-http-test-contains-p *llm-buffer-name* "Citations:")
              (llm-http-test-contains-p *llm-buffer-name*
                                        "https://example.test/two"))
         "yes" "no")
     (if (llm-http-test-contains-p *llm-buffer-name* "Copilot answer 1")
         "yes" "no")
     (if (llm-http-test-contains-p *llm-buffer-name* "Copilot answer 2")
         "yes" "no")
     (if (llm-http-test-contains-p *llm-copilot-login-buffer-name*
                                   "ABCD-EFGH") "yes" "no")
     (if (llm-http-test-contains-p *llm-copilot-login-buffer-name*
                                   "Authorization complete") "yes" "no")
     (if (uiop:file-exists-p github) "yes" "no")
     (if (uiop:file-exists-p session) "yes" "no")
     (if (uiop:directory-exists-p directory)
         (llm-http-test-mode directory) 0)
     (if (uiop:file-exists-p github) (llm-http-test-mode github) 0)
     (if (uiop:file-exists-p session) (llm-http-test-mode session) 0))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-http-static)
  (define-key keymap "F3" 'lem-yath-test-llm-perplexity)
  (define-key keymap "F4" 'lem-yath-test-copilot-login)
  (define-key keymap "F5" 'lem-yath-test-llm-copilot)
  (define-key keymap "F6" 'lem-yath-test-llm-copilot-renew)
  (define-key keymap "F9" 'lem-yath-test-llm-http-reload)
  (define-key keymap "F12" 'lem-yath-test-llm-http-record))

(llm-http-test-log "READY")
