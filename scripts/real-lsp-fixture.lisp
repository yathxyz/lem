(in-package :lem-yath)

;;; Runtime fixture for scripts/real-lsp-test.sh.  This deliberately uses the
;;; configured language modes and specs instead of test doubles.

(defvar *real-lsp-test-report-path*
  (uiop:getenv "LEM_YATH_REAL_LSP_REPORT"))

(defvar *real-lsp-test-fixture-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_REAL_LSP_FIXTURES")))

(defparameter *real-lsp-test-cases*
  (vector
   (list :id "rust"
         :directory "rust/crate/"
         :expected-root "rust/"
         :file "src/main.rs"
         :mode 'lem-rust-mode:rust-mode
         :spec-class 'lem-yath-rust-spec
         :language-id "rust"
         :connection-mode :stdio
         :command '("rust-analyzer")
         :program-environment "LEM_YATH_REAL_LSP_RUST_ANALYZER")
   (list :id "python"
         :directory "python/package/"
         :expected-root "python/"
         :file "main.py"
         :mode 'lem-python-mode:python-mode
         :spec-class 'lem-yath-python-spec
         :language-id "python"
         :connection-mode :stdio
         :command '("pyright-langserver" "--stdio")
         :program-environment "LEM_YATH_REAL_LSP_PYRIGHT"
         :manual t)
   (list :id "nix"
         :directory "nix/flake/"
         :expected-root "nix/"
         :file "default.nix"
         :mode 'lem-nix-mode:nix-mode
         :spec-class 'lem-yath-nix-spec
         :language-id "nix"
         :connection-mode :stdio
         :command '("nixd")
         :program-environment "LEM_YATH_REAL_LSP_NIXD")
   (list :id "markdown"
         :directory "markdown/docs/"
         :expected-root "markdown/"
         :file "README.md"
         :mode 'lem-markdown-mode:markdown-mode
         :spec-class 'lem-yath-markdown-spec
         :language-id "markdown"
         :connection-mode :stdio
         :command '("harper-ls" "--stdio")
         :program-environment "LEM_YATH_REAL_LSP_HARPER")
   (list :id "csharp"
         :directory "csharp/app/"
         :expected-root "csharp/"
         :file "Main.cs"
         :mode 'csharp-mode
         :spec-class 'lem-yath-csharp-spec
         :language-id "csharp"
         :connection-mode :stdio
         :command '("csharp-ls")
         :program-environment "LEM_YATH_REAL_LSP_CSHARP")
   (list :id "java"
         :directory "java/"
         :file "src/main/java/example/Main.java"
         :mode 'lem-java-mode:java-mode
         :spec-class 'lem-yath-java-spec
         :language-id "java"
         :connection-mode :stdio
         :command '("jdtls")
         :program-environment "LEM_YATH_REAL_LSP_JDTLS"
         :manual t)
   (list :id "go"
         :directory "go/module/"
         :expected-root "go/"
         :file "main.go"
         :mode 'lem-go-mode:go-mode
         :spec-class 'lem-yath-go-spec
         :language-id "go"
         :connection-mode :stdio
         :command '("gopls")
         :program-environment "LEM_YATH_REAL_LSP_GOPLS")
   (list :id "terraform"
         :directory "terraform/environment/"
         :expected-root "terraform/"
         :file "main.tf"
         :mode 'lem-terraform-mode:terraform-mode
         :spec-class 'lem-yath-terraform-spec
         :language-id "terraform"
         :connection-mode :stdio
         :command '("terraform-ls" "serve")
         :program-environment "LEM_YATH_REAL_LSP_TERRAFORM_LS")))

(defparameter *real-lsp-test-prerequisites*
  '(("rust-analyzer" . "LEM_YATH_REAL_LSP_RUST_ANALYZER")
    ("pyright-langserver" . "LEM_YATH_REAL_LSP_PYRIGHT")
    ("harper-ls" . "LEM_YATH_REAL_LSP_HARPER")
    ("csharp-ls" . "LEM_YATH_REAL_LSP_CSHARP")
    ("nixd" . "LEM_YATH_REAL_LSP_NIXD")
    ("jdtls" . "LEM_YATH_REAL_LSP_JDTLS")
    ("gopls" . "LEM_YATH_REAL_LSP_GOPLS")
    ("terraform-ls" . "LEM_YATH_REAL_LSP_TERRAFORM_LS")
    ("cargo" . "LEM_YATH_REAL_LSP_CARGO")
    ("rustc" . "LEM_YATH_REAL_LSP_RUSTC")
    ("cargo-clippy" . "LEM_YATH_REAL_LSP_CARGO_CLIPPY")))

