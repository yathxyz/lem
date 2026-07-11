;;;; IDE layer: eglot -> lem-lsp-mode, with the same language servers the
;;;; Emacs config used. Lem ships working specs for go (gopls) and
;;;; terraform; rust/nix have no active spec and python defaults to pylsp,
;;;; so we (re)register specs to match the Emacs setup:
;;;;   rust -> rust-analyzer, nix -> nixd (+ flake-aware settings),
;;;;   python -> pyright, markdown -> harper-ls (prose linting).

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

;;; --- format buffer (apheleia's SPC b f) ------------------------------------

(define-command lem-yath-format-buffer () ()
  "Format the current buffer via its LSP server (apheleia equivalent)."
  (handler-case (uiop:symbol-call :lem-lsp-mode :lsp-document-format)
    (error (e) (message "Format failed: ~a" e))))

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
       (setf (car selected-cell) candidate)
       (completion-record-candidate
        (workspace-symbol-candidate-label candidate))
       (lem/prompt-window::prompt-execute)))))

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
