(in-package :lem-yath)

(defvar *gdscript-test-report*
  (uiop:getenv "LEM_YATH_GDSCRIPT_TEST_REPORT"))

(defun gdscript-test-yes-no (value)
  (if value "yes" "no"))

(defun gdscript-test-attribute (buffer text)
  (with-point ((point (buffer-start-point buffer)))
    (when (search-forward-regexp point (cl-ppcre:quote-meta-chars text))
      (character-offset point (- (length text)))
      (text-property-at point :attribute))))

(define-command lem-yath-gdscript-test-report () ()
  (let* ((buffer (current-buffer))
         (workspace
           (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
         (spec (lem-lsp-mode/spec:get-language-spec 'gdscript-mode))
         (client (and workspace (lem-lsp-mode::workspace-client workspace)))
         (phase (or (uiop:getenv "LEM_YATH_GDSCRIPT_TEST_PHASE") "unknown")))
    (lem-core::syntax-scan-buffer buffer)
    (with-open-file (stream *gdscript-test-report*
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (format
       stream
       "STATE phase=~a mode=~a programming=~a tabs=~a width=~d comment=~a grammar=~a function-face=~a spec=~a connection=~a command=~a configured-port=~d default-port=~d lsp=~a workspace=~a state=~a client=~a child=~a root=~a~%"
       phase
       (buffer-major-mode buffer)
       (gdscript-test-yes-no (programming-buffer-p buffer))
       (gdscript-test-yes-no (variable-value 'indent-tabs-mode
                                              :buffer buffer))
       (variable-value 'tab-width :buffer buffer)
       (variable-value 'lem/language-mode:line-comment :buffer buffer)
       (or (expand-region-tree-sitter-language buffer) "none")
       (or (gdscript-test-attribute buffer "ready") "none")
       (class-name (class-of spec))
       (lem-lsp-mode/spec:spec-connection-mode spec)
       (lem-lsp-mode/spec:get-spec-command spec)
       (godot-language-server-port)
       (godot-language-server-port (user-homedir-pathname))
       (gdscript-test-yes-no
        (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
       (gdscript-test-yes-no workspace)
       (if workspace (lem-lsp-mode::workspace-state workspace) "none")
       (if client (class-name (class-of client)) "none")
       (gdscript-test-yes-no
        (and client
             (typep client 'lem-lsp-mode/client:tcp-client)
             (lem-lsp-mode/client::tcp-client-process client)))
       (if workspace
           (namestring (lem-lsp-mode::workspace-root-pathname workspace))
           "none")))))
