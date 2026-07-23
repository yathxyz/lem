(in-package :lem-yath)

;;; Installed-runtime acceptance fixture for scripts/lint-test.sh.

(defvar *lint-test-report-path* (uiop:getenv "LEM_YATH_LINT_REPORT"))
(defvar *lint-test-root*
  (uiop:ensure-directory-pathname (uiop:getenv "LEM_YATH_LINT_ROOT")))
(defvar *lint-test-event-path* (uiop:getenv "LEM_YATH_LINT_EVENTS"))
(defvar *lint-test-fake-bin*
  (uiop:ensure-directory-pathname (uiop:getenv "LEM_YATH_LINT_FAKE_BIN")))
(defvar *lint-test-failures* 0)
(defvar *lint-test-stage* :automatic-python)
(defvar *lint-test-deadline* (+ (lint-now-ms) 60000))
(defvar *lint-test-timer* nil)
(defvar *lint-test-python-buffer* nil)
(defvar *lint-test-slow-request* nil)
(defvar *lint-test-original-path* nil)
(defvar *lint-test-finished-p* nil)

(defun lint-test-report (control &rest arguments)
  (with-open-file (stream *lint-test-report-path*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun lint-test-safe (value)
  (let ((text (princ-to-string value)))
    (map 'string
         (lambda (character)
           (if (member character '(#\Newline #\Return #\Tab))
               #\Space
               character))
         text)))

(defun lint-test-check (condition label &optional detail)
  (lint-test-report "~a ~a~@[ -- ~a~]"
                    (if condition "PASS" "FAIL")
                    label
                    (and detail (lint-test-safe detail)))
  (unless condition
    (incf *lint-test-failures*))
  condition)

(defun lint-test-file (relative)
  (merge-pathnames relative *lint-test-root*))

(defun lint-test-binding (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun lint-test-diagnostic-checker-p (diagnostics checker)
  (find checker diagnostics :key #'lint-diagnostic-checker))

(defun lint-test-result-has-level-p (result level)
  (find level (lint-result-diagnostics result)
        :key #'lint-diagnostic-level))

(defun lint-test-events ()
  (if (probe-file *lint-test-event-path*)
      (alexandria:read-file-into-string *lint-test-event-path*)
      ""))

(defun lint-test-set-buffer-text (buffer text)
  (with-current-buffer buffer
    (let ((lem/buffer/internal:*inhibit-modification-hooks* t))
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer) text))))

(defun lint-test-run-case
    (label relative expected-checkers expected-checker &optional expected-mode)
  (let ((buffer nil)
        (request nil))
    (unwind-protect
         (progn
           (let ((lem-lsp-mode::*disable* t))
             (setf buffer (find-file-buffer (lint-test-file relative))))
           (when expected-mode
             (lint-test-check
              (eq expected-mode (buffer-major-mode buffer))
              (format nil "~a-selects-mode" label)
              (buffer-major-mode buffer)))
           (with-current-buffer buffer
             (when (mode-active-p buffer 'lem-yath-lint-mode)
               (lem-yath-lint-mode nil)))
           (let* ((context (lint-capture-context buffer 1 t))
                  (request-value (make-live-project-request 1 nil)))
             (setf request request-value)
             (let ((result (lint-run-context context request-value)))
               (lint-test-check
                (null (lint-result-error result))
                (format nil "~a-runner-completes" label)
                (lint-result-error result))
               (lint-test-check
                (equal expected-checkers (lint-result-checkers result))
                (format nil "~a-checker-chain" label)
                (lint-result-checkers result))
               (lint-test-check
                (plusp (length (lint-result-diagnostics result)))
                (format nil "~a-produces-diagnostics" label))
               (lint-test-check
                (lint-test-diagnostic-checker-p
                 (lint-result-diagnostics result) expected-checker)
                (format nil "~a-diagnostic-attribution" label))
               (lint-test-check
                (lint-test-result-has-level-p result :error)
                (format nil "~a-error-severity" label))
               result)))
      (when request
        (cancel-project-request request))
      (when (and buffer (not (deleted-buffer-p buffer)))
        (delete-buffer buffer)))))

(defun lint-test-static-contract ()
  (dolist (program '("bash" "cargo" "clang" "go" "gofmt" "mypy"
                     "nix-instantiate" "python3" "ruff" "timeout"))
    (lint-test-check (executable-find program)
                     (format nil "runtime-~a" program)))
  (let* ((hook-symbol
           (mode-hook-variable 'lem-python-mode:python-mode))
         (hook (and hook-symbol (symbol-value hook-symbol)))
         (spec (lem-lsp-mode/spec:get-language-spec
                'lem-python-mode:python-mode)))
    (lint-test-check (typep spec 'lem-yath-python-spec)
                     "python-pyright-remains-registered")
    (lint-test-check
     (not (member 'lem-lsp-mode::enable-lsp-mode hook))
     "python-has-no-automatic-lsp-hook"))
  (dolist (entry `((,*lint-command-keymap* "c" lem-yath-lint-buffer)
                   (,*lint-command-keymap* "n" lem-yath-next-diagnostic)
                   (,*lint-command-keymap* "p" lem-yath-previous-diagnostic)
                   (,*lint-command-keymap* "l" lem-yath-list-diagnostics)
                   (,*global-keymap* "M-g n" lem-yath-next-error)
                   (,*global-keymap* "M-g p" lem-yath-previous-error)))
    (destructuring-bind (keymap keys command) entry
      (lint-test-check (eq command (lint-test-binding keymap keys))
                       (format nil "binding-~a" keys))))
  (lint-test-check
   (= 1 (count 'lint-lsp-attached
               lem-lsp-mode::*lsp-buffer-attached-hook*
               :key #'car))
   "lsp-attach-hook-installed-once")
  (lint-test-check
   (= 1 (count 'lint-lsp-detached
               lem-lsp-mode::*lsp-buffer-detached-hook*
               :key #'car))
   "lsp-detach-hook-installed-once")
  (dolist (entry `((after-change-functions lint-after-change)
                   (after-save-hook lint-after-save)
                   (kill-buffer-hook lint-kill-buffer)))
    (destructuring-bind (variable callback) entry
      (lint-test-check
       (= 1 (count callback (variable-value variable :global t)
                   :key #'car))
       (format nil "hook-~a-installed-once" callback))))
  (lint-test-check
   (and *lint-idle-timer* (not (timer-expired-p *lint-idle-timer*)))
   "idle-change-timer-is-running"))

(defun lint-test-empty-navigation-preserves-provider ()
  (let ((buffer (make-buffer " *lint-empty-navigation*" :temporary t))
        (original-source *lem-yath-next-error-source*)
        (editor-error-p nil))
    (unwind-protect
         (progn
           (setf *lem-yath-next-error-source* :compilation)
           (with-current-buffer buffer
             (handler-case
                 (lint-move-to-diagnostic 1)
               (editor-error ()
                 (setf editor-error-p t))))
           (lint-test-check editor-error-p
                            "empty-navigation-reports-no-diagnostics")
           (lint-test-check
            (eq :compilation *lem-yath-next-error-source*)
            "empty-navigation-preserves-compilation-provider"))
      (setf *lem-yath-next-error-source* original-source)
      (unless (deleted-buffer-p buffer)
        (delete-buffer buffer)))))

(defun lint-test-check-automatic-python (buffer)
  (let ((diagnostics
          (buffer-value buffer 'lem-yath-lint-diagnostics)))
    (switch-to-buffer buffer)
    (lint-test-check
     (eq (buffer-major-mode buffer) 'lem-python-mode:python-mode)
     "python-file-selects-python-mode")
    (lint-test-check (mode-active-p buffer 'lem-yath-lint-mode)
                     "python-enables-lint-mode")
    (lint-test-check (not (lint-lsp-owned-p buffer))
                     "python-does-not-auto-start-pyright")
    (lint-test-check
     (equal '(:ruff :mypy)
            (buffer-value buffer 'lem-yath-lint-last-checkers))
     "python-runs-ruff-then-mypy")
    (lint-test-check (lint-test-diagnostic-checker-p diagnostics :ruff)
                     "python-has-ruff-diagnostic")
    (lint-test-check (lint-test-diagnostic-checker-p diagnostics :mypy)
                     "python-has-mypy-diagnostic")
    (lint-test-check (find :warning diagnostics :key #'lint-diagnostic-level)
                     "ruff-diagnostic-is-warning")
    (lint-test-check (find :error diagnostics :key #'lint-diagnostic-level)
                     "mypy-diagnostic-is-error")
    (lint-test-check
     (= (length diagnostics)
        (length (lem-lsp-mode::buffer-diagnostic-overlays buffer)))
     "diagnostics-publish-shared-overlays")
    (lint-test-check
     (eq :lint (buffer-value buffer :lem-yath-diagnostic-owner))
     "diagnostic-owner-is-linter")
    (lint-test-check
     (search "FlyC:" (or (lint-modeline-status (current-window)) ""))
     "modeline-shows-flycheck-counts")
    (buffer-start (current-point))
    (let ((before
            (cons (line-number-at-point (current-point))
                  (point-charpos (current-point)))))
      (lint-move-to-diagnostic 1)
      (lint-test-check
       (not (equal before
                   (cons (line-number-at-point (current-point))
                         (point-charpos (current-point)))))
       "next-diagnostic-moves-point")
      (lint-move-to-diagnostic -1)
      (lint-test-check t "previous-diagnostic-is-usable"))))

(defun lint-test-security-and-lsp-lifecycle (buffer)
  (lint-cancel-request buffer)
  (setf (buffer-value buffer 'lem-yath-sops-active) t)
  (lint-test-check (null (lint-start-check buffer))
                   "sops-plaintext-never-starts-checker")
  (lint-test-check (null (buffer-value buffer 'lem-yath-lint-request))
                   "sops-plaintext-has-no-process-request")
  (setf (buffer-value buffer 'lem-yath-sops-active) nil
        (buffer-value buffer 'lem-lsp-mode::lsp-workspace) :test-workspace)
  (lint-lsp-attached buffer :test-workspace)
  (lint-test-check (not (mode-active-p buffer 'lem-yath-lint-mode))
                   "lsp-attach-disables-linter")
  (lint-test-check (buffer-value buffer 'lem-yath-lint-was-enabled)
                   "lsp-attach-remembers-linter")
  (lint-test-check
   (null (lem-lsp-mode::buffer-diagnostic-overlays buffer))
   "lsp-attach-clears-linter-overlays")
  (setf (buffer-value buffer 'lem-lsp-mode::lsp-workspace) nil)
  (lint-lsp-detached buffer :test-workspace)
  (lint-test-check (mode-active-p buffer 'lem-yath-lint-mode)
                   "lsp-detach-restores-linter")
  (lint-test-check
   (null (buffer-value buffer 'lem-yath-lint-was-enabled))
   "lsp-detach-clears-restore-state")
  (lint-cancel-request buffer))

(defun lint-test-run-real-checkers ()
  (lint-test-run-case "c" "main.c" '(:clang) :clang)
  (lint-test-run-case "cpp" "main.cpp" '(:clang) :clang 'c++-mode)
  (lint-test-run-case "shell" "main.sh" '(:bash) :bash)
  (lint-test-run-case "json" "main.json" '(:json) :json)
  (lint-test-run-case "nix" "default.nix" '(:nix) :nix)
  (lint-test-run-case
   "go" "go/main.go" '(:gofmt :go-vet :go-build) :go-build)
  (lint-test-run-case "rust" "rust/src/main.rs" '(:cargo) :cargo))

(defun lint-test-start-cancellation (buffer)
  (setf *lint-test-original-path* (uiop:getenv "PATH")
        (uiop:getenv "PATH")
        (format nil "~a:~a"
                (uiop:native-namestring *lint-test-fake-bin*)
                *lint-test-original-path*))
  (lint-test-set-buffer-text buffer (format nil "SLOW = True~%"))
  (setf *lint-test-slow-request* (lint-start-check buffer :manual-p t)
        *lint-test-stage* :wait-slow-start
        *lint-test-deadline* (+ (lint-now-ms) 15000))
  (lint-test-check *lint-test-slow-request*
                   "slow-checker-request-started"))

(defun lint-test-start-fast-replacement ()
  (lint-test-set-buffer-text *lint-test-python-buffer*
                             (format nil
                                     "FAST = True~%current = missing~%"))
  (let ((request
          (lint-start-check *lint-test-python-buffer* :manual-p t)))
    (lint-test-check request "replacement-checker-request-started")
    (lint-test-check
     (project-request-cancelled-p *lint-test-slow-request*)
     "superseded-request-is-cancelled")
    (setf *lint-test-stage* :wait-fast-result
          *lint-test-deadline* (+ (lint-now-ms) 15000))))

(defun lint-test-check-fast-result ()
  (let* ((buffer *lint-test-python-buffer*)
         (diagnostics (buffer-value buffer 'lem-yath-lint-diagnostics))
         (codes (mapcar #'lint-diagnostic-code diagnostics)))
    (lint-test-check (equal '(:ruff)
                            (buffer-value buffer
                                          'lem-yath-lint-last-checkers))
                     "unsaved-python-runs-only-ruff")
    (lint-test-check (member "F998" codes :test #'string=)
                     "replacement-result-is-published")
    (lint-test-check (not (member "F999" codes :test #'string=))
                     "stale-result-is-rejected")
    (lint-test-check
     (null (project-request-process *lint-test-slow-request*))
     "cancelled-checker-releases-process")
    (lint-test-check (search "fast-start" (lint-test-events))
                     "replacement-checker-executed")))

(defun lint-test-automatic-triggers (buffer)
  (lint-cancel-request buffer)
  (lint-test-set-buffer-text buffer "value = 1")
  (with-point ((start (buffer-start-point buffer))
               (end (buffer-end-point buffer)))
    (lint-after-change start end 0))
  (lint-test-check
   (and (null (buffer-value buffer 'lem-yath-lint-request))
        (integerp (buffer-value buffer 'lem-yath-lint-due-at))
        (eq :pending (buffer-value buffer 'lem-yath-lint-status)))
   "ordinary-change-schedules-500ms-idle-check")
  (setf (buffer-value buffer 'lem-yath-lint-due-at)
        (1- (lint-now-ms)))
  (lint-reconcile-buffer buffer (lint-now-ms))
  (lint-test-check (buffer-value buffer 'lem-yath-lint-request)
                   "idle-reconciliation-starts-checker")
  (lint-cancel-request buffer)
  (lint-test-set-buffer-text buffer (format nil "value = 1~%"))
  (with-point ((start (buffer-start-point buffer))
               (end (buffer-end-point buffer)))
    (lint-test-check (lint-change-inserts-newline-p start end)
                     "newline-range-is-detected")
    (lint-after-change start end 0))
  (lint-test-check
   (buffer-value buffer 'lem-yath-lint-request)
   "newline-change-starts-checker-immediately"
   (format nil "eligible=~s status=~s due=~s text=~s"
           (lint-automatic-buffer-p buffer)
           (buffer-value buffer 'lem-yath-lint-status)
           (buffer-value buffer 'lem-yath-lint-due-at)
           (points-to-string (buffer-start-point buffer)
                             (buffer-end-point buffer))))
  (lint-cancel-request buffer)
  (lint-after-save buffer)
  (lint-test-check (buffer-value buffer 'lem-yath-lint-request)
                   "save-starts-checker-immediately")
  (lint-cancel-request buffer))

(defun lint-test-finish ()
  (unless *lint-test-finished-p*
    (setf *lint-test-finished-p* t)
    (when *lint-test-original-path*
      (setf (uiop:getenv "PATH") *lint-test-original-path*))
    (when (and *lint-test-python-buffer*
               (not (deleted-buffer-p *lint-test-python-buffer*)))
      (lint-cancel-request *lint-test-python-buffer*))
    (when *lint-test-timer*
      (stop-timer *lint-test-timer*)
      (setf *lint-test-timer* nil))
    (lint-test-report "SUMMARY ~a (~d failure~:p)"
                      (if (zerop *lint-test-failures*) "PASS" "FAIL")
                      *lint-test-failures*)))

(defun lint-test-timeout (label)
  (when (> (lint-now-ms) *lint-test-deadline*)
    (lint-test-check nil label)
    (lint-test-finish)
    t))

(defun lint-test-tick ()
  (unless *lint-test-finished-p*
    (handler-case
        (case *lint-test-stage*
          (:automatic-python
           (unless *lint-test-python-buffer*
             (setf *lint-test-python-buffer*
                   (find-file-buffer (lint-test-file "main.py"))))
           (let ((status
                   (buffer-value *lint-test-python-buffer*
                                 'lem-yath-lint-status)))
             (cond
               ((eq status :finished)
                (lint-test-static-contract)
                (lint-test-empty-navigation-preserves-provider)
                (lint-test-check-automatic-python
                 *lint-test-python-buffer*)
                (lint-test-run-real-checkers)
                (lint-test-security-and-lsp-lifecycle
                 *lint-test-python-buffer*)
                (lint-test-start-cancellation
                 *lint-test-python-buffer*))
               ((eq status :failed)
                (lint-test-check
                 nil "automatic-python-check-finished"
                 (buffer-value *lint-test-python-buffer*
                               'lem-yath-lint-last-error))
                (lint-test-finish))
               ((member status '(:disabled :no-checker))
                (lint-test-check
                 nil "automatic-python-check-started"
                 (format nil
                         "status=~s mode=~s lint=~s lsp=~s kind=~s programs=~s ruff=~s path=~a"
                         status
                         (buffer-major-mode *lint-test-python-buffer*)
                         (mode-active-p *lint-test-python-buffer*
                                        'lem-yath-lint-mode)
                         (lint-lsp-owned-p *lint-test-python-buffer*)
                         (lint-kind-for-buffer *lint-test-python-buffer*)
                         (lint-resolve-programs :python)
                         (executable-find "ruff")
                         (uiop:getenv "PATH")))
                (lint-test-finish))
               (t (lint-test-timeout
                   "automatic-python-check-timed-out")))))
          (:wait-slow-start
           (cond
             ((search "slow-start" (lint-test-events))
              (lint-test-start-fast-replacement))
             (t (lint-test-timeout "slow-checker-did-not-start"))))
          (:wait-fast-result
           (let ((status
                   (buffer-value *lint-test-python-buffer*
                                 'lem-yath-lint-status)))
             (cond
               ((eq status :finished)
                (lint-test-check-fast-result)
                (lint-test-automatic-triggers
                 *lint-test-python-buffer*)
                (lint-test-finish))
               ((eq status :failed)
                (lint-test-check
                 nil "replacement-checker-finished"
                 (buffer-value *lint-test-python-buffer*
                               'lem-yath-lint-last-error))
                (lint-test-finish))
               (t (lint-test-timeout
                   "replacement-checker-timed-out"))))))
      (error (condition)
        (lint-test-check nil "unhandled-error" condition)
        (lint-test-finish)))))

(setf *lint-test-timer*
      (start-timer
       (make-timer 'lint-test-tick :name "lem-yath-lint-test")
       100
       :repeat t))
