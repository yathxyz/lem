;;;; Flycheck-style non-LSP diagnostics for programming buffers.
;;;;
;;;; The authoritative Emacs configuration enables Flycheck from prog-mode,
;;;; checks on mode enable/save/newline/500ms idle change, and disables it
;;;; while Eglot owns diagnostics.  This module implements that lifecycle with
;;;; the checker programs actually present in the configured development
;;;; environment.  Results use Lem LSP's diagnostic overlays, popup, and list
;;;; UI so switching diagnostic providers does not change presentation.

(in-package :lem-yath)

(defvar *lem-yath-next-error-source* :diagnostic)

(defparameter *lint-idle-change-delay-ms* 500)
(defparameter *lint-idle-poll-ms* 100)
(defparameter *lint-input-limit* (* 16 1024 1024))
(defparameter *lint-output-limit* (* 4 1024 1024))

(defvar *lint-idle-timer* nil)

(defvar *lint-mode-keymap*
  (make-keymap :description '*lint-mode-keymap*))

(defvar *lint-command-keymap*
  (make-keymap :description '*lint-command-keymap*))

(define-key *lint-mode-keymap* "C-c !" *lint-command-keymap*)

(defstruct lint-diagnostic
  line
  column
  level
  message
  checker
  code)

(defstruct lint-context
  buffer
  generation
  tick
  mode
  kind
  filename
  directory
  text
  saved-p
  environment
  programs
  manual-p)

(defstruct lint-result
  (diagnostics '())
  (checkers '())
  error)

(defun lint-now-ms ()
  (floor (* 1000 (get-internal-real-time))
         internal-time-units-per-second))

(defun lint-buffer-live-p (buffer)
  (and (typep buffer 'lem:buffer)
       (not (deleted-buffer-p buffer))
       (member buffer (buffer-list) :test #'eq)))

(defun lint-lsp-owned-p (buffer)
  "Whether Lem LSP is enabled or already owns BUFFER."
  (and (lint-buffer-live-p buffer)
       (or (mode-active-p buffer 'lem-lsp-mode::lsp-mode)
           (buffer-value buffer 'lem-lsp-mode::lsp-workspace))))

(defun lint-mode-object (buffer)
  (ignore-errors (ensure-mode-object (buffer-major-mode buffer))))

(defun lint-kind-for-buffer (buffer)
  (let ((mode (lint-mode-object buffer)))
    (cond
      ((typep mode 'lem-python-mode:python-mode) :python)
      ((typep mode 'lem-c-mode:c-mode) :c)
      ((typep mode 'lem-rust-mode:rust-mode) :rust)
      ((typep mode 'lem-go-mode:go-mode) :go)
      ((typep mode 'lem-nix-mode:nix-mode) :nix)
      ((typep mode 'lem-posix-shell-mode:posix-shell-mode) :shell)
      ((typep mode 'lem-json-mode:json-mode) :json)
      (t nil))))

(defun lint-program-specifications (kind)
  (case kind
    (:python '((:ruff . "ruff") (:mypy . "mypy")))
    (:c '((:clang . "clang") (:gcc . "gcc")))
    (:rust '((:cargo . "cargo")))
    (:go '((:gofmt . "gofmt") (:go . "go")))
    (:nix '((:nix-instantiate . "nix-instantiate")))
    (:shell '((:bash . "bash")))
    (:json '((:python3 . "python3") (:python . "python")))
    (t nil)))

(defun lint-resolve-programs (kind)
  (loop :for (key . name) :in (lint-program-specifications kind)
        :for pathname := (executable-find name)
        :when pathname
          :collect (cons key pathname)))

(defun lint-program (context key)
  (cdr (assoc key (lint-context-programs context))))

(defun lint-primary-program-p (context)
  (case (lint-context-kind context)
    (:python (lint-program context :ruff))
    (:c (or (lint-program context :clang)
            (lint-program context :gcc)))
    (:rust (lint-program context :cargo))
    (:go (and (lint-program context :gofmt)
              (lint-program context :go)))
    (:nix (lint-program context :nix-instantiate))
    (:shell (lint-program context :bash))
    (:json (or (lint-program context :python3)
               (lint-program context :python)))
    (t nil)))

(defun lint-automatic-buffer-p (buffer)
  (and (lint-buffer-live-p buffer)
       (mode-active-p buffer 'lem-yath-lint-mode)
       (programming-buffer-p buffer)
       (not (buffer-temporary-p buffer))
       (not (buffer-read-only-p buffer))
       ;; Flycheck deliberately refuses encrypted buffers.  Do not send SOPS
       ;; plaintext to arbitrary project checkers either.
       (not (sops-buffer-active-p buffer))
       (not (lint-lsp-owned-p buffer))))

(defun lint-capture-environment ()
  #+sbcl (copy-list (sb-ext:posix-environ))
  #-sbcl nil)

(defun lint-buffer-text (buffer)
  (let ((text (points-to-string (buffer-start-point buffer)
                                (buffer-end-point buffer))))
    (when (> (length text) *lint-input-limit*)
      (error "buffer exceeds the ~d-character lint limit"
             *lint-input-limit*))
    text))

(defun lint-capture-context (buffer generation manual-p)
  (let* ((filename (buffer-filename buffer))
         (kind (lint-kind-for-buffer buffer)))
    (make-lint-context
     :buffer buffer
     :generation generation
     :tick (buffer-modified-tick buffer)
     :mode (buffer-major-mode buffer)
     :kind kind
     :filename filename
     :directory (or (ignore-errors (buffer-directory buffer))
                    (uiop:getcwd))
     :text (lint-buffer-text buffer)
     :saved-p (and filename
                   (not (buffer-modified-p buffer))
                   (probe-file filename))
     :environment (lint-capture-environment)
     :programs (lint-resolve-programs kind)
     :manual-p manual-p)))

;;; Diagnostic presentation --------------------------------------------------

(defun lint-clean-message (message)
  (let* ((message (or message "no message"))
         (message (ppcre:regex-replace-all "[\\r\\n\\t ]+" message " "))
         (message (string-trim '(#\Space) message)))
    (if (> (length message) 1000)
        (concatenate 'string (subseq message 0 999) "…")
        message)))

(defun lint-checker-name (checker)
  (string-downcase (string checker)))

(defun lint-display-message (diagnostic)
  (format nil "[~a~@[ ~a~]] ~a"
          (lint-checker-name (lint-diagnostic-checker diagnostic))
          (lint-diagnostic-code diagnostic)
          (lint-clean-message (lint-diagnostic-message diagnostic))))

(defun make-lint-source-diagnostic
    (checker level line column message &optional code)
  (make-lint-diagnostic
   :checker checker
   :level level
   :line (max 1 (or line 1))
   :column (and column (max 1 column))
   :message (lint-clean-message message)
   :code code))

(defun lint-diagnostic-attribute (diagnostic)
  (ecase (lint-diagnostic-level diagnostic)
    (:error 'lem-lsp-mode::diagnostic-error-attribute)
    (:warning 'lem-lsp-mode::diagnostic-warning-attribute)
    (:info 'lem-lsp-mode::diagnostic-information-attribute)
    (:hint 'lem-lsp-mode::diagnostic-hint-attribute)))

(defun lint-clear-diagnostics (buffer)
  (when (and (lint-buffer-live-p buffer)
             (eq :lint (buffer-value buffer :lem-yath-diagnostic-owner)))
    (lem-lsp-mode::reset-buffer-diagnostic buffer)
    (setf (buffer-value buffer :lem-yath-diagnostic-owner) nil))
  (when (lint-buffer-live-p buffer)
    (setf (buffer-value buffer 'lem-yath-lint-diagnostics) nil)))

(defun lint-symbol-range (start end)
  (when (syntax-symbol-char-p (character-at start))
    (skip-chars-backward start #'syntax-symbol-char-p)
    (skip-chars-forward end #'syntax-symbol-char-p)))

(defun lint-highlight-diagnostic (buffer diagnostic)
  (with-point ((start (buffer-point buffer))
               (end (buffer-point buffer)))
    (unless (move-to-line start (lint-diagnostic-line diagnostic))
      (return-from lint-highlight-diagnostic nil))
    (line-start start)
    (if (lint-diagnostic-column diagnostic)
        (progn
          (move-to-column start
                          (1- (lint-diagnostic-column diagnostic)))
          (move-point end start)
          (lint-symbol-range start end)
          (when (point= start end)
            (cond
              ((character-at end)
               (character-offset end 1))
              ((plusp (point-charpos start))
               (character-offset start -1)))))
        (progn
          (move-point end start)
          (line-end end)))
    (when (point= start end)
      (return-from lint-highlight-diagnostic nil))
    (let ((overlay
            (make-overlay start end
                          (lint-diagnostic-attribute diagnostic)
                          :end-point-kind :right-inserting)))
      (overlay-put
       overlay
       'lem-lsp-mode::diagnostic
       (lem-lsp-mode::make-diagnostic
        :buffer buffer
        :position
        (lem-lsp-mode::point-to-xref-position start)
        :message (lint-display-message diagnostic)))
      (push overlay (lem-lsp-mode::buffer-diagnostic-overlays buffer))
      overlay)))

(defun lint-diagnostic< (left right)
  (or (< (lint-diagnostic-line left) (lint-diagnostic-line right))
      (and (= (lint-diagnostic-line left) (lint-diagnostic-line right))
           (< (or (lint-diagnostic-column left) 0)
              (or (lint-diagnostic-column right) 0)))))

(defun lint-publish-diagnostics (buffer diagnostics)
  (unless (and (lint-buffer-live-p buffer)
               (not (lint-lsp-owned-p buffer)))
    (return-from lint-publish-diagnostics nil))
  (lem-lsp-mode::reset-buffer-diagnostic buffer)
  (let ((diagnostics (stable-sort (copy-list diagnostics)
                                  #'lint-diagnostic<)))
    (setf (buffer-value buffer :lem-yath-diagnostic-owner) :lint
          (buffer-value buffer 'lem-yath-lint-diagnostics) diagnostics)
    (dolist (diagnostic diagnostics)
      (lint-highlight-diagnostic buffer diagnostic))
    (when diagnostics
      (setf (lem-lsp-mode::buffer-diagnostic-idle-timer buffer)
            (start-timer
             (make-idle-timer 'lem-lsp-mode::popup-diagnostic
                              :name "lem-yath-lint-diagnostic")
             200
             :repeat t)))
    (redraw-display)
    diagnostics))

;;; Checker output parsers ---------------------------------------------------

(defun lint-lines (output)
  (mapcar (lambda (line)
            (string-right-trim '(#\Return) line))
          (uiop:split-string (or output "") :separator '(#\Newline))))

(defun lint-parse-integer (string &optional default)
  (if string
      (handler-case (parse-integer string)
        (error () default))
      default))

(defun lint-parse-ruff (output)
  (loop :for line :in (lint-lines output)
        :for diagnostic =
          (cl-ppcre:register-groups-bind
              (file row column code message)
              ("^(.+):(\\d+):(\\d+): ([A-Za-z0-9-]+):? (.*)$" line)
            (declare (ignore file))
            (make-lint-source-diagnostic
             :ruff
             (if (member code '("SyntaxError" "invalid-syntax")
                         :test #'string=)
                 :error
                 :warning)
             (lint-parse-integer row 1)
             (lint-parse-integer column nil)
             message code))
        :when diagnostic
          :collect diagnostic))

(defun lint-reported-file-p (context reported &optional directory)
  (let ((expected (lint-context-filename context)))
    (when (and expected reported (plusp (length reported)))
      (handler-case
          (let* ((reported-path (pathname reported))
                 (candidate
                   (if (uiop:absolute-pathname-p reported-path)
                       reported-path
                       (merge-pathnames reported-path
                                        (or directory
                                            (lint-context-directory context)))))
                 (expected (expand-file-name expected))
                 (candidate (expand-file-name candidate)))
            (if (and (probe-file expected) (probe-file candidate))
                (uiop:pathname-equal (truename expected) (truename candidate))
                (string= (uiop:native-namestring expected)
                         (uiop:native-namestring candidate))))
        (error () nil)))))

(defun lint-parse-mypy (context output directory)
  (loop :for line :in (lint-lines output)
        :for diagnostic =
          (cl-ppcre:register-groups-bind
              (file row column level message code)
              ("^(.+?):(\\d+)(?::(\\d+))?: (error|warning|note): (.*?)(?:  \\[([^]]+)\\])?$"
               line)
            (when (lint-reported-file-p context file directory)
              (make-lint-source-diagnostic
               :mypy
               (cond
                 ((string= level "error") :error)
                 ((string= level "warning") :warning)
                 (t :info))
               (lint-parse-integer row 1)
               (lint-parse-integer column nil)
               message code)))
        :when diagnostic
          :collect diagnostic))

(defun lint-parse-c-compiler (checker output)
  (loop :for line :in (lint-lines output)
        :for diagnostic =
          (cl-ppcre:register-groups-bind (row column level message)
              ("^(?:<stdin>|.*?):(\\d+)(?::(\\d+))?: (note|warning|fatal error|error): (.*)$"
               line)
            (make-lint-source-diagnostic
             checker
             (cond
               ((string= level "note") :info)
               ((string= level "warning") :warning)
               (t :error))
             (lint-parse-integer row 1)
             (lint-parse-integer column nil)
             (if (zerop (length message)) "no message" message)))
        :when diagnostic
          :collect diagnostic))

(defun lint-parse-shell (output)
  (loop :for line :in (lint-lines output)
        :for diagnostic =
          (cl-ppcre:register-groups-bind (row message)
              ("^[^:]+:[^0-9]*(\\d+)[ ]*:[ ]*(.*)$" line)
            (make-lint-source-diagnostic
             :bash :error (lint-parse-integer row 1) nil message))
        :when diagnostic
          :collect diagnostic))

(defun lint-parse-json-tool (output)
  (loop :for line :in (lint-lines output)
        :for diagnostic =
          (cl-ppcre:register-groups-bind (message row column)
              ("^(.*): line (\\d+) column (\\d+)(?: |$)" line)
            (make-lint-source-diagnostic
             :json :error
             (lint-parse-integer row 1)
             (lint-parse-integer column 1)
             message))
        :when diagnostic
          :collect diagnostic))

(defun lint-parse-go-standard-input (output)
  (loop :for line :in (lint-lines output)
        :for diagnostic =
          (cl-ppcre:register-groups-bind (row column message)
              ("^<standard input>:(\\d+):(\\d+): (.*)$" line)
            (make-lint-source-diagnostic
             :gofmt :error
             (lint-parse-integer row 1)
             (lint-parse-integer column 1)
             message))
        :when diagnostic
          :collect diagnostic))

(defun lint-parse-go-file-output (context checker level output directory)
  (loop :for line :in (lint-lines output)
        :for diagnostic =
          (cl-ppcre:register-groups-bind (file row column message)
              ("^(?:vet: )?(.*?):(\\d+)(?::(\\d+))?: (.*)$" line)
            (when (lint-reported-file-p context file directory)
              (make-lint-source-diagnostic
               checker level
               (lint-parse-integer row 1)
               (lint-parse-integer column nil)
               message)))
        :when diagnostic
          :collect diagnostic))

(defun lint-parse-nix (output)
  (let ((message nil)
        (diagnostics '()))
    (dolist (line (lint-lines output))
      (cond
        ((alexandria:starts-with-subseq "error: " line)
         (setf message (subseq line (length "error: "))))
        ((cl-ppcre:register-groups-bind (row column)
             ("^[ ]*at «stdin»:(\\d+):(\\d+):$" line)
           (push (make-lint-source-diagnostic
                  :nix :error
                  (lint-parse-integer row 1)
                  (lint-parse-integer column 1)
                  (or message "Nix parse error"))
                 diagnostics)
           (setf message nil)
           t))
        ((cl-ppcre:register-groups-bind (row column)
             ("^at: \\((\\d+):(\\d+)\\) from stdin$" line)
           (push (make-lint-source-diagnostic
                  :nix :error
                  (lint-parse-integer row 1)
                  (lint-parse-integer column 1)
                  (or message "Nix parse error"))
                 diagnostics)
           (setf message nil)
           t))))
    (nreverse diagnostics)))

(defun lint-json-sequence (value)
  (cond
    ((vectorp value) (coerce value 'list))
    ((listp value) value)
    (t nil)))

(defun lint-cargo-level (level)
  (cond
    ((string= level "error") :error)
    ((string= level "warning") :warning)
    ((member level '("note" "help" "failure-note") :test #'string=) :info)
    (t :info)))

(defun lint-cargo-code (message)
  (let ((code (and (hash-table-p message) (gethash "code" message))))
    (and (hash-table-p code) (gethash "code" code))))

(defun lint-cargo-primary-span (message)
  (find-if (lambda (span)
             (and (hash-table-p span)
                  (gethash "is_primary" span)))
           (lint-json-sequence
            (and (hash-table-p message) (gethash "spans" message)))))

(defun lint-parse-cargo (context output workspace-root)
  (loop :for line :in (lint-lines output)
        :for object =
          (handler-case (yason:parse line)
            (error () nil))
        :for message =
          (and (hash-table-p object)
               (string= (or (gethash "reason" object) "")
                        "compiler-message")
               (gethash "message" object))
        :for span = (and message (lint-cargo-primary-span message))
        :for reported = (and span (gethash "file_name" span))
        :when (and message span
                   (lint-reported-file-p context reported workspace-root))
          :collect
          (make-lint-source-diagnostic
           :cargo
           (lint-cargo-level (or (gethash "level" message) "error"))
           (or (gethash "line_start" span) 1)
           (or (gethash "column_start" span) 1)
           (or (gethash "message" message) "Rust compiler diagnostic")
          (lint-cargo-code message))))

;;; Checker execution --------------------------------------------------------

(defun lint-run-program
    (context request program arguments &key input directory)
  (run-project-program
   (cons (uiop:native-namestring program) arguments)
   :directory (or directory (lint-context-directory context))
   :request request
   :input input
   :environment (lint-context-environment context)
   :output-limit *lint-output-limit*))

(defun lint-command-output (stdout stderr)
  (concatenate 'string (or stdout "") (string #\Newline) (or stderr "")))

(defun lint-tool-failure (checker status stdout stderr)
  (let* ((detail (string-trim '(#\Space #\Tab #\Newline #\Return)
                              (lint-command-output stdout stderr)))
         (detail (if (> (length detail) 500)
                     (concatenate 'string (subseq detail 0 499) "…")
                     detail)))
    (format nil "~a exited with status ~a~@[: ~a~]"
            (lint-checker-name checker) status
            (and (plusp (length detail)) detail))))

(defun lint-nearest-file (directory names)
  (labels ((walk (current)
             (let ((current (uiop:ensure-directory-pathname current)))
               (or (loop :for name :in names
                         :for path := (merge-pathnames name current)
                         :when (probe-file path)
                           :return path)
                   (let ((parent
                           (uiop:pathname-parent-directory-pathname current)))
                     (unless (uiop:pathname-equal parent current)
                       (walk parent)))))))
    (ignore-errors (walk directory))))

(defun lint-python-project-root (context)
  (let* ((start (uiop:ensure-directory-pathname
                 (lint-context-directory context)))
         (marker
           (lint-nearest-file
            start '("pyproject.toml" "setup.cfg" "mypy.ini"
                    "pyrightconfig.json"))))
    (if marker
        (uiop:pathname-directory-pathname marker)
        (labels ((walk (current)
                   (let ((current (uiop:ensure-directory-pathname current)))
                     (if (not (probe-file
                               (merge-pathnames "__init__.py" current)))
                         current
                         (let ((parent
                                 (uiop:pathname-parent-directory-pathname
                                  current)))
                           (if (uiop:pathname-equal parent current)
                               current
                               (walk parent)))))))
          (walk start)))))

(defun lint-run-python (context request)
  (let* ((ruff (lint-program context :ruff))
         (mypy (lint-program context :mypy))
         (root (lint-python-project-root context))
         (filename (lint-context-filename context))
         (arguments
           (append
            (list "check")
            (list "--output-format=concise")
            (when filename
              (list "--stdin-filename" (uiop:native-namestring filename)))
            (list "-"))))
    (unless ruff
      (return-from lint-run-python
        (make-lint-result :error "ruff is not available")))
    (multiple-value-bind (stdout stderr status)
        (lint-run-program context request ruff arguments
                          :input (lint-context-text context)
                          :directory root)
      (let* ((diagnostics
               (lint-parse-ruff (lint-command-output stdout stderr)))
             (error
               (when (and (not (member status '(0 1)))
                          (null diagnostics))
                 (lint-tool-failure :ruff status stdout stderr)))
             (checkers '(:ruff)))
        (when (and (null error)
                   mypy
                   (lint-context-saved-p context)
                   (notany (lambda (diagnostic)
                             (eq :error
                                 (lint-diagnostic-level diagnostic)))
                           diagnostics))
          (let ((mypy-arguments
                  (list "--show-column-numbers"
                        "--show-error-codes"
                        "--no-pretty"
                        (uiop:native-namestring filename))))
            (multiple-value-bind (mypy-out mypy-err mypy-status)
                (lint-run-program context request mypy mypy-arguments
                                  :directory root)
              (let ((mypy-diagnostics
                      (lint-parse-mypy
                       context
                       (lint-command-output mypy-out mypy-err)
                       root)))
                (setf diagnostics (nconc diagnostics mypy-diagnostics)
                      checkers (append checkers '(:mypy)))
                (when (and (not (member mypy-status '(0 1)))
                           (null mypy-diagnostics))
                  (setf error
                        (lint-tool-failure
                         :mypy mypy-status mypy-out mypy-err)))))))
        (make-lint-result :diagnostics diagnostics
                          :checkers checkers
                          :error error)))))

(defun lint-c++-source-p (filename)
  (and filename
       (member (string-downcase (or (pathname-type filename) ""))
               '("cc" "cp" "cpp" "cxx" "c++" "hh" "hpp" "hxx" "h++")
               :test #'string=)))

(defun lint-run-c (context request)
  (let* ((clang (lint-program context :clang))
         (gcc (lint-program context :gcc))
         (program (or clang gcc))
         (checker (if clang :clang :gcc))
         (language (if (lint-c++-source-p (lint-context-filename context))
                       "c++"
                       "c"))
         (directory (lint-context-directory context))
         (arguments
           (if clang
               (list "-fsyntax-only"
                     "-fno-color-diagnostics"
                     "-fno-caret-diagnostics"
                     "-fno-diagnostics-show-option"
                     "-iquote" (uiop:native-namestring directory)
                     "-Wall" "-Wextra" "-x" language "-")
               (list "-fshow-column"
                     "-iquote" (uiop:native-namestring directory)
                     "-Wall" "-Wextra" "-x" language
                     "-S" "-o" (uiop:native-namestring
                                  (uiop:null-device-pathname))
                     "-"))))
    (unless program
      (return-from lint-run-c
        (make-lint-result :error "neither clang nor gcc is available")))
    (multiple-value-bind (stdout stderr status)
        (lint-run-program context request program arguments
                          :input (lint-context-text context))
      (let ((diagnostics
              (lint-parse-c-compiler
               checker (lint-command-output stdout stderr))))
        (make-lint-result
         :diagnostics diagnostics
         :checkers (list checker)
         :error (when (and (not (zerop status)) (null diagnostics))
                  (lint-tool-failure checker status stdout stderr)))))))

(defun lint-run-shell (context request)
  (let ((bash (lint-program context :bash)))
    (unless bash
      (return-from lint-run-shell
        (make-lint-result :error "bash is not available")))
    (multiple-value-bind (stdout stderr status)
        (lint-run-program context request bash
                          '("--posix" "--norc" "-n" "--")
                          :input (lint-context-text context))
      (let ((diagnostics
              (lint-parse-shell (lint-command-output stdout stderr))))
        (make-lint-result
         :diagnostics diagnostics
         :checkers '(:bash)
         :error (when (and (not (zerop status)) (null diagnostics))
                  (lint-tool-failure :bash status stdout stderr)))))))

(defun lint-run-json (context request)
  (let ((python (or (lint-program context :python3)
                    (lint-program context :python))))
    (unless python
      (return-from lint-run-json
        (make-lint-result :error "python is not available for json.tool")))
    (multiple-value-bind (stdout stderr status)
        (lint-run-program context request python '("-m" "json.tool")
                          :input (lint-context-text context))
      (let ((diagnostics
              (lint-parse-json-tool (lint-command-output stdout stderr))))
        (make-lint-result
         :diagnostics diagnostics
         :checkers '(:json)
         :error (when (and (not (zerop status)) (null diagnostics))
                  (lint-tool-failure :json status stdout stderr)))))))

(defun lint-run-nix (context request)
  (let ((program (lint-program context :nix-instantiate)))
    (unless program
      (return-from lint-run-nix
        (make-lint-result :error "nix-instantiate is not available")))
    (multiple-value-bind (stdout stderr status)
        (lint-run-program context request program '("--parse" "-")
                          :input (lint-context-text context))
      (let ((diagnostics
              (lint-parse-nix (lint-command-output stdout stderr))))
        (make-lint-result
         :diagnostics diagnostics
         :checkers '(:nix)
         :error (when (and (not (zerop status)) (null diagnostics))
                  (lint-tool-failure :nix status stdout stderr)))))))

(defun lint-run-go (context request)
  (let ((gofmt (lint-program context :gofmt))
        (go (lint-program context :go)))
    (unless (and gofmt go)
      (return-from lint-run-go
        (make-lint-result :error "go or gofmt is not available")))
    (multiple-value-bind (stdout stderr status)
        (lint-run-program context request gofmt '()
                          :input (lint-context-text context))
      (let* ((diagnostics
               (lint-parse-go-standard-input
                (lint-command-output stdout stderr)))
             (checkers '(:gofmt))
             (error
               (when (and (not (zerop status)) (null diagnostics))
                 (lint-tool-failure :gofmt status stdout stderr))))
        (when (and (null error)
                   (null diagnostics)
                   (lint-context-saved-p context))
          (let* ((filename (lint-context-filename context))
                 (directory (lint-context-directory context))
                 (native (uiop:native-namestring filename)))
            (multiple-value-bind (vet-out vet-err vet-status)
                (lint-run-program context request go
                                  (list "vet" native)
                                  :directory directory)
              (let ((vet-diagnostics
                      (lint-parse-go-file-output
                       context :go-vet :warning
                       (lint-command-output vet-out vet-err)
                       directory)))
                (setf diagnostics (nconc diagnostics vet-diagnostics)
                      checkers (append checkers '(:go-vet)))
                (when (and (not (zerop vet-status))
                           (null vet-diagnostics))
                  (setf error
                        (lint-tool-failure
                         :go-vet vet-status vet-out vet-err)))))
            (when (null error)
              (let* ((test-p
                       (alexandria:ends-with-subseq
                        "_test.go" (uiop:native-namestring filename)))
                     (arguments
                       (if test-p
                           (list "test" "-c" "-o"
                                 (uiop:native-namestring
                                  (uiop:null-device-pathname)))
                           (list "build" "-o"
                                 (uiop:native-namestring
                                  (uiop:null-device-pathname))))))
                (multiple-value-bind (build-out build-err build-status)
                    (lint-run-program context request go arguments
                                      :directory directory)
                  (let ((build-diagnostics
                          (lint-parse-go-file-output
                           context
                           (if test-p :go-test :go-build)
                           :error
                           (lint-command-output build-out build-err)
                           directory)))
                    (setf diagnostics (nconc diagnostics build-diagnostics)
                          checkers
                          (append checkers
                                  (list (if test-p :go-test :go-build))))
                    (when (and (not (zerop build-status))
                               (null build-diagnostics))
                      (setf error
                            (lint-tool-failure
                             (if test-p :go-test :go-build)
                             build-status build-out build-err)))))))))
        (make-lint-result :diagnostics diagnostics
                          :checkers checkers
                          :error error)))))

(defun lint-cargo-target-kind (kinds)
  (let ((kind (first (lint-json-sequence kinds))))
    (cond
      ((member kind '("lib" "rlib" "dylib" "staticlib" "cdylib"
                      "proc-macro") :test #'string=)
       "lib")
      ((member kind '("bin" "example" "test" "bench") :test #'string=)
       kind)
      (t nil))))

(defun lint-directory-prefix-p (directory filename)
  (let ((directory
          (uiop:native-namestring
           (uiop:ensure-directory-pathname (expand-file-name directory))))
        (filename (uiop:native-namestring (expand-file-name filename))))
    (alexandria:starts-with-subseq directory filename)))

(defun lint-cargo-target-score (context target)
  (when (hash-table-p target)
    (let* ((source (gethash "src_path" target))
           (kind (lint-cargo-target-kind (gethash "kind" target)))
           (filename (lint-context-filename context)))
      (when (and source kind filename)
        (cond
          ((lint-reported-file-p context source) most-positive-fixnum)
          ((lint-directory-prefix-p
            (uiop:pathname-directory-pathname source) filename)
           (length (uiop:native-namestring
                    (uiop:pathname-directory-pathname source))))
          (t nil))))))

(defun lint-cargo-best-target (context metadata)
  (let ((best nil)
        (best-score nil))
    (dolist (package
             (lint-json-sequence
              (and (hash-table-p metadata) (gethash "packages" metadata))))
      (dolist (target
               (lint-json-sequence
                (and (hash-table-p package) (gethash "targets" package))))
        (let ((score (lint-cargo-target-score context target)))
          (when (and score (or (null best-score) (> score best-score)))
            (setf best target
                  best-score score)))))
    best))

(defun lint-cargo-configuration (context request cargo root)
  (multiple-value-bind (stdout stderr status)
      (lint-run-program context request cargo
                        '("metadata" "--no-deps" "--format-version" "1")
                        :directory root)
    (declare (ignore stderr))
    (when (and (integerp status) (zerop status))
      (handler-case
          (let* ((metadata (yason:parse stdout))
                 (target (lint-cargo-best-target context metadata))
                 (workspace
                   (and (hash-table-p metadata)
                        (gethash "workspace_root" metadata))))
            (values target
                    (and workspace
                         (uiop:ensure-directory-pathname workspace))))
        (error () (values nil nil))))))

(defun lint-cargo-target-arguments (target)
  (when (hash-table-p target)
    (let* ((kind (lint-cargo-target-kind (gethash "kind" target)))
           (name (gethash "name" target))
           (features
             (lint-json-sequence (gethash "required-features" target))))
      (append
       (when kind
         (if (string= kind "lib")
             (list "--lib")
             (list (format nil "--~a" kind) name)))
       (when features
         (list (format nil "--features=~{~a~^,~}" features)))))))

(defun lint-run-rust (context request)
  (let* ((cargo (lint-program context :cargo))
         (filename (lint-context-filename context))
         (manifest
           (and filename
                (lint-nearest-file
                 (lint-context-directory context) '("Cargo.toml")))))
    (unless (and cargo manifest (lint-context-saved-p context))
      (return-from lint-run-rust
        (make-lint-result
         :error (cond
                  ((null cargo) "cargo is not available")
                  ((null manifest) "no Cargo.toml was found")
                  (t "Rust Flycheck requires a saved buffer")))))
    (let ((root (uiop:pathname-directory-pathname manifest)))
      (multiple-value-bind (target workspace-root)
          (lint-cargo-configuration context request cargo root)
        (let* ((workspace-root (or workspace-root root))
               (arguments
                 (append (list "test" "--no-run")
                         (lint-cargo-target-arguments target)
                         (list "--message-format=json"))))
          (multiple-value-bind (stdout stderr status)
              (lint-run-program context request cargo arguments
                                :directory root)
            (let ((diagnostics
                    (lint-parse-cargo context stdout workspace-root)))
              (make-lint-result
               :diagnostics diagnostics
               :checkers '(:cargo)
               :error (when (and (not (zerop status)) (null diagnostics))
                        (lint-tool-failure
                         :cargo status stdout stderr))))))))))

(defun lint-run-context (context request)
  (unless (project-request-live-p request)
    (error 'project-request-cancelled))
  (case (lint-context-kind context)
    (:python (lint-run-python context request))
    (:c (lint-run-c context request))
    (:rust (lint-run-rust context request))
    (:go (lint-run-go context request))
    (:nix (lint-run-nix context request))
    (:shell (lint-run-shell context request))
    (:json (lint-run-json context request))
    (t (make-lint-result :error "no checker is configured for this mode"))))

;;; Request lifecycle --------------------------------------------------------

(defun lint-cancel-request (buffer)
  (when (lint-buffer-live-p buffer)
    (incf (buffer-value buffer 'lem-yath-lint-generation 0))
    (alexandria:when-let
        ((request (buffer-value buffer 'lem-yath-lint-request)))
      (setf (buffer-value buffer 'lem-yath-lint-request) nil)
      (cancel-project-request request))))

(defun lint-current-result-p (context request)
  (let ((buffer (lint-context-buffer context)))
    (and (lint-buffer-live-p buffer)
         (eq request (buffer-value buffer 'lem-yath-lint-request))
         (project-request-live-p request)
         (= (lint-context-generation context)
            (buffer-value buffer 'lem-yath-lint-generation 0))
         (= (lint-context-tick context) (buffer-modified-tick buffer))
         (eq (lint-context-mode context) (buffer-major-mode buffer))
         (equal (lint-context-filename context) (buffer-filename buffer))
         (mode-active-p buffer 'lem-yath-lint-mode)
         (programming-buffer-p buffer)
         (not (lint-lsp-owned-p buffer)))))

(defun lint-apply-result (context request result)
  (when (lint-current-result-p context request)
    (let ((buffer (lint-context-buffer context)))
      (setf (buffer-value buffer 'lem-yath-lint-request) nil
            (buffer-value buffer 'lem-yath-lint-last-tick)
            (lint-context-tick context)
            (buffer-value buffer 'lem-yath-lint-last-checkers)
            (lint-result-checkers result)
            (buffer-value buffer 'lem-yath-lint-last-error)
            (lint-result-error result)
            (buffer-value buffer 'lem-yath-lint-status)
            (if (lint-result-error result) :failed :finished))
      (lint-publish-diagnostics buffer (lint-result-diagnostics result))
      (when (and (lint-context-manual-p context)
                 (lint-result-error result))
        (message "Flycheck: ~a" (lint-result-error result))))))

(defun lint-apply-crash (context request condition)
  (when (lint-current-result-p context request)
    (let ((buffer (lint-context-buffer context))
          (message (princ-to-string condition)))
      (setf (buffer-value buffer 'lem-yath-lint-request) nil
            (buffer-value buffer 'lem-yath-lint-status) :failed
            (buffer-value buffer 'lem-yath-lint-last-error) message)
      (when (lint-context-manual-p context)
        (show-message (format nil "Flycheck failed: ~a" message)))
      (redraw-display))))

(defun lint-start-check (buffer &key manual-p)
  (unless (lint-automatic-buffer-p buffer)
    (return-from lint-start-check nil))
  (lint-cancel-request buffer)
  (lint-clear-diagnostics buffer)
  (setf (buffer-value buffer 'lem-yath-lint-due-at) nil)
  (let* ((generation (buffer-value buffer 'lem-yath-lint-generation 0))
         (context
           (handler-case (lint-capture-context buffer generation manual-p)
             (error (condition)
               (setf (buffer-value buffer 'lem-yath-lint-status) :failed
                     (buffer-value buffer 'lem-yath-lint-last-error)
                     (princ-to-string condition))
               (when manual-p
                 (show-message
                  (format nil "Flycheck failed: ~a" condition)))
               (return-from lint-start-check nil))))
         (request (make-live-project-request generation nil)))
    (unless (and (lint-context-kind context)
                 (lint-primary-program-p context))
      (setf (buffer-value buffer 'lem-yath-lint-status) :no-checker
            (buffer-value buffer 'lem-yath-lint-last-error) nil)
      (when manual-p
        (message "Flycheck: no checker is available for this mode."))
      (return-from lint-start-check nil))
    (setf (buffer-value buffer 'lem-yath-lint-request) request
          (buffer-value buffer 'lem-yath-lint-status) :running
          (buffer-value buffer 'lem-yath-lint-last-error) nil)
    (redraw-display)
    (bt2:make-thread
     (lambda ()
       (handler-case
           (let ((result (lint-run-context context request)))
             (send-event
              (lambda () (lint-apply-result context request result))))
         (project-request-cancelled () nil)
         (error (condition)
           (send-event
            (lambda () (lint-apply-crash context request condition))))))
     :name (format nil "lem-yath/lint-~(~a~)"
                   (lint-context-kind context)))
    request))

(defun lint-invalidate-buffer (buffer &key due-at immediate)
  (when (lint-buffer-live-p buffer)
    (lint-cancel-request buffer)
    (lint-clear-diagnostics buffer)
    (setf (buffer-value buffer 'lem-yath-lint-status) :pending
          (buffer-value buffer 'lem-yath-lint-due-at) due-at)
    (when immediate
      (lint-start-check buffer))))

;;; Automatic triggers and LSP ownership ------------------------------------

(defun lint-change-inserts-newline-p (start end)
  (with-point ((point start))
    (loop :while (point< point end)
          :do (when (eql (character-at point) #\Newline)
                (return t))
              (character-offset point 1)
          :finally (return nil))))

(defun lint-after-change (start end old-length)
  (declare (ignore old-length))
  (let ((buffer (point-buffer start)))
    (when (and (lint-buffer-live-p buffer)
               (mode-active-p buffer 'lem-yath-lint-mode))
      (if (lint-change-inserts-newline-p start end)
          (lint-invalidate-buffer buffer :immediate t)
          (lint-invalidate-buffer
           buffer
           :due-at (+ (lint-now-ms) *lint-idle-change-delay-ms*))))))

(defun lint-after-save (&optional (buffer (current-buffer)))
  (when (and (lint-buffer-live-p buffer)
             (mode-active-p buffer 'lem-yath-lint-mode))
    (lint-invalidate-buffer buffer :immediate t)))

(defun lint-kill-buffer (&optional (buffer (current-buffer)))
  (when (lint-buffer-live-p buffer)
    (lint-cancel-request buffer)
    (setf (buffer-value buffer 'lem-yath-lint-due-at) nil)))

(defun lint-mode-enable-hook ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer 'lem-yath-lint-status) :pending)
    (if (lint-lsp-owned-p buffer)
        (setf (buffer-value buffer 'lem-yath-lint-was-enabled) t)
        (lint-start-check buffer))))

(defun lint-mode-disable-hook ()
  (let ((buffer (current-buffer)))
    (lint-cancel-request buffer)
    (lint-clear-diagnostics buffer)
    (setf (buffer-value buffer 'lem-yath-lint-due-at) nil
          (buffer-value buffer 'lem-yath-lint-status) :disabled)
    (redraw-display)))

(define-minor-mode lem-yath-lint-mode
    (:name "Lint"
     :enable-hook 'lint-mode-enable-hook
     :disable-hook 'lint-mode-disable-hook
     :keymap *lint-mode-keymap*
     :hide-from-modeline t)
  "Check the current programming buffer outside LSP ownership.")

(defun lint-enable-for-programming-mode ()
  (let ((buffer (current-buffer)))
    (when (programming-buffer-p buffer)
      (if (lint-lsp-owned-p buffer)
          (setf (buffer-value buffer 'lem-yath-lint-was-enabled) t)
          (lem-yath-lint-mode t)))))

(defun lint-lsp-attached (buffer workspace)
  (declare (ignore workspace))
  (when (and (lint-buffer-live-p buffer)
             (mode-active-p buffer 'lem-yath-lint-mode))
    (with-current-buffer buffer
      (lem-yath-lint-mode nil))
    (setf (buffer-value buffer 'lem-yath-lint-was-enabled) t)))

(defun lint-restore-after-lsp (buffer)
  (when (and (lint-buffer-live-p buffer)
             (buffer-value buffer 'lem-yath-lint-was-enabled)
             (programming-buffer-p buffer)
             (not (lint-lsp-owned-p buffer)))
    (setf (buffer-value buffer 'lem-yath-lint-was-enabled) nil)
    (with-current-buffer buffer
      (lem-yath-lint-mode t))))

(defun lint-lsp-detached (buffer workspace)
  (declare (ignore workspace))
  (lint-restore-after-lsp buffer))

(defun lint-reconcile-buffer (buffer now)
  (when (lint-buffer-live-p buffer)
    (cond
      ((and (mode-active-p buffer 'lem-yath-lint-mode)
            (not (programming-buffer-p buffer)))
       (with-current-buffer buffer
         (lem-yath-lint-mode nil)))
      ((and (mode-active-p buffer 'lem-yath-lint-mode)
            (lint-lsp-owned-p buffer))
       (lint-lsp-attached buffer nil))
      ((buffer-value buffer 'lem-yath-lint-was-enabled)
       (lint-restore-after-lsp buffer))
      ((and (lint-automatic-buffer-p buffer)
            (buffer-value buffer 'lem-yath-lint-due-at)
            (<= (buffer-value buffer 'lem-yath-lint-due-at) now))
       (lint-start-check buffer)))))

(defun lint-idle-function ()
  (let ((now (lint-now-ms)))
    (dolist (buffer (copy-list (buffer-list)))
      (lint-reconcile-buffer buffer now))))

(defun lint-ensure-idle-timer ()
  (unless (and *lint-idle-timer*
               (not (timer-expired-p *lint-idle-timer*)))
    (setf *lint-idle-timer*
          (start-timer
           (make-idle-timer 'lint-idle-function
                            :name "lem-yath-flycheck")
           *lint-idle-poll-ms*
           :repeat t))))

(defun lint-programming-mode-object-p (mode)
  (and (typep mode 'lem/language-mode:language-mode)
       (notany (lambda (class-name)
                 (mode-object-typep mode class-name))
               *non-programming-language-mode-classes*)))

(defun lint-install-major-mode-hooks ()
  (dolist (mode-name (major-modes))
    (let* ((mode (ensure-mode-object mode-name))
           (hook (and (lint-programming-mode-object-p mode)
                      (mode-hook-variable mode))))
      (when (and hook (boundp hook))
        (remove-hook (symbol-value hook) 'lint-enable-for-programming-mode)
        (add-hook (symbol-value hook) 'lint-enable-for-programming-mode)))))

(defun lint-install-hooks ()
  (remove-hook (variable-value 'after-change-functions :global t)
               'lint-after-change)
  (remove-hook (variable-value 'after-save-hook :global t)
               'lint-after-save)
  (remove-hook (variable-value 'kill-buffer-hook :global t)
               'lint-kill-buffer)
  (add-hook (variable-value 'after-change-functions :global t)
            'lint-after-change)
  (add-hook (variable-value 'after-save-hook :global t)
            'lint-after-save)
  (add-hook (variable-value 'kill-buffer-hook :global t)
            'lint-kill-buffer)
  (unless (boundp 'lem-lsp-mode::*lsp-buffer-attached-hook*)
    (setf lem-lsp-mode::*lsp-buffer-attached-hook* nil))
  (unless (boundp 'lem-lsp-mode::*lsp-buffer-detached-hook*)
    (setf lem-lsp-mode::*lsp-buffer-detached-hook* nil))
  (remove-hook lem-lsp-mode::*lsp-buffer-attached-hook* 'lint-lsp-attached)
  (remove-hook lem-lsp-mode::*lsp-buffer-detached-hook* 'lint-lsp-detached)
  (add-hook lem-lsp-mode::*lsp-buffer-attached-hook* 'lint-lsp-attached)
  (add-hook lem-lsp-mode::*lsp-buffer-detached-hook* 'lint-lsp-detached)
  (lint-install-major-mode-hooks))

(defun lint-initialize-editor ()
  (lint-ensure-idle-timer)
  (modeline-remove-status-list 'lint-modeline-status)
  (modeline-add-status-list 'lint-modeline-status)
  (dolist (buffer (copy-list (buffer-list)))
    (when (and (lint-buffer-live-p buffer)
               (programming-buffer-p buffer)
               (not (mode-active-p buffer 'lem-yath-lint-mode))
               (not (lint-lsp-owned-p buffer)))
      (with-current-buffer buffer
        (lem-yath-lint-mode t)))))

;;; User commands, counts, and navigation -----------------------------------

(defun lint-diagnostic-count (buffer level)
  (count level (buffer-value buffer 'lem-yath-lint-diagnostics)
         :key #'lint-diagnostic-level))

(defun lint-modeline-status (window)
  (let ((buffer (window-buffer window)))
    (if (or (mode-active-p buffer 'lem-yath-lint-mode)
            (buffer-value buffer 'lem-yath-lint-was-enabled))
        (case (buffer-value buffer 'lem-yath-lint-status)
          (:running " FlyC*")
          (:pending " FlyC-")
          (:failed " FlyC!")
          (:no-checker " FlyC?")
          (:finished
           (format nil " FlyC:~d/~d"
                   (lint-diagnostic-count buffer :error)
                   (lint-diagnostic-count buffer :warning)))
          (t " FlyC"))
        "")))

(define-command lem-yath-lint-buffer () ()
  "Run the configured non-LSP checker immediately."
  (let ((buffer (current-buffer)))
    (unless (programming-buffer-p buffer)
      (editor-error "The current buffer is not a programming buffer."))
    (when (lint-lsp-owned-p buffer)
      (editor-error "LSP owns diagnostics in the current buffer."))
    (when (sops-buffer-active-p buffer)
      (editor-error "Refusing to send SOPS plaintext to a linter."))
    (when (or (buffer-temporary-p buffer)
              (buffer-read-only-p buffer))
      (editor-error "The current buffer is not eligible for linting."))
    (unless (mode-active-p buffer 'lem-yath-lint-mode)
      (lem-yath-lint-mode t))
    (lint-start-check buffer :manual-p t)))

(defun lint-diagnostic-position-key (diagnostic)
  (let ((position (lem-lsp-mode::diagnostic-position diagnostic)))
    (cons (lem/language-mode::xref-position-line-number position)
          (lem/language-mode::xref-position-charpos position))))

(defun lint-position-key< (left right)
  (or (< (car left) (car right))
      (and (= (car left) (car right))
           (< (cdr left) (cdr right)))))

(defun lint-move-to-diagnostic (direction)
  (let* ((buffer (current-buffer))
         (diagnostics
           (sort (copy-list (lem-lsp-mode::buffer-diagnostics buffer))
                 #'lint-position-key<
                 :key #'lint-diagnostic-position-key)))
    (unless diagnostics
      (editor-error "The current buffer has no diagnostics."))
    (let* ((current
             (cons (line-number-at-point (current-point))
                   (point-charpos (current-point))))
           (diagnostic
             (if (plusp direction)
                 (or (find-if
                      (lambda (candidate)
                        (lint-position-key<
                         current (lint-diagnostic-position-key candidate)))
                      diagnostics)
                     (first diagnostics))
                 (or (find-if
                      (lambda (candidate)
                        (lint-position-key<
                         (lint-diagnostic-position-key candidate) current))
                      diagnostics :from-end t)
                     (car (last diagnostics))))))
      (lem/language-mode:move-to-xref-location-position
       (current-point)
       (lem-lsp-mode::diagnostic-position diagnostic))
      (setf *lem-yath-next-error-source* :diagnostic)
      (message "~a" (lem-lsp-mode::diagnostic-message diagnostic))
      diagnostic)))

(define-command lem-yath-next-diagnostic () ()
  "Move to the next LSP or linter diagnostic, wrapping at buffer end."
  (lint-move-to-diagnostic 1))

(define-command lem-yath-previous-diagnostic () ()
  "Move to the previous LSP or linter diagnostic, wrapping at buffer start."
  (lint-move-to-diagnostic -1))

(define-command lem-yath-list-diagnostics () ()
  "List the current LSP or linter diagnostics in a navigable peek buffer."
  (lem-lsp-mode::lsp-document-diagnostics))

;; Preserve Flycheck's default command prefix for existing muscle memory.
(define-key *lint-command-keymap* "c" 'lem-yath-lint-buffer)
(define-key *lint-command-keymap* "n" 'lem-yath-next-diagnostic)
(define-key *lint-command-keymap* "p" 'lem-yath-previous-diagnostic)
(define-key *lint-command-keymap* "l" 'lem-yath-list-diagnostics)

(lint-install-hooks)
(initialize-editor-feature 'lint-initialize-editor)
