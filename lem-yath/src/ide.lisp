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

;;; --- project-wide grep prefers ripgrep, as in the Emacs config -------------

(when (executable-find "rg")
  (setf lem/grep:*grep-command* "rg"
        lem/grep:*grep-args* "-nH --no-heading"))
