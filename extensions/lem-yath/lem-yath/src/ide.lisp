;;;; IDE layer: eglot -> lem-lsp-mode, with the same language servers the
;;;; Emacs config used. Lem ships working specs for go (gopls) and
;;;; terraform; rust/nix have no active spec and python defaults to pylsp,
;;;; so we (re)register specs to match the Emacs setup:
;;;;   rust -> rust-analyzer, nix -> nixd (+ flake-aware settings),
;;;;   python -> pyright, markdown -> harper-ls (prose linting),
;;;;   C# -> csharp-ls.
;;;; Java remains explicit, matching eglot-java-mode in the Emacs config.

(in-package :lem-yath)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defclass lem-yath-eglot-project-spec (lem-lsp-mode/spec::spec) ()))

(defparameter *git-marker-byte-limit* 4096)

(defun read-git-marker (root)
  "Read ROOT's .git marker through one bounded, verified descriptor."
  (let ((descriptor nil)
        (stream nil)
        (marker (merge-pathnames ".git" root)))
    (unwind-protect
         (handler-case
             (progn
               (setf descriptor
                     (sb-posix:open
                      (uiop:native-namestring marker)
                      (logior sb-posix:o-rdonly sb-posix:o-nonblock
                              sb-posix:o-nofollow)))
               (let* ((stat (sb-posix:fstat descriptor))
                      (size (sb-posix:stat-size stat)))
                 (unless (and (= (logand (sb-posix:stat-mode stat)
                                          sb-posix:s-ifmt)
                                   sb-posix:s-ifreg)
                              (<= size *git-marker-byte-limit*))
                   (return-from read-git-marker nil))
                 (let ((fd descriptor))
                   (setf stream
                         (sb-sys:make-fd-stream
                          fd :input t :element-type '(unsigned-byte 8)
                          :buffering :full
                          :name (uiop:native-namestring marker))
                         descriptor nil)
                   (let ((octets
                           (make-array size :element-type '(unsigned-byte 8)))
                         (count 0))
                     (loop :while (< count size)
                           :for next := (read-sequence octets stream
                                                      :start count)
                           :do (when (= next count)
                                 (return-from read-git-marker nil))
                               (setf count next))
                     (sb-ext:octets-to-string
                      octets :external-format :utf-8)))))
           (error () nil))
      (when stream
        (ignore-errors (close stream :abort t)))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor))))))

(defun git-submodule-marker-p (root)
  "Return true when ROOT's bounded .git file identifies a Git submodule."
  (alexandria:when-let ((marker (read-git-marker root)))
    (not
     (null
      (cl-ppcre:scan
       "\\Agitdir:[ \\t]+[^\\r\\n]*/\\.git/(?:worktrees/[^/\\r\\n]+/)?modules/"
       marker)))))

(defun configured-eglot-git-root (directory)
  "Return project.el's configured Git root for DIRECTORY."
  (labels ((walk (start)
             (alexandria:when-let ((root (find-up start ".git")))
               (if (git-submodule-marker-p root)
                   (let ((parent
                           (uiop:pathname-parent-directory-pathname root)))
                     (if (uiop:pathname-equal root parent)
                         root
                         (or (walk parent) root)))
                   root))))
    (walk directory)))

(defun configured-eglot-project-root (buffer)
  "Return BUFFER's Git project root, matching the configured project.el backend."
  (alexandria:when-let*
      ((directory (ignore-errors (buffer-directory buffer)))
       (root (configured-eglot-git-root directory)))
    (uiop:ensure-directory-pathname
     (or (ignore-errors (truename root)) root))))

(defmethod lem-lsp-mode::compute-root-pathname
    ((spec lem-yath-eglot-project-spec) buffer)
  (declare (ignore spec))
  (or (configured-eglot-project-root buffer)
      (call-next-method)))

(lem-lsp-mode:define-language-spec
    (lem-yath-rust-spec lem-rust-mode:rust-mode
                        :parent-spec lem-yath-eglot-project-spec)
  :language-id "rust"
  :root-uri-patterns '("Cargo.toml")
  :command '("rust-analyzer")
  :install-command "nix profile install nixpkgs#rust-analyzer"
  :readme-url "https://rust-analyzer.github.io/"
  :connection-mode :stdio)