(defstruct real-lsp-test-current
  case
  buffer
  workspace
  client
  pid
  configuration-count
  manual-clean-p
  watchdog)

(defvar *real-lsp-test-next-case-index* 0)
(defvar *real-lsp-test-current* nil)

;; JSON-RPC registers the function designator, so this wrapper records real
;; server requests without replacing the production response implementation.
(defvar *real-lsp-test-workspace-configuration-count* 0)
(defvar *real-lsp-test-workspace-configuration-original*
  (symbol-function 'lem-lsp-mode::workspace/configuration))

(defun real-lsp-test-workspace-configuration (params)
  (incf *real-lsp-test-workspace-configuration-count*)
  (funcall *real-lsp-test-workspace-configuration-original* params))

(setf (symbol-function 'lem-lsp-mode::workspace/configuration)
      #'real-lsp-test-workspace-configuration)

(defun real-lsp-test-report (control &rest arguments)
  (with-open-file (stream *real-lsp-test-report-path*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun real-lsp-test-yes-no (value)
  (if value "yes" "no"))

(defun real-lsp-test-safe-token (value)
  (let ((text (princ-to-string value)))
    (map 'string
         (lambda (character)
           (if (member character '(#\Space #\Tab #\Newline #\Return))
               #\_
               character))
         text)))

(defun real-lsp-test-which (program)
  (handler-case
      (uiop:run-program (list "which" program)
                        :output '(:string :stripped t)
                        :error-output nil)
    (error () nil)))

(defun real-lsp-test-canonical-path (path)
  (and path
       (ignore-errors (namestring (truename path)))))

(defun real-lsp-test-program-state (program environment-variable)
  (let* ((resolved (real-lsp-test-which program))
         (expected (uiop:getenv environment-variable))
         (resolved-canonical (real-lsp-test-canonical-path resolved))
         (expected-canonical (real-lsp-test-canonical-path expected)))
    (values (and resolved-canonical
                 expected-canonical
                 (string= resolved-canonical expected-canonical))
            (or resolved "none")
            (or expected "none"))))

(defun real-lsp-test-report-prerequisites ()
  (dolist (entry *real-lsp-test-prerequisites*)
    (multiple-value-bind (ok resolved expected)
        (real-lsp-test-program-state (car entry) (cdr entry))
      (real-lsp-test-report
       "PREREQ name=~a ok=~a resolved=~a expected=~a"
       (car entry)
       (real-lsp-test-yes-no ok)
       (real-lsp-test-safe-token resolved)
       (real-lsp-test-safe-token expected)))))

(defun real-lsp-test-case-root (case)
  (merge-pathnames (getf case :directory) *real-lsp-test-fixture-root*))

(defun real-lsp-test-case-expected-root (case)
  (merge-pathnames (or (getf case :expected-root)
                       (getf case :directory))
                   *real-lsp-test-fixture-root*))

(defun real-lsp-test-case-file (case)
  (merge-pathnames (getf case :file) (real-lsp-test-case-root case)))

(defun real-lsp-test-command-line-file-p ()
  (let* ((case (aref *real-lsp-test-cases* 0))
         (buffer (current-buffer)))
    (and (buffer-filename buffer)
         (uiop:pathname-equal (real-lsp-test-case-file case)
                              (buffer-filename buffer))
         (eq (getf case :mode) (buffer-major-mode buffer)))))

(defun real-lsp-test-command-line-workspace-p ()
  (and (real-lsp-test-command-line-file-p)
       (buffer-value (current-buffer) 'lem-lsp-mode::lsp-workspace)))

(defun real-lsp-test-lem-home-restored-p ()
  (let ((expected (uiop:getenv "LEM_YATH_REAL_LSP_EXPECTED_LEM_HOME")))
    (and expected
         (uiop:pathname-equal (uiop:ensure-directory-pathname expected)
                              (uiop:ensure-directory-pathname (lem-home))))))

(defun real-lsp-test-client-pid (client)
  (etypecase client
    (lem-lsp-mode/client:stdio-client
     (uiop:process-info-pid
      (lem-lsp-mode/client::stdio-client-process client)))
    (lem-lsp-mode/client:tcp-client
     (let ((process (lem-lsp-mode/client::tcp-client-process client)))
       (unless process
         (error "TCP language-server client has no process"))
       (async-process::process-pid
        (lem-process::process-pointer process))))))

(defun real-lsp-test-spec-command (spec connection-mode)
  (if (eq connection-mode :tcp)
      (lem-lsp-mode/spec:get-spec-command spec 41357)
      (lem-lsp-mode/spec:get-spec-command spec)))

(defun real-lsp-test-expected-client-p (client connection-mode)
  (ecase connection-mode
    (:stdio (typep client 'lem-lsp-mode/client:stdio-client))
    (:tcp (typep client 'lem-lsp-mode/client:tcp-client))))

(defun real-lsp-test-workspace-configuration-capability-p ()
  (let* ((capabilities (lem-lsp-mode::client-capabilities))
         (workspace (lsp:client-capabilities-workspace capabilities)))
    (eq t (lsp:workspace-client-capabilities-configuration workspace))))

(defun real-lsp-test-stop-watchdog (current)
  (alexandria:when-let ((watchdog (real-lsp-test-current-watchdog current)))
    (ignore-errors (stop-timer watchdog))
    (setf (real-lsp-test-current-watchdog current) nil)))

(defun real-lsp-test-watch-startup (current)
  (when (and (eq current *real-lsp-test-current*)
             (eq :starting
                 (lem-lsp-mode::workspace-state
                  (real-lsp-test-current-workspace current)))
             (not (ignore-errors
                    (lem-lsp-mode/client:alive-p
                     (real-lsp-test-current-client current)))))
    (real-lsp-test-stop-watchdog current)
    (real-lsp-test-report
     "FAIL id=~a phase=initialize error=server-process-exited"
     (getf (real-lsp-test-current-case current) :id))))

(defun real-lsp-test-initialization-option-failures (case workspace)
  "Return failed assertions for the options frozen into WORKSPACE at launch."
  (let ((id (getf case :id))
        (options (lem-lsp-mode::workspace-initialization-options workspace))
        (failures '()))
    (flet ((check (condition label)
             (unless condition (push label failures))))
      (cond
        ((string= id "nix")
         (check (hash-table-p options) "nix-options-map")
         (when (hash-table-p options)
           (let* ((root (nixd-flake-root))
                  (nixpkgs (gethash "nixpkgs" options))
                  (formatting (gethash "formatting" options))
                  (option-sources (gethash "options" options)))
             (check (hash-table-p nixpkgs) "nix-nixpkgs-map")
             (when (hash-table-p nixpkgs)
               (check (string=
                       (format nil
                               "import (builtins.getFlake \"~a\").inputs.nixpkgs { }"
                               root)
                               (gethash "expr" nixpkgs ""))
                      "nix-nixpkgs-expr"))
             (check (hash-table-p formatting) "nix-formatting-map")
             (when (hash-table-p formatting)
               (check (equalp #("nixfmt")
                              (gethash "command" formatting))
                      "nix-formatter-command"))
             (check (hash-table-p option-sources) "nix-option-sources-map")
             (when (hash-table-p option-sources)
               (dolist (source '(("nixos" . "nixosConfigurations.nova.options")
                                 ("home-manager" .
                                  "homeConfigurations.yanni.options")))
                 (let ((entry (gethash (car source) option-sources)))
                   (check (hash-table-p entry)
                          (format nil "nix-~a-map" (car source)))
                   (when (hash-table-p entry)
                     (check
                      (string=
                       (format nil "(builtins.getFlake \"~a\").~a"
                               root (cdr source))
                       (gethash "expr" entry ""))
                      (format nil "nix-~a-expr" (car source))))))))))
        ((string= id "java")
         (check (hash-table-p options) "java-options-map")
         (when (hash-table-p options)
           (let* ((settings (gethash "settings" options))
                  (java (and (hash-table-p settings)
                             (gethash "java" settings)))
                  (format-options (and (hash-table-p java)
                                       (gethash "format" java)))
                  (format-settings (and (hash-table-p format-options)
                                        (gethash "settings" format-options))))
             (check (hash-table-p settings) "java-settings-map")
             (check (hash-table-p java) "java-language-map")
             (check (hash-table-p format-options) "java-format-map")
             (when (hash-table-p format-options)
               (check (eq t (gethash "enabled" format-options))
                      "java-format-enabled"))
             (check (hash-table-p format-settings)
                    "java-format-settings-map")
             (when (hash-table-p format-settings)
               (check (string= *java-google-style-url*
                               (gethash "url" format-settings ""))
                      "java-google-style-url")))))
        (t
         (check (null options) "unexpected-initialization-options"))))
    (nreverse failures)))

(defun real-lsp-test-record-ready (current)
  (real-lsp-test-stop-watchdog current)
  (handler-case
      (let* ((case (real-lsp-test-current-case current))
             (id (getf case :id))
             (buffer (real-lsp-test-current-buffer current))
             (workspace (real-lsp-test-current-workspace current))
             (client (real-lsp-test-current-client current))
             (spec (lem-lsp-mode::workspace-spec workspace))
             (expected-mode (getf case :mode))
             (expected-root
               (truename (real-lsp-test-case-expected-root case)))
             (connection-mode (getf case :connection-mode))
             (command (real-lsp-test-spec-command spec connection-mode))
             (program (first command))
             (failures
               (real-lsp-test-initialization-option-failures case workspace)))
        (flet ((check (condition label)
                 (unless condition (push label failures))))
          (check (eq expected-mode (buffer-major-mode buffer)) "major-mode")
          (check (eq expected-mode (lem-lsp-mode/spec:spec-mode spec))
                 "spec-mode")
          (check (typep spec (getf case :spec-class)) "spec-class")
          (check (eq spec
                     (lem-lsp-mode/spec:get-language-spec expected-mode))
                 "registered-spec")
          (check (string= (getf case :language-id)
                          (lem-lsp-mode/spec:spec-language-id spec))
                 "language-id")
          (check (eq connection-mode
                     (lem-lsp-mode/spec:spec-connection-mode spec))
                 "connection-mode")
          (check (equal (getf case :command) command) "command")
          (multiple-value-bind (program-ok resolved expected)
              (real-lsp-test-program-state
               program (getf case :program-environment))
            (declare (ignore resolved expected))
            (check program-ok "program-path"))
          (check (uiop:pathname-equal
                  expected-root
                  (lem-lsp-mode::workspace-root-pathname workspace))
                 "root-pathname")
          (check (string= (lem-lsp-base/utils:pathname-to-uri expected-root)
                          (lem-lsp-mode::workspace-root-uri workspace))
                 "root-uri")
          (check (eq :ready (lem-lsp-mode::workspace-state workspace))
                 "workspace-state")
          (check (eq workspace
                     (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
                 "raw-ownership")
          (check (eq workspace (lem-lsp-mode::buffer-workspace buffer nil))
                 "buffer-workspace")
          (check (eq :open (buffer-value buffer 'lem-lsp-mode::lsp-state))
                 "buffer-state")
          (check (equal (lem-lsp-mode::buffer-opened-uri buffer)
                        (lem-lsp-mode::buffer-uri buffer))
                 "opened-uri")
          (check (lem-lsp-mode::workspace-response-current-p workspace buffer)
                 "response-current")
          (check (member buffer (lem-lsp-mode::workspace-buffers workspace)
                         :test #'eq)
                 "workspace-buffer")
          (check (real-lsp-test-expected-client-p client connection-mode)
                 "client-class")
          ;; ALIVE-P is safe before disposal.  The async-process library frees
          ;; its process pointer during disposal, so post-disposal proof uses
          ;; the captured OS PID in the shell driver instead.
          (check (lem-lsp-mode/client:alive-p client) "client-alive")
          (check (real-lsp-test-workspace-configuration-capability-p)
                 "workspace-configuration-capability")
          (check (lem-lsp-mode::workspace-server-capabilities workspace)
                 "server-capabilities")
          (check (null (lem-lsp-mode::workspace-initialization-timer workspace))
                 "initialization-timer")
          (check (null (lem-lsp-mode::workspace-startup-spinner workspace))
                 "startup-spinner")
          (check (not (mode-active-p buffer 'lem-yath-lint-mode))
                 "lint-disabled")
          (when (getf case :manual)
            (check (real-lsp-test-current-manual-clean-p current)
                   "manual-start-clean"))
          (when (string= id "java")
            (check (uiop:directory-exists-p
                    (java-jdtls-data-pathname expected-root))
                   "jdtls-data-directory")))
        (let ((pid (real-lsp-test-client-pid client)))
          (setf (real-lsp-test-current-pid current) pid)
          (real-lsp-test-report
           (concatenate
            'string
            "READY id=~a ok=~a pid=~d mode=~a spec=~a language=~a "
            "transport=~a root=~a state=~a opened=~a client-alive=~a "
            "failures=~{~a~^,~}")
           id
           (real-lsp-test-yes-no (null failures))
           pid
           (buffer-major-mode buffer)
           (class-name (class-of spec))
           (lem-lsp-mode/spec:spec-language-id spec)
           (lem-lsp-mode/spec:spec-connection-mode spec)
           (namestring (lem-lsp-mode::workspace-root-pathname workspace))
           (lem-lsp-mode::workspace-state workspace)
           (buffer-value buffer 'lem-lsp-mode::lsp-state)
           (real-lsp-test-yes-no
            (lem-lsp-mode/client:alive-p client))
           (nreverse failures))))
    (error (condition)
      (real-lsp-test-report
       "FAIL id=~a phase=ready error=~a"
       (getf (real-lsp-test-current-case current) :id)
       (real-lsp-test-safe-token condition)))))

(defun real-lsp-test-start-case (case)
  (handler-case
      (let* ((buffer (find-file-buffer (real-lsp-test-case-file case)))
             (manual-p (getf case :manual))
             (workspace-before
               (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
             (manual-clean-p
               (or (not manual-p)
                   (and (null workspace-before)
                        (not (mode-active-p
                              buffer 'lem-lsp-mode::lsp-mode))))))
        (switch-to-buffer buffer)
        (when manual-p
          (if (string= (getf case :id) "java")
              (lem-yath-java-lsp)
              (with-current-buffer buffer
                (lem-lsp-mode::lsp-mode t))))
        (let* ((workspace
                 (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
               (client (and workspace
                            (lem-lsp-mode::workspace-client workspace))))
          (unless workspace
            (let* ((mode (buffer-major-mode buffer))
                   (hook-variable (mode-hook-variable mode))
                   (hook-value (and hook-variable
                                    (symbol-value hook-variable))))
              (error
               (concatenate
                'string
                "Opening or explicitly enabling the fixture did not attach "
                "an LSP workspace (mode=~s spec=~s lsp=~s hook=~s "
                "entries=~s disabled=~s)")
               mode
               (lem-lsp-mode::buffer-language-spec buffer)
               (mode-active-p buffer 'lem-lsp-mode::lsp-mode)
               hook-variable
               hook-value
               lem-lsp-mode::*disable*)))
          (let* ((pid (real-lsp-test-client-pid client))
                 (current
                   (make-real-lsp-test-current
                    :case case
                    :buffer buffer
                    :workspace workspace
                    :client client
                    :pid pid
                    :configuration-count
                    *real-lsp-test-workspace-configuration-count*
                    :manual-clean-p manual-clean-p)))
            (setf *real-lsp-test-current* current)
            (setf (real-lsp-test-current-watchdog current)
                  (start-timer
                   (make-timer
                    (lambda () (real-lsp-test-watch-startup current))
                    :name "real-lsp-startup-watchdog")
                   250
                   :repeat t))
            (real-lsp-test-report
             "START id=~a pid=~d state=~a"
             (getf case :id)
             pid
             (lem-lsp-mode::workspace-state workspace))
            (case (lem-lsp-mode::workspace-state workspace)
              (:ready
               (real-lsp-test-record-ready current))
              (:starting
               (lem-lsp-mode::queue-workspace-continuation
                workspace
                buffer
                (lambda ()
                  (when (eq current *real-lsp-test-current*)
                    (real-lsp-test-record-ready current)))))
              (otherwise
               (error "Workspace entered unexpected state ~S"
                      (lem-lsp-mode::workspace-state workspace)))))))
    (error (condition)
      (real-lsp-test-report
       "FAIL id=~a phase=start error=~a"
       (getf case :id)
       (real-lsp-test-safe-token condition)))))

(define-command lem-yath-test-real-lsp-start-next () ()
  (when *real-lsp-test-current*
    (editor-error "Record shutdown before starting the next LSP fixture."))
  (when (>= *real-lsp-test-next-case-index*
            (length *real-lsp-test-cases*))
    (editor-error "All real LSP fixtures have already run."))
  (let ((case (aref *real-lsp-test-cases*
                    *real-lsp-test-next-case-index*)))
    (incf *real-lsp-test-next-case-index*)
    (real-lsp-test-start-case case)))

(define-command lem-yath-test-real-lsp-record-shutdown () ()
  (unless *real-lsp-test-current*
    (editor-error "No real LSP fixture is active."))
  (let* ((current *real-lsp-test-current*)
         (case (real-lsp-test-current-case current))
         (id (getf case :id))
         (buffer (real-lsp-test-current-buffer current))
         (workspace (real-lsp-test-current-workspace current))
         (spec (lem-lsp-mode::workspace-spec workspace))
         (failures '()))
    (flet ((check (condition label)
             (unless condition (push label failures))))
      (check (eq :disposed (lem-lsp-mode::workspace-state workspace))
             "workspace-state")
      (check (null (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
             "raw-ownership")
      (check (null (buffer-value buffer 'lem-lsp-mode::lsp-state))
             "buffer-state")
      (check (null (lem-lsp-mode::buffer-opened-uri buffer)) "opened-uri")
      (check (not (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
             "lsp-mode")
      (check (null (lem-lsp-mode::find-workspace-for-buffer spec buffer))
             "workspace-table")
      (check (not (member workspace (lem-lsp-mode::all-workspaces)
                          :test #'eq))
             "workspace-registry")
      (check (null (lem-lsp-mode::workspace-initialization-timer workspace))
             "initialization-timer")
      (check (null (lem-lsp-mode::workspace-startup-spinner workspace))
             "startup-spinner")
      (when (programming-buffer-p buffer)
        (check (mode-active-p buffer 'lem-yath-lint-mode)
               "lint-restored")
        (check (null (buffer-value buffer 'lem-yath-lint-was-enabled))
               "lint-restore-state")))
    (real-lsp-test-report
     (concatenate
      'string
      "SHUTDOWN id=~a ok=~a pid=~d state=~a owned=~a lsp=~a "
      "registered=~a failures=~{~a~^,~}")
     id
     (real-lsp-test-yes-no (null failures))
     (real-lsp-test-current-pid current)
     (lem-lsp-mode::workspace-state workspace)
     (real-lsp-test-yes-no
      (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
     (real-lsp-test-yes-no
      (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
     (real-lsp-test-yes-no
      (member workspace (lem-lsp-mode::all-workspaces) :test #'eq))
     (nreverse failures))
    (setf *real-lsp-test-current* nil)))

(define-command lem-yath-test-real-lsp-record-stable () ()
  (unless *real-lsp-test-current*
    (editor-error "No real LSP fixture is active."))
  (let* ((current *real-lsp-test-current*)
         (case (real-lsp-test-current-case current))
         (id (getf case :id))
         (buffer (real-lsp-test-current-buffer current))
         (workspace (real-lsp-test-current-workspace current))
         (client (real-lsp-test-current-client current))
         (configuration-count
           (- *real-lsp-test-workspace-configuration-count*
              (real-lsp-test-current-configuration-count current)))
         (failures '()))
    (when (string= id "csharp")
      (maybe-pull-current-buffer-diagnostics))
    (flet ((check (condition label)
             (unless condition (push label failures))))
      (check (eq :ready (lem-lsp-mode::workspace-state workspace))
             "workspace-state")
      (check (eq workspace (lem-lsp-mode::buffer-workspace buffer nil))
             "buffer-workspace")
      (check (lem-lsp-mode/client:alive-p client) "client-alive")
      (when (string= id "csharp")
        (check (plusp (length (lem-lsp-mode::buffer-diagnostic-overlays buffer)))
               "csharp-diagnostics"))
      (when (string= id "markdown")
        (check (plusp configuration-count)
               "workspace-configuration-request")))
    (real-lsp-test-report
     (concatenate
      'string
      "STABLE id=~a ok=~a state=~a client-alive=~a diagnostics=~d "
      "pull-provider=~a pull-last=~a pull-in-flight=~a "
      "configuration-requests=~d failures=~{~a~^,~}")
     id
     (real-lsp-test-yes-no (null failures))
     (lem-lsp-mode::workspace-state workspace)
     (real-lsp-test-yes-no (lem-lsp-mode/client:alive-p client))
     (length (lem-lsp-mode::buffer-diagnostic-overlays buffer))
     (real-lsp-test-yes-no (workspace-pull-diagnostics-p workspace))
     (or (buffer-value buffer 'lem-yath-pull-diagnostics-last-tick) "none")
     (real-lsp-test-yes-no
      (buffer-value buffer 'lem-yath-pull-diagnostics-in-flight))
     configuration-count
     (nreverse failures))))

(real-lsp-test-report-prerequisites)
(real-lsp-test-report
 "FIXTURE ready=yes boot=~a cases=~d command-line-file=~a command-line-workspace=~a lem-home=~a caller-evals=~a"
 (real-lsp-test-yes-no (boot-ok-p))
 (length *real-lsp-test-cases*)
 (real-lsp-test-yes-no (real-lsp-test-command-line-file-p))
 (real-lsp-test-yes-no (real-lsp-test-command-line-workspace-p))
 (real-lsp-test-yes-no (real-lsp-test-lem-home-restored-p))
 (real-lsp-test-yes-no
  (string= "yes" (or (uiop:getenv "LEM_YATH_REAL_LSP_EVAL_ONE") ""))))
