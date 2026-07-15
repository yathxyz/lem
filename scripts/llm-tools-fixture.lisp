(in-package :lem-yath)

(defvar *llm-tools-test-report* (uiop:getenv "LEM_YATH_LLM_TOOLS_REPORT"))
(defvar *llm-tools-test-root*
  (canonical-project-directory (uiop:getenv "LEM_YATH_LLM_TOOLS_PROJECT")))
(defvar *llm-tools-test-source*
  (merge-pathnames "target.lisp" *llm-tools-test-root*))

(setf *llm-curl-executable* (uiop:getenv "LEM_YATH_LLM_TOOLS_CURL"))

(defun llm-tools-test-log (control &rest arguments)
  (with-open-file (stream *llm-tools-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun llm-tools-test-context ()
  (make-llm-tool-context
   :root *llm-tools-test-root*
   :project-request
   (make-live-project-request 0 (capture-project-request-origin))))

(defun llm-tools-test-text ()
  (let ((buffer (llm-output-buffer)))
    (points-to-string (buffer-start-point buffer) (buffer-end-point buffer))))

(defun llm-tools-test-contains-p (needle)
  (not (null (search needle (llm-tools-test-text)))))

(defun llm-tools-test-signals-error-p (function)
  (handler-case (progn (funcall function) nil)
    (error () t)))

(define-command lem-yath-test-llm-tools-static () ()
  (let ((failures 0)
        (context (llm-tools-test-context)))
    (labels ((check (condition name)
               (llm-tools-test-log "~a STATIC ~a"
                                   (if condition "PASS" "FAIL") name)
               (unless condition (incf failures)))
             (invoke (name arguments)
               (llm-invoke-tool context name arguments)))
      (unwind-protect
           (progn
             (let ((names
                     (loop :for definition :across (llm-tool-definitions)
                           :for function := (gethash "function" definition)
                           :collect (gethash "name" function))))
               (check
                (equal names '("project_root" "list_project_files"
                               "search_project" "read_project_file"
                               "read_emacs_symbol"))
                "exact-tool-registry"))
             (let ((*llm-use-tools* nil))
               (let ((body (yason:parse (llm-request-body "quick"))))
                 (check (not (nth-value 1 (gethash "tools" body)))
                        "quick-lookup-tool-free")))
             (let ((*llm-use-tools* t))
               (let* ((body (yason:parse (llm-request-body "agentic")))
                      (tools (gethash "tools" body)))
                 (check (= (length tools) 5) "agentic-schema-body")))
             (check
              (llm-tools-test-signals-error-p
               (lambda () (llm-sse-json "data: {bad")))
              "reject-malformed-sse")
             (check
              (llm-tools-test-signals-error-p
               (lambda ()
                 (llm-stream-tool-call-chunk
                  (make-hash-table)
                  (llm-json-object
                   "index" *llm-max-tool-calls-per-round*))))
              "bound-tool-call-index")
             (check
              (llm-tools-test-signals-error-p
               (lambda ()
                 (llm-stream-tool-call-chunk
                  (make-hash-table)
                  (llm-json-object
                   "index" 0
                   "function"
                   (llm-json-object
                    "arguments"
                    (make-string (1+ *llm-tool-argument-character-limit*)
                                 :initial-element #\x))))))
              "bound-tool-argument-fragments")
             (llm-load-preset "project-readonly")
             (check (and *llm-use-tools*
                         (eq *llm-backend* :openrouter)
                         (= *llm-max-tokens* 4000))
                    "agentic-preset-opt-in")
             (llm-save-preset "tool-enabled-fixture")
             (llm-load-preset "quick-lookup")
             (check (not *llm-use-tools*) "quick-preset-restores-tool-free")
             (llm-load-preset "tool-enabled-fixture")
             (check *llm-use-tools* "persist-tool-enabled-preset")
             (llm-load-preset "quick-lookup")
             (check (string= (invoke "project_root" "{}")
                             (project-native-directory *llm-tools-test-root*))
                    "captured-project-root")
             (let ((listing (invoke "list_project_files"
                                    "{\"glob\":\"*.lisp\"}")))
               (check (and (search "target.lisp" listing)
                           (not (search "notes.txt" listing)))
                      "bounded-glob-file-list"))
             (let ((matches
                     (invoke
                      "search_project"
                      "{\"pattern\":\"TOOL_SENTINEL\",\"glob\":\"*.lisp\"}")))
               (check (and (search "target.lisp:1" matches)
                           (search "TOOL_SENTINEL" matches))
                      "ripgrep-project-search"))
             (let ((read
                     (invoke
                      "read_project_file"
                      "{\"path\":\"long.txt\",\"start_line\":1,\"end_line\":999}")))
               (check (and (search "Showing lines 1-300" read)
                           (search "additional lines omitted" read)
                           (not (search "line-305" read)))
                      "hard-file-line-cap"))
             (check (search "Unsafe project-relative path"
                            (invoke "read_project_file"
                                    "{\"path\":\"../outside/secret.txt\"}"))
                    "reject-lexical-path-escape")
             (check (search "Path escapes project root"
                            (invoke "read_project_file"
                                    "{\"path\":\"escape.txt\"}"))
                    "reject-symlink-path-escape")
             (check (search "TOOL_SENTINEL"
                            (invoke "read_project_file"
                                    "{\"path\":\"inside-link.lisp\"}"))
                    "allow-contained-symlink-target")
             (check (search "Refusing a binary file"
                            (invoke "read_project_file"
                                    "{\"path\":\"binary.dat\"}"))
                    "reject-binary-file")
             (check (search "Tool arguments must be a JSON object"
                            (invoke "project_root" "[]"))
                    "reject-nonobject-arguments")
             (check (search "Unknown tool"
                            (invoke "write_project_file" "{}"))
                    "allowlist-only")
             (let ((symbol
                     (invoke
                      "read_emacs_symbol"
                      "{\"name\":\"LEM-YATH::LLM-REQUEST-BODY\"}")))
               (check (and (search "Function: LEM-YATH::LLM-REQUEST-BODY" symbol)
                           (search "Encode one request" symbol))
                      "lem-symbol-documentation"))
             (let* ((abort-context (llm-tools-test-context))
                    (request
                      (make-llm-request nil nil :openrouter
                                        :tool-context abort-context
                                        :tools-p t)))
               (llm-request-abort-now request)
               (check (not (project-request-live-p
                            (llm-tool-context-project-request abort-context)))
                      "abort-cancels-tool-work")))
        (cancel-project-request (llm-tool-context-project-request context)))
      (llm-tools-test-log "SUMMARY STATIC ~a failures=~d"
                          (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-llm-tools-send () ()
  (find-file *llm-tools-test-source*)
  (llm-load-preset "project-readonly")
  (llm-stream "Inspect this project with the available tools.")
  (llm-tools-test-log "SEND started"))

(define-command lem-yath-test-llm-tools-record () ()
  (let ((buffer (llm-output-buffer)))
    (llm-tools-test-log
     (concatenate
      'string
      "STATE active=~a final=~a root=~a list=~a search=~a read=~a "
      "symbol=~a protocol-error=~a")
     (if (llm-active-request buffer) "yes" "no")
     (if (llm-tools-test-contains-p "Agentic tools complete") "yes" "no")
     (if (llm-tools-test-contains-p
          (project-native-directory *llm-tools-test-root*)) "yes" "no")
     (if (llm-tools-test-contains-p "target.lisp") "yes" "no")
     (if (llm-tools-test-contains-p "TOOL_SENTINEL") "yes" "no")
     (if (llm-tools-test-contains-p "Showing lines 1-2") "yes" "no")
     (if (llm-tools-test-contains-p
          "Function: LEM-YATH::LLM-REQUEST-BODY") "yes" "no")
     (if (llm-tools-test-contains-p "OpenRouter protocol error") "yes" "no"))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-llm-tools-static)
  (define-key keymap "F3" 'lem-yath-test-llm-tools-send)
  (define-key keymap "F12" 'lem-yath-test-llm-tools-record))

(llm-tools-test-log "READY")
