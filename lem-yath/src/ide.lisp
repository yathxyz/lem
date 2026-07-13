;;;; IDE layer: eglot -> lem-lsp-mode, with the same language servers the
;;;; Emacs config used. Lem ships working specs for go (gopls) and
;;;; terraform; rust/nix have no active spec and python defaults to pylsp,
;;;; so we (re)register specs to match the Emacs setup:
;;;;   rust -> rust-analyzer, nix -> nixd (+ flake-aware settings),
;;;;   python -> pyright, markdown -> harper-ls (prose linting),
;;;;   C# -> csharp-ls.
;;;; Java remains explicit, matching eglot-java-mode in the Emacs config.

(in-package :lem-yath)

(lem-lsp-mode:define-language-spec (lem-yath-rust-spec lem-rust-mode:rust-mode)
  :language-id "rust"
  :root-uri-patterns '("Cargo.toml")
  :command '("rust-analyzer")
  :install-command "nix profile install nixpkgs#rust-analyzer"
  :readme-url "https://rust-analyzer.github.io/"
  :connection-mode :stdio)

(lem-lsp-mode:define-language-spec (lem-yath-python-spec lem-python-mode:python-mode)
  :language-id "python"
  :root-uri-patterns '("pyproject.toml" "setup.py" "requirements.txt" "poetry.lock")
  :command '("pyright-langserver" "--stdio")
  :install-command "nix profile install nixpkgs#pyright"
  :readme-url "https://github.com/microsoft/pyright"
  :connection-mode :stdio)

(lem-lsp-mode:define-language-spec (lem-yath-markdown-spec lem-markdown-mode:markdown-mode)
  :language-id "markdown"
  :root-uri-patterns '(".git")
  :command '("harper-ls" "--stdio")
  :install-command "nix profile install nixpkgs#harper"
  :readme-url "https://writewithharper.com/"
  :connection-mode :stdio)

(lem-lsp-mode:define-language-spec (lem-yath-csharp-spec csharp-mode)
  :language-id "csharp"
  :root-uri-patterns '(".sln" ".csproj" ".git")
  :command '("csharp-ls")
  :install-command "nix profile install nixpkgs#csharp-ls"
  :readme-url "https://github.com/razzmatazz/csharp-language-server"
  :connection-mode :stdio)

;;; --- LSP 3.17 pull diagnostics ------------------------------------------

(defvar *pull-diagnostics-idle-timer* nil)

(defparameter *csharp-initial-empty-diagnostic-retries* 60)