;; Python is deliberately registered without the mode hook installed by
;; DEFINE-LANGUAGE-SPEC.  The Emacs configuration does not call eglot-ensure
;; from python-mode, so Flycheck remains authoritative unless Eglot is enabled
;; manually.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defclass lem-yath-python-spec (lem-yath-eglot-project-spec) ()
    (:default-initargs
     :language-id "python"
     :root-uri-patterns '("pyproject.toml" "setup.py" "requirements.txt" "poetry.lock")
     :command '("pyright-langserver" "--stdio")
     :install-command "nix profile install nixpkgs#pyright"
     :readme-url "https://github.com/microsoft/pyright"
     :connection-mode :stdio
     :mode 'lem-python-mode:python-mode))
  (lem-lsp-mode/spec:register-language-spec
   'lem-python-mode:python-mode
   (make-instance 'lem-yath-python-spec))
  (alexandria:when-let
      ((hook (mode-hook-variable 'lem-python-mode:python-mode)))
    (remove-hook (symbol-value hook) 'lem-lsp-mode::enable-lsp-mode)))

(lem-lsp-mode:define-language-spec
    (lem-yath-markdown-spec lem-markdown-mode:markdown-mode
                            :parent-spec lem-yath-eglot-project-spec)
  :language-id "markdown"
  :root-uri-patterns '(".git")
  :command '("harper-ls" "--stdio")
  :install-command "nix profile install nixpkgs#harper"
  :readme-url "https://writewithharper.com/"
  :connection-mode :stdio)

(lem-lsp-mode:define-language-spec
    (lem-yath-csharp-spec csharp-mode
                          :parent-spec lem-yath-eglot-project-spec)
  :language-id "csharp"
  :root-uri-patterns '(".sln" ".csproj" ".git")
  :command '("csharp-ls")
  :install-command "nix profile install nixpkgs#csharp-ls"
  :readme-url "https://github.com/razzmatazz/csharp-language-server"
  :connection-mode :stdio)

;;; --- Godot's externally hosted GDScript server ---------------------------

(defparameter *godot-language-server-default-port* 6005)

(defun godot-config-directory ()
  (uiop:ensure-directory-pathname
   (merge-pathnames
    "godot/"
    (alexandria:if-let ((xdg (uiop:getenv "XDG_CONFIG_HOME")))
      (uiop:ensure-directory-pathname xdg)
      (merge-pathnames ".config/" (user-homedir-pathname))))))

(defun godot-project-version (&optional directory)
  "Return the editor-settings version used by the current Godot project."
  (let* ((directory (or directory (buffer-directory (current-buffer))))
         (root (and directory (find-up directory "project.godot")))
         (file (and root (merge-pathnames "project.godot" root))))
    (when (and file (probe-file file))
      (let ((source (uiop:read-file-string file)))
        (cond
          ((cl-ppcre:scan "(?m)^config_version[ \\t]*=[ \\t]*(?:3|4)[ \\t]*$"
                         source)
           "3")
          (t
           (multiple-value-bind (match groups)
               (cl-ppcre:scan-to-strings
                "config/features[ \\t]*=[ \\t]*PackedStringArray\\(\"([^\",)]+)\""
                source)
             (when match
               (let ((version (aref groups 0)))
                 (if (string= version "4.0") "4" version))))))))))

(defun godot-language-server-port (&optional directory)
  "Read Godot's configured LSP port, falling back to its stock port."
  (or
   (ignore-errors
     (alexandria:when-let*
         ((version (godot-project-version directory))
          (settings
            (merge-pathnames
             (format nil "editor_settings-~a.tres" version)
             (godot-config-directory)))
          (source (and (probe-file settings)
                       (uiop:read-file-string settings))))
       (multiple-value-bind (match groups)
           (cl-ppcre:scan-to-strings
            "network/language_server/remote_port[ \\t]*=[ \\t]*([0-9]+)"
            source)
         (when match
           (parse-integer (aref groups 0))))))
   *godot-language-server-default-port*))

(lem-lsp-mode:define-language-spec
    (lem-yath-gdscript-spec gdscript-mode)
  :language-id "gdscript"
  :root-uri-patterns '("project.godot")
  :command nil
  :readme-url "https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/"
  :connection-mode :tcp
  :port 6005)

(defmethod lem-lsp-mode/spec:spec-port ((spec lem-yath-gdscript-spec))
  (declare (ignore spec))
  (godot-language-server-port))

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

(lem-lsp-mode:define-language-spec
    (lem-yath-nix-spec lem-nix-mode:nix-mode
                       :parent-spec lem-yath-eglot-project-spec)
  :language-id "nix"
  :root-uri-patterns '("flake.nix" "flake.lock" "default.nix" "shell.nix")
  :command '("nixd")
  :install-command "nix profile install nixpkgs#nixd"
  :readme-url "https://github.com/nix-community/nixd"
  :connection-mode :stdio)

(defun nixd-workspace-settings ()
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

(defmethod lem-lsp-mode:spec-workspace-configuration
    ((spec lem-yath-nix-spec))
  (declare (ignore spec))
  (lem-lsp-base/type:make-lsp-map "nixd" (nixd-workspace-settings)))

;;; --- configured Eglot stdio specs ---------------------------------------

(lem-lsp-mode:define-language-spec
    (lem-yath-go-spec lem-go-mode:go-mode
                      :parent-spec lem-yath-eglot-project-spec)
  :language-id "go"
  :root-uri-patterns '("go.mod")
  :command '("gopls")
  :install-command "nix profile install nixpkgs#gopls"
  :readme-url "https://go.dev/gopls/"
  :connection-mode :stdio)

(lem-lsp-mode:define-language-spec
    (lem-yath-terraform-spec lem-terraform-mode:terraform-mode
                             :parent-spec lem-yath-eglot-project-spec)
  :language-id "terraform"
  :root-uri-patterns '()
  :command '("terraform-ls" "serve")
  :install-command "nix profile install nixpkgs#terraform-ls"
  :readme-url "https://github.com/hashicorp/terraform-ls"
  :connection-mode :stdio)

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

;;; --- Eglot-style work-done progress -------------------------------------

(defun lsp-work-done-progress-modeline (window)
  (let* ((buffer (window-buffer window))
         (workspace (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
         (percentage
           (and workspace
                (lem-lsp-mode::workspace-progress-percentage workspace))))
    (if percentage
        (values (format nil " LSP ~d% " percentage)
                (if (eq window (current-window))
                    'lem-core::modeline-minor-modes-attribute
                    'lem-core::inactive-modeline-minor-modes-attribute)
                :right)
        "")))

(defun lsp-progress-modeline-attached (buffer workspace)
  (declare (ignore workspace))
  (modeline-add-status-list 'lsp-work-done-progress-modeline buffer))

(defun lsp-progress-modeline-detached (buffer workspace)
  (declare (ignore workspace))
  (modeline-remove-status-list 'lsp-work-done-progress-modeline buffer))

(defun configure-lsp-progress-modeline ()
  (remove-hook lem-lsp-mode::*lsp-buffer-attached-hook*
               'lsp-progress-modeline-attached)
  (remove-hook lem-lsp-mode::*lsp-buffer-detached-hook*
               'lsp-progress-modeline-detached)
  (add-hook lem-lsp-mode::*lsp-buffer-attached-hook*
            'lsp-progress-modeline-attached)
  (add-hook lem-lsp-mode::*lsp-buffer-detached-hook*
            'lsp-progress-modeline-detached)
  (dolist (buffer (buffer-list))
    (modeline-remove-status-list 'lsp-work-done-progress-modeline buffer)
    (when (buffer-value buffer 'lem-lsp-mode::lsp-workspace)
      (modeline-add-status-list 'lsp-work-done-progress-modeline buffer))))

(configure-lsp-progress-modeline)

;;; --- configured grep defaults match the Emacs setup ------------------------

(when (executable-find "rg")
  (lem/grep:change-grep-command "rg" :args "-nS --no-heading"))