(defun csharp-pull-diagnostics-p (workspace)
  (typep (lem-lsp-mode::workspace-spec workspace) 'lem-yath-csharp-spec))

(defun workspace-pull-diagnostics-p (workspace)
  (handler-case
      (not (null
            (lsp:server-capabilities-diagnostic-provider
             (lem-lsp-mode::workspace-server-capabilities workspace))))
    (unbound-slot () nil)))

(defun invalidate-pull-diagnostics (workspace)
  (dolist (buffer (lem-lsp-mode::workspace-buffers workspace))
    (incf (buffer-value buffer 'lem-yath-pull-diagnostics-generation 0))
    (setf (buffer-value buffer 'lem-yath-pull-diagnostics-last-tick) nil
          (buffer-value buffer 'lem-yath-pull-diagnostics-empty-retries) 0)))

(defun pull-diagnostics-refresh (workspace params)
  (declare (ignore params))
  (send-event (lambda () (invalidate-pull-diagnostics workspace)))
  lem-lsp-base/type:+null+)

(defmethod lem-lsp-mode::initialized-workspace :after
    ((mode lem/language-mode:language-mode) workspace)
  (declare (ignore mode))
  (when (workspace-pull-diagnostics-p workspace)
    (lem-lsp-mode:register-lsp-method
     workspace
     "workspace/diagnostic/refresh"
     (lambda (params) (pull-diagnostics-refresh workspace params)))))

(defun pull-diagnostics-result-id (response)
  (handler-case
      (etypecase response
        (lsp:full-document-diagnostic-report
         (lsp:full-document-diagnostic-report-result-id response))
        (lsp:unchanged-document-diagnostic-report
         (lsp:unchanged-document-diagnostic-report-result-id response)))
    (unbound-slot () nil)))

(defun apply-pulled-diagnostics (workspace buffer tick generation response)
  (let ((token (buffer-value buffer 'lem-yath-pull-diagnostics-in-flight)))
    (when (equal token (list workspace tick generation))
      (setf (buffer-value buffer 'lem-yath-pull-diagnostics-in-flight) nil)
      (when (and (member buffer (buffer-list) :test #'eq)
                 (= tick (buffer-modified-tick buffer))
                 (= generation
                    (buffer-value buffer
                                  'lem-yath-pull-diagnostics-generation 0))
                 (lem-lsp-mode::workspace-response-current-p workspace buffer))
        (typecase response
          (lsp:full-document-diagnostic-report
           (let ((diagnostics
                   (lsp:full-document-diagnostic-report-items response)))
             (lem-lsp-mode::highlight-diagnostics
              workspace
              (make-instance
               'lsp:publish-diagnostics-params
               :uri (lem-lsp-mode::buffer-uri buffer)
               :diagnostics diagnostics))
             ;; csharp-ls loads Roslyn projects after initialize and can return
             ;; empty reports without sending diagnostic/refresh. Retry that
             ;; initial state boundedly and force a fresh computation.
             (if (and (csharp-pull-diagnostics-p workspace)
                      (zerop (length diagnostics))
                      (< (buffer-value
                          buffer 'lem-yath-pull-diagnostics-empty-retries 0)
                         *csharp-initial-empty-diagnostic-retries*))
                 (progn
                   (incf (buffer-value
                          buffer 'lem-yath-pull-diagnostics-empty-retries 0))
                   (setf (buffer-value
                          buffer 'lem-yath-pull-diagnostics-last-tick) nil
                         (buffer-value
                          buffer 'lem-yath-pull-diagnostics-result-id) nil))
                 (setf (buffer-value
                        buffer 'lem-yath-pull-diagnostics-last-tick) tick
                       (buffer-value
                        buffer 'lem-yath-pull-diagnostics-empty-retries) 0
                       (buffer-value
                        buffer 'lem-yath-pull-diagnostics-result-id)
                       (pull-diagnostics-result-id response)))))
          (lsp:unchanged-document-diagnostic-report nil))
        (when (typep response 'lsp:unchanged-document-diagnostic-report)
          (setf (buffer-value buffer 'lem-yath-pull-diagnostics-last-tick) tick
                (buffer-value buffer 'lem-yath-pull-diagnostics-result-id)
                (pull-diagnostics-result-id response)))))))

(defun finish-failed-pull-diagnostics (buffer token)
  (when (and (member buffer (buffer-list) :test #'eq)
             (equal token
                    (buffer-value buffer 'lem-yath-pull-diagnostics-in-flight)))
    (setf (buffer-value buffer 'lem-yath-pull-diagnostics-in-flight) nil
          (buffer-value buffer 'lem-yath-pull-diagnostics-last-tick)
          (second token))))

(defun request-pull-diagnostics (workspace buffer)
  (let* ((tick (buffer-modified-tick buffer))
         (generation
           (buffer-value buffer 'lem-yath-pull-diagnostics-generation 0))
         (token (list workspace tick generation))
         (result-id
           (buffer-value buffer 'lem-yath-pull-diagnostics-result-id)))
    (setf (buffer-value buffer 'lem-yath-pull-diagnostics-in-flight) token)
    (lem-language-client/request:request-async
     (lem-lsp-mode::workspace-client workspace)
     (make-instance 'lsp:text-document/diagnostic)
     (apply #'make-instance
            'lsp:document-diagnostic-params
            :text-document
            (lem-lsp-mode::make-text-document-identifier buffer)
            (when result-id (list :previous-result-id result-id)))
     (lambda (response)
       (send-event
        (lambda ()
          (apply-pulled-diagnostics
           workspace buffer tick generation response))))
     (lambda (message code)
       (declare (ignore message code))
       (send-event
        (lambda () (finish-failed-pull-diagnostics buffer token)))))))

(defun maybe-pull-current-buffer-diagnostics ()
  (let* ((buffer (current-buffer))
         (workspace (and (mode-active-p buffer 'lem-lsp-mode::lsp-mode)
                         (lem-lsp-mode::buffer-workspace buffer nil)))
         (tick (buffer-modified-tick buffer)))
    (when (and workspace
               (workspace-pull-diagnostics-p workspace)
               (not (buffer-value buffer 'lem-yath-pull-diagnostics-in-flight))
               (not (eql tick
                         (buffer-value
                          buffer 'lem-yath-pull-diagnostics-last-tick))))
      (request-pull-diagnostics workspace buffer))))

(defun ensure-pull-diagnostics-idle-timer ()
  (unless (and *pull-diagnostics-idle-timer*
               (not (timer-expired-p *pull-diagnostics-idle-timer*)))
    (setf *pull-diagnostics-idle-timer*
          (start-timer
           (make-idle-timer 'maybe-pull-current-buffer-diagnostics
                            :name "lem-yath-pull-diagnostics")
           500
           :repeat t))))

(initialize-editor-feature 'ensure-pull-diagnostics-idle-timer)

;;; --- nixd, replicating yath/nixd-workspace-configuration -------------------

(defparameter *nixd-known-flake-option-sources*
  (let ((root (ignore-errors
                (truename (merge-pathnames "proj/nix/computer"
                                           (user-homedir-pathname))))))
    (when root
      (list (list (string-right-trim "/" (namestring root))
                  '("nixos" . "nixosConfigurations.nova.options")
                  '("home-manager" . "homeConfigurations.yanni.options")))))
  "Flake roots with extra nixd option sources, as in the Emacs config.")

(defun nixd-flake-root ()
  (let ((dir (ignore-errors (buffer-directory (current-buffer)))))
    (alexandria:when-let ((root (and dir (find-up dir "flake.nix"))))
      (string-right-trim "/" (namestring (truename root))))))

(defun nixd-formatter-command ()
  (loop :for candidate :in '("nixfmt-rfc-style" "nixfmt" "alejandra")
        :when (executable-find candidate)
          :return candidate))

(lem-lsp-mode:define-language-spec (lem-yath-nix-spec lem-nix-mode:nix-mode)
  :language-id "nix"
  :root-uri-patterns '("flake.nix" "flake.lock" "default.nix" "shell.nix")
  :command '("nixd")
  :install-command "nix profile install nixpkgs#nixd"
  :readme-url "https://github.com/nix-community/nixd"
  :connection-mode :stdio)

(defmethod lem-lsp-mode:spec-initialization-options ((spec lem-yath-nix-spec))
  (let* ((root (nixd-flake-root))
         (expr (if root
                   (format nil "import (builtins.getFlake \"~a\").inputs.nixpkgs { }" root)
                   "import <nixpkgs> { }"))
         (formatter (nixd-formatter-command))
         (sources (and root
                       (rest (assoc root *nixd-known-flake-option-sources*
                                    :test #'string=))))
         (options '()))
    (dolist (source sources)
      (push (lem-lsp-base/type:make-lsp-map
             "expr" (format nil "(builtins.getFlake \"~a\").~a" root (cdr source)))
            options)
      (push (car source) options))
    (apply #'lem-lsp-base/type:make-lsp-map
           "nixpkgs" (lem-lsp-base/type:make-lsp-map "expr" expr)
           (append (when formatter
                     (list "formatting"
                           (lem-lsp-base/type:make-lsp-map
                            "command" (vector formatter))))
                   (when options
                     (list "options" (apply #'lem-lsp-base/type:make-lsp-map
                                            options)))))))

;;; --- Java / eglot-java ---------------------------------------------------

(defparameter *java-google-style-url*
  "https://raw.githubusercontent.com/google/styleguide/gh-pages/eclipse-java-google-style.xml")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defclass lem-yath-java-spec (lem-lsp-mode/spec::spec) ()
    (:default-initargs
     :language-id "java"
     :root-uri-patterns '("pom.xml"
                          "build.gradle"
                          "build.gradle.kts"
                          "settings.gradle"
                          "settings.gradle.kts"
                          ".git")
     :command '("jdtls")
     :install-command "nix profile install nixpkgs#jdt-language-server"
     :readme-url "https://github.com/eclipse-jdtls/eclipse.jdt.ls"
     :connection-mode :stdio
     :mode 'lem-java-mode:java-mode))
  (lem-lsp-mode/spec:register-language-spec
   'lem-java-mode:java-mode
   (make-instance 'lem-yath-java-spec)))

(defmethod lem-lsp-mode:spec-initialization-options
    ((spec lem-yath-java-spec))
  (declare (ignore spec))
  (lem-lsp-base/type:make-lsp-map
   "settings"
   (lem-lsp-base/type:make-lsp-map
    "java"
    (lem-lsp-base/type:make-lsp-map
     "format"
     (lem-lsp-base/type:make-lsp-map
      "settings"
      (lem-lsp-base/type:make-lsp-map "url" *java-google-style-url*)
      "enabled" t)))))

(defun java-project-cache-key (root)
  (let* ((canonical
           (namestring
            (truename (uiop:ensure-directory-pathname root))))
         (digest
           (with-input-from-string (input canonical)
             (uiop:run-program '("sha256sum")
                               :input input
                               :output '(:string :stripped t)
                               :error-output :output))))
    (subseq digest 0 (position #\Space digest))))

(defun java-jdtls-data-pathname (root)
  "Return JDTLS's isolated data pathname for canonical project ROOT."
  (unless root
    (error "JDTLS requires a project root directory."))
  (let* ((cache-root
           (uiop:ensure-directory-pathname
            (or (uiop:getenv "XDG_CACHE_HOME")
                (merge-pathnames ".cache/" (user-homedir-pathname)))))
         (directory
           (merge-pathnames
            (format nil "lem-yath/jdtls/~a/" (java-project-cache-key root))
            cache-root)))
    directory))

(defun java-jdtls-data-directory (root)
  "Create and return JDTLS's isolated data directory for project ROOT."
  (let ((directory (java-jdtls-data-pathname root)))
    (ensure-directories-exist directory)
    directory))

(defmethod lem-lsp-mode::run-server
    ((spec lem-yath-java-spec) &key directory)
  ;; The nixpkgs launcher otherwise derives its data directory from only the
  ;; current directory basename.  Supply a canonical-root key so unrelated
  ;; projects cannot share JDTLS indexes.
  (let* ((data-directory (java-jdtls-data-directory directory))
         (launch-spec
           (make-instance 'lem-yath-java-spec
                          :command (list "jdtls"
                                         "-data"
                                         (namestring data-directory)))))
    (lem-lsp-mode::run-server-using-mode
     :stdio launch-spec :directory directory)))

(define-command lem-yath-java-lsp () ()
  "Enable JDTLS explicitly in the current Java buffer."
  (let ((buffer (current-buffer)))
    (unless (eq 'lem-java-mode:java-mode (buffer-major-mode buffer))
      (editor-error "JDTLS can only be enabled in a Java buffer."))
    (if (mode-active-p buffer 'lem-lsp-mode::lsp-mode)
        (message "JDTLS is already enabled for this buffer.")
        (lem-lsp-mode::lsp-mode t))))

;;; --- workspace symbols (consult-eglot-symbols / SPC p s) ------------------

(defparameter *workspace-symbol-timeout* 10
  "Seconds to wait for one project-wide workspace/symbol response.")

(defstruct (workspace-symbol-candidate
            (:constructor %make-workspace-symbol-candidate))
  symbol
  label
  detail
  filter-text)

(defun workspace-symbol-provider-p (workspace)
  (handler-case
      (lsp:server-capabilities-workspace-symbol-provider
       (lem-lsp-mode::workspace-server-capabilities workspace))
    (unbound-slot () nil)))

(defun workspace-symbol-location (symbol)
  (typecase symbol
    (lsp:symbol-information
     (lsp:symbol-information-location symbol))
    (lsp:workspace-symbol
     (lsp:workspace-symbol-location symbol))))

(defun workspace-symbol-container (symbol)
  (handler-case (lsp:base-symbol-information-container-name symbol)
    (unbound-slot () nil)))

(defun workspace-symbol-kind-name (symbol)
  (or (nth-value
       0
       (lem-lsp-mode::symbol-kind-to-string-and-attribute
        (lsp:base-symbol-information-kind symbol)))
      "Symbol"))

(defun workspace-symbol-location-summary (workspace symbol)
  (let ((location (workspace-symbol-location symbol)))
    (when (typep location 'lsp:location)
      (let* ((file (ignore-errors
                     (lem-lsp-base/utils:uri-to-pathname
                      (lsp:location-uri location))))
             (root (lem-lsp-mode::workspace-root-pathname workspace))
             (range (lsp:location-range location))
             (line (1+ (lsp:position-line (lsp:range-start range)))))
        (when file
          (format nil "~a:~d"
                  (or (and root
                           (ignore-errors (enough-namestring file root)))
                      (namestring file))
                  line))))))

(defun workspace-symbol-to-candidate (workspace symbol)
  (let* ((name (lsp:base-symbol-information-name symbol))
         (kind (workspace-symbol-kind-name symbol))
         (container (workspace-symbol-container symbol))
         (location (workspace-symbol-location-summary workspace symbol))
         (detail (format nil "[~a]~@[ ~a~]~@[ — ~a~]"
                         kind container location)))
    (%make-workspace-symbol-candidate
     :symbol symbol
     :label name
     :detail detail
     :filter-text (format nil "~a ~a~@[ ~a~]~@[ ~a~]"
                          name kind container location))))

(defun request-workspace-symbols (workspace query)
  (unless (workspace-symbol-provider-p workspace)
    (editor-error "The current language server does not provide workspace symbols."))
  (let ((jsonrpc:*default-timeout* *workspace-symbol-timeout*))
    (let ((response
            (lem-language-client/request:request
             (lem-lsp-mode::workspace-client workspace)
             (make-instance 'lsp:workspace/symbol)
             (make-instance 'lsp:workspace-symbol-params :query query))))
      (unless (lem-lsp-base/type:lsp-null-p response)
        (map 'list
             (lambda (symbol)
               (workspace-symbol-to-candidate workspace symbol))
             response)))))

(defun workspace-symbol-completion-item (candidate selected-cell)
  (let ((start (lem/prompt-window::current-prompt-start-point))
        (end (buffer-end-point (current-buffer))))
    (lem/completion-mode:make-completion-item
     :label (workspace-symbol-candidate-label candidate)
     :detail (workspace-symbol-candidate-detail candidate)
     :filter-text (workspace-symbol-candidate-filter-text candidate)
     :start start
     :end end
     :accept-action
     (lambda ()
       (setf (car selected-cell) candidate)))))

(defun prompt-for-workspace-symbol (candidates)
  (let ((selected-cell (list nil)))
    (prompt-for-string
     "Workspace symbol: "
     :completion-function
     (lambda (input)
       (prescient-filter
        input
        (mapcar (lambda (candidate)
                  (workspace-symbol-completion-item candidate selected-cell))
                candidates)
        :key #'lem/completion-mode:completion-item-filter-text
        :category :workspace-symbol))
     :history-symbol 'lem-yath-workspace-symbol)
    (car selected-cell)))

(defun goto-workspace-symbol (workspace candidate)
  (let* ((symbol (workspace-symbol-candidate-symbol candidate))
         (location (workspace-symbol-location symbol)))
    (unless (typep location 'lsp:location)
      (editor-error "The language server returned a workspace symbol without a location."))
    (let ((xref (lem-lsp-mode::convert-location location workspace)))
      (unless xref
        (editor-error "The workspace symbol location is not a readable local file."))
      (lem/language-mode::push-location-stack (current-point))
      (lem/language-mode:go-to-location xref #'switch-to-buffer)
      (lem/peek-source:highlight-matched-line (current-point)))))

(define-command lem-yath-workspace-symbol () ()
  "Query the current LSP project, narrow its symbols, and jump to one."
  (handler-case
      (let ((workspace (lem-lsp-mode::check-connection)))
        (let* ((query (prompt-for-string
                       "Workspace symbol query: "
                       :history-symbol 'lem-yath-workspace-symbol-query))
               (candidates (request-workspace-symbols workspace query)))
          (if candidates
              (alexandria:when-let
                  ((candidate (prompt-for-workspace-symbol candidates)))
                (goto-workspace-symbol workspace candidate))
              (message "No workspace symbols matched ~s." query))))
    (editor-abort () nil)
    (error (condition)
      (message "Workspace symbol search failed: ~a" condition))))

;;; --- project-wide grep prefers ripgrep, as in the Emacs config -------------

(when (executable-find "rg")
  (setf lem/grep:*grep-command* "rg"
        lem/grep:*grep-args* "-nH --no-heading"))
