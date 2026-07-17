(in-package :lem-yath)

;; Keep the four-stage workspace-symbol pulse visible until the physical F12
;; report key arrives.  The production delay remains 30 ms.
(setf *jump-feedback-delay-ms* 300)

(defvar *lsp-project-test-lisp-v2-preloaded-p* nil)
(defvar *lsp-project-test-lisp-v2-immutable-p* nil)
(defvar *lsp-project-test-lisp-v2-load-no-op-p* nil)

(eval-when (:load-toplevel :execute)
  (let* ((name "lem-lisp-mode/v2")
         (system-before (asdf:registered-system name)))
    (setf *lsp-project-test-lisp-v2-preloaded-p*
          (and system-before
               (member name (asdf:already-loaded-systems)
                       :test #'string=))
          *lsp-project-test-lisp-v2-immutable-p*
          (and asdf::*immutable-systems*
               (gethash name asdf::*immutable-systems*)))
    ;; This remains the supported runtime entry point.  In the delivered Lem
    ;; image it must be a no-op because v2 was loaded and frozen before dump.
    (asdf:load-system name)
    (setf *lsp-project-test-lisp-v2-load-no-op-p*
          (and system-before
               (eq system-before (asdf:registered-system name))))))

(defun lsp-project-test-server-command (&rest arguments)
  (append
   (list (or (uiop:getenv "LEM_YATH_LSP_TEST_PYTHON") "python3")
         (uiop:getenv "LEM_YATH_LSP_TEST_SERVER")
         "--events"
         (uiop:getenv "LEM_YATH_LSP_TEST_EVENTS"))
   arguments))

(define-major-mode lem-yath-lsp-project-test-mode
    lem/language-mode:language-mode
    (:name "LSP Project Fixture"
     :mode-hook *lem-yath-lsp-project-test-mode-hook*))

(define-major-mode lem-yath-lsp-timeout-test-mode
    lem/language-mode:language-mode
    (:name "LSP Timeout Fixture"
     :mode-hook *lem-yath-lsp-timeout-test-mode-hook*))

(define-major-mode lem-yath-lsp-pending-test-mode
    lem/language-mode:language-mode
    (:name "LSP Pending Fixture"
     :mode-hook *lem-yath-lsp-pending-test-mode-hook*))

(define-major-mode lem-yath-lsp-slow-shutdown-test-mode
    lem/language-mode:language-mode
    (:name "LSP Slow Shutdown Fixture"
     :mode-hook *lem-yath-lsp-slow-shutdown-test-mode-hook*))

(define-major-mode lem-yath-lsp-symbol-peer-test-mode
    lem/language-mode:language-mode
    (:name "LSP Symbol Peer Fixture"
     :mode-hook *lem-yath-lsp-symbol-peer-test-mode-hook*))

(lem-lsp-mode:define-language-spec
    (lem-yath-lsp-project-test-spec lem-yath-lsp-project-test-mode)
  :language-id "lem-yath-project-fixture"
  :root-uri-patterns '(".lsp-fixture-root")
  :command (lsp-project-test-server-command
            "--initialize-delay-ms" "350"
            "--publish-diagnostics")
  :readme-url "https://example.invalid/lem-yath-lsp-fixture"
  :connection-mode :stdio)

(lem-lsp-mode:define-language-spec
    (lem-yath-lsp-timeout-test-spec lem-yath-lsp-timeout-test-mode)
  :language-id "lem-yath-timeout-fixture"
  :root-uri-patterns '(".lsp-timeout-root")
  :command (lsp-project-test-server-command
            "--initialize-delay-ms" "5000")
  :connection-mode :stdio)

(lem-lsp-mode:define-language-spec
    (lem-yath-lsp-pending-test-spec lem-yath-lsp-pending-test-mode)
  :language-id "lem-yath-pending-fixture"
  :root-uri-patterns '(".lsp-pending-root")
  :command (lsp-project-test-server-command
            "--initialize-delay-ms" "5000")
  :connection-mode :stdio)

(lem-lsp-mode:define-language-spec
    (lem-yath-lsp-slow-shutdown-test-spec
     lem-yath-lsp-slow-shutdown-test-mode)
  :language-id "lem-yath-slow-shutdown-fixture"
  :root-uri-patterns '(".lsp-slow-shutdown-root")
  :command (lsp-project-test-server-command
            "--shutdown-delay-ms" "5000")
  :connection-mode :stdio)

(lem-lsp-mode:define-language-spec
    (lem-yath-lsp-symbol-peer-test-spec
     lem-yath-lsp-symbol-peer-test-mode)
  :language-id "lem-yath-symbol-peer-fixture"
  :root-uri-patterns '(".lsp-fixture-root")
  :command (lsp-project-test-server-command
            "--symbol-prefix" "Peer"
            "--symbol-file" "peer-symbols.fixture"
            "--symbol-score-base" "100"
            "--workspace-symbol-delay-ms" "700"
            "--workspace-symbol-failure-query" "never")
  :connection-mode :stdio)

(defclass lem-yath-lsp-project-lisp-test-spec
    (lem-lisp-mode/v2/lsp-config::lisp-spec)
  ())

(defvar *lsp-project-test-lisp-restart-mode* :unset)

(defmethod lem-lsp-mode::restart-workspace
    ((spec lem-yath-lsp-project-lisp-test-spec) workspace buffers)
  (declare (ignore spec workspace buffers))
  (setf *lsp-project-test-lisp-restart-mode*
        lem-lisp-mode/v2/lsp-config::*self-connection*)
  :fixture-restart)

(defvar *lsp-project-test-report-path*
  (uiop:getenv "LEM_YATH_LSP_TEST_REPORT"))

(defvar *lsp-project-test-a-one* nil)
(defvar *lsp-project-test-a-two* nil)
(defvar *lsp-project-test-b-one* nil)
(defvar *lsp-project-test-symbol-peer* nil)
(defvar *lsp-project-test-pre-save-a-workspace* nil)
(defvar *lsp-project-test-post-save-b-workspace* nil)
(defvar *lsp-project-test-mode-change-had-diagnostics* nil)
(defvar *lsp-project-test-mode-change-had-timer* nil)
(defvar *lsp-project-test-idle-a-anchor* nil)
(defvar *lsp-project-test-timeout-buffer* nil)
(defvar *lsp-project-test-timeout-workspace* nil)
(defvar *lsp-project-test-saved-initialize-timeout* nil)
(defvar *lsp-project-test-pending-buffer* nil)
(defvar *lsp-project-test-pending-workspace* nil)
(defvar *lsp-project-test-slow-buffer* nil)

(defun lsp-project-test-report (control &rest arguments)
  (with-open-file (stream *lsp-project-test-report-path*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun lsp-project-test-path (environment-variable relative-path)
  (merge-pathnames relative-path
                   (uiop:ensure-directory-pathname
                    (uiop:getenv environment-variable))))

(defun lsp-project-test-open
    (environment-variable relative-path
     &optional (mode 'lem-yath-lsp-project-test-mode))
  (let ((buffer (find-file-buffer
                 (lsp-project-test-path environment-variable relative-path))))
    (change-buffer-mode buffer mode)
    ;; The fake diagnostic covers the first character.  Keep the real overlay
    ;; and repeating popup timer alive for lifecycle assertions while placing
    ;; the persistent buffer point outside that range, so it cannot interrupt
    ;; unrelated M-x command entry in the ncurses driver.
    (move-point (buffer-point buffer) (buffer-end-point buffer))
    buffer))

(defun lsp-project-test-live-buffer-p (buffer)
  (and buffer (member buffer (buffer-list) :test #'eq)))

(defun lsp-project-test-workspace (buffer)
  (and (lsp-project-test-live-buffer-p buffer)
       (lem-lsp-mode::buffer-workspace buffer nil)))

(defun lsp-project-test-yes-no (value)
  (if value "yes" "no"))

(defun lsp-project-test-signals-error-p (function)
  (handler-case
      (progn (funcall function) nil)
    (error () t)))

(defun lsp-project-test-handler-a (&rest arguments)
  (declare (ignore arguments))
  :handler-a)

(defun lsp-project-test-handler-b (&rest arguments)
  (declare (ignore arguments))
  :handler-b)

(defun lsp-project-test-editor-variable-key (symbol)
  (lem/common/var:editor-variable-local-indicator
   (get symbol 'lem/common/var:editor-variable)))

(defun lsp-project-test-editor-variable-locally-bound-p (buffer symbol)
  (let* ((unbound (gensym "UNBOUND-"))
         (value (buffer-value
                 buffer (lsp-project-test-editor-variable-key symbol) unbound)))
    (not (eq value unbound))))

(defun lsp-project-test-diagnostic-count (buffer)
  (length (lem-lsp-mode::buffer-diagnostic-overlays buffer)))

(defun lsp-project-test-lisp-v2-contracts ()
  (let* ((spec (make-instance 'lem-yath-lsp-project-lisp-test-spec))
         (root (uiop:ensure-directory-pathname
                (uiop:getenv "LEM_YATH_LSP_TEST_PROJECT_A")))
         (root-uri (lem-lsp-base/utils:pathname-to-uri root))
         (buffer (make-buffer "*lsp-lisp-v2-resolver*" :temporary t))
         (self-workspace
           (make-instance 'lem-lsp-mode::workspace
                          :spec spec
                          :root-pathname root
                          :root-uri root-uri
                          :key (list 'lisp-v2-fixture :self (gensym))
                          :state :ready))
         (manual-workspace
           (make-instance 'lem-lsp-mode::workspace
                          :spec spec
                          :root-pathname root
                          :root-uri root-uri
                          :key (list 'lisp-v2-fixture :manual (gensym))
                          :state :ready))
         (manual-selected nil)
         (self-selected nil)
         (manual-restart-mode nil)
         (manual-binding-restored nil)
         (self-restart-mode nil)
         (self-binding-restored nil))
    (setf (lem-lisp-mode/v2/lsp-config::self-connection-p self-workspace) t
          (lem-lisp-mode/v2/lsp-config::self-connection-p manual-workspace) nil)
    (unwind-protect
         (progn
           (lem-lsp-mode::add-workspace self-workspace)
           (lem-lsp-mode::add-workspace manual-workspace)
           (setf manual-selected
                 (eq manual-workspace
                     (lem-lsp-mode::find-workspace-for-buffer spec buffer)))
           (lem-lsp-mode::remove-workspace manual-workspace)
           (setf self-selected
                 (eq self-workspace
                     (lem-lsp-mode::find-workspace-for-buffer spec buffer)))
           (let ((lem-lisp-mode/v2/lsp-config::*self-connection* t))
             (setf *lsp-project-test-lisp-restart-mode* :unset)
             (lem-lsp-mode::restart-workspace spec manual-workspace nil)
             (setf manual-restart-mode
                   (null *lsp-project-test-lisp-restart-mode*)
                   manual-binding-restored
                   lem-lisp-mode/v2/lsp-config::*self-connection*))
           (let ((lem-lisp-mode/v2/lsp-config::*self-connection* nil))
             (setf *lsp-project-test-lisp-restart-mode* :unset)
             (lem-lsp-mode::restart-workspace spec self-workspace nil)
             (setf self-restart-mode
                   (eq t *lsp-project-test-lisp-restart-mode*)
                   self-binding-restored
                   (null lem-lisp-mode/v2/lsp-config::*self-connection*))))
      (ignore-errors (lem-lsp-mode::remove-workspace manual-workspace))
      (ignore-errors (lem-lsp-mode::remove-workspace self-workspace))
      (when (member buffer (buffer-list) :test #'eq)
        (delete-buffer buffer)))
    (list :manual-selected manual-selected
          :self-selected self-selected
          :manual-restart-mode manual-restart-mode
          :manual-binding-restored manual-binding-restored
          :self-restart-mode self-restart-mode
          :self-binding-restored self-binding-restored)))

(define-command lem-yath-test-lsp-static-checks () ()
  (let ((failures 0))
    (flet ((check (condition label)
             (lsp-project-test-report
              "~a STATIC ~a"
              (if condition "PASS" "FAIL")
              label)
             (unless condition (incf failures))))
      (check (lem/language-mode::match-pattern-p "Cargo.toml" "Cargo.toml")
             "literal-root-marker-matches-exactly")
      (check (not (lem/language-mode::match-pattern-p
                   "Cargo.toml" "Cargo.toml.bak"))
             "literal-root-marker-rejects-backup")
      (check (lem/language-mode::match-pattern-p "*.asd" "lem-yath.asd")
             "glob-root-marker-matches")
      (check (uiop:pathname-equal
              #P"/"
              (lem/language-mode:find-root-directory
               #P"/" '("lem-yath-definitely-absent-root-marker")))
             "root-walk-terminates-at-filesystem-root")
      (let* ((git-root (uiop:ensure-directory-pathname
                        (uiop:getenv "LEM_YATH_LSP_TEST_GIT_ROOT")))
             (child (merge-pathnames "nested/" git-root)))
        (check (uiop:pathname-equal
                git-root
                (lem/language-mode:find-root-directory
                 child '("missing-language-marker")))
               "git-directory-is-a-root-marker"))
      (let* ((path #P"/tmp/lem+yath # λ.lisp")
             (uri (lem-lsp-base/utils:pathname-to-uri path))
             (round-trip (lem-lsp-base/utils:uri-to-pathname uri)))
        (check (and (search "%20" uri)
                    (search "%23" uri)
                    (search "%2B" uri)
                    (uiop:pathname-equal path round-trip))
               "file-uri-round-trips-escaped-path"))
      (check (uiop:pathname-equal
              #P"/tmp/lem+yath.lisp"
              (lem-lsp-base/utils:uri-to-pathname
               "file:///tmp/lem+yath.lisp"))
             "file-uri-preserves-raw-plus")
      (check (lsp-project-test-signals-error-p
              (lambda ()
                (lem-lsp-base/utils:uri-to-pathname
                 "https://example.invalid/source.lisp")))
             "non-file-uri-is-rejected")
      (check (lsp-project-test-signals-error-p
              (lambda ()
                (lem-lsp-base/utils:uri-to-pathname
                 "file://remote.example/source.lisp")))
             "remote-file-authority-is-rejected")
      (check (uiop:pathname-equal
              #P"/tmp/localhost.lisp"
              (lem-lsp-base/utils:uri-to-pathname
               "file://localhost/tmp/localhost.lisp"))
             "localhost-file-authority-is-local")
      (let* ((root (uiop:ensure-directory-pathname
                    (uiop:getenv "LEM_YATH_LSP_TEST_PROJECT_A")))
             (left (make-instance 'lem-yath-lsp-project-test-spec))
             (right (make-instance 'lem-yath-lsp-project-test-spec)))
        (check (equal (lem-lsp-mode::make-workspace-key left root)
                      (lem-lsp-mode::make-workspace-key right root))
               "workspace-key-survives-spec-reload"))
      (let ((buffer (make-buffer "*lsp-fileless-static-check*")))
        (unwind-protect
             (progn
               (change-buffer-mode buffer 'lem-yath-lsp-project-test-mode)
               (check (and (not (lem-lsp-mode::lsp-buffer-eligible-p buffer))
                           (null (lem-lsp-mode::buffer-workspace buffer nil)))
                      "fileless-buffer-does-not-start-lsp"))
          (delete-buffer buffer)))
      (let ((contracts (lsp-project-test-lisp-v2-contracts)))
        (check *lsp-project-test-lisp-v2-preloaded-p*
               "image-preloads-lisp-v2")
        (check *lsp-project-test-lisp-v2-immutable-p*
               "image-registers-lisp-v2-immutable")
        (check *lsp-project-test-lisp-v2-load-no-op-p*
               "lisp-v2-load-system-is-a-no-op")
        (check (getf contracts :manual-selected)
               "lisp-v2-selected-manual-workspace-resolves")
        (check (getf contracts :self-selected)
               "lisp-v2-selected-self-workspace-resolves")
        (check (and (getf contracts :manual-restart-mode)
                    (getf contracts :manual-binding-restored))
               "lisp-v2-manual-restart-mode-is-dynamic")
        (check (and (getf contracts :self-restart-mode)
                    (getf contracts :self-binding-restored))
               "lisp-v2-self-restart-mode-is-dynamic"))
      (check (= 30 lem-lsp-mode::*workspace-initialize-timeout*)
             "production-initialize-timeout-is-thirty-seconds")
      (check (and (eq 'lem-yath-workspace-symbol
                      (leader-binding-command
                       lem-vi-mode:*normal-keymap* "p s"))
                  (eq 'lem-yath-workspace-symbol
                      (leader-binding-command
                       lem-vi-mode:*visual-keymap* "p s")))
             "workspace-symbol-leader-binding")
      (check (and (= 3 *workspace-symbol-minimum-input*)
                  (= 200 *workspace-symbol-debounce-milliseconds*)
                  (= 500 *workspace-symbol-throttle-milliseconds*)
                  (= 10 *workspace-symbol-timeout*))
             "workspace-symbol-consult-async-defaults")
      (lsp-project-test-report "SUMMARY STATIC ~a failures=~d"
                               (if (zerop failures) "PASS" "FAIL")
                               failures))))

(defun lsp-project-test-record-workspaces (label)
  (let* ((a-one (lsp-project-test-workspace *lsp-project-test-a-one*))
         (a-two (lsp-project-test-workspace *lsp-project-test-a-two*))
         (b-one (lsp-project-test-workspace *lsp-project-test-b-one*))
         (workspaces (lem-lsp-mode::all-workspaces)))
    (lsp-project-test-report
     (concatenate
      'string
      "STATE label=~a workspaces=~d same-a=~a isolated-b=~a "
      "a-root=~a b-root=~a a-live=~d")
     label
     (length workspaces)
     (lsp-project-test-yes-no (and a-one a-two (eq a-one a-two)))
     (lsp-project-test-yes-no (and a-one b-one (not (eq a-one b-one))))
     (if a-one (lem-lsp-mode::workspace-root-uri a-one) "none")
     (if b-one (lem-lsp-mode::workspace-root-uri b-one) "none")
     (count-if #'lsp-project-test-live-buffer-p
               (list *lsp-project-test-a-one*
                     *lsp-project-test-a-two*)))))

(define-command lem-yath-test-lsp-open-project-a () ()
  ;; Starting both mode hooks in one editor event is intentional: the fake
  ;; server delays initialize so this exercises in-flight workspace reuse.
  (setf *lsp-project-test-a-one*
        (lsp-project-test-open "LEM_YATH_LSP_TEST_PROJECT_A" "one.fixture")
        *lsp-project-test-a-two*
        (lsp-project-test-open "LEM_YATH_LSP_TEST_PROJECT_A" "two.fixture"))
  (switch-to-buffer *lsp-project-test-a-two*)
  (lsp-project-test-report "OPEN project=a buffers=2"))

(define-command lem-yath-test-lsp-open-project-b () ()
  (setf *lsp-project-test-b-one*
        (lsp-project-test-open "LEM_YATH_LSP_TEST_PROJECT_B" "one.fixture"))
  (switch-to-buffer *lsp-project-test-b-one*)
  (lsp-project-test-report "OPEN project=b buffers=1"))

(define-command lem-yath-test-lsp-activate-project-a () ()
  (unless (lsp-project-test-live-buffer-p *lsp-project-test-a-one*)
    (editor-error "Project A fixture buffer is not live"))
  (switch-to-buffer *lsp-project-test-a-one*)
  (lsp-project-test-report "ACTIVE project=a"))

(define-command lem-yath-test-lsp-activate-project-a-two () ()
  (unless (lsp-project-test-live-buffer-p *lsp-project-test-a-two*)
    (editor-error "Project A second fixture buffer is not live"))
  (switch-to-buffer *lsp-project-test-a-two*)
  (lsp-project-test-report "ACTIVE project=a-two"))

(define-command lem-yath-test-lsp-bottom () ()
  (let ((point (buffer-point (current-buffer))))
    (move-point point (buffer-end-point (current-buffer)))
    (when (plusp (position-at-point point))
      (character-offset point -1))
    (line-start point)
    (window-recenter (current-window))))

(define-command lem-yath-test-lsp-open-symbol-peer () ()
  (setf *lsp-project-test-symbol-peer*
        (lsp-project-test-open
         "LEM_YATH_LSP_TEST_PROJECT_A"
         "peer.fixture"
         'lem-yath-lsp-symbol-peer-test-mode))
  (switch-to-buffer *lsp-project-test-a-one*)
  (lsp-project-test-report "OPEN symbol-peer=yes"))

(define-command lem-yath-test-lsp-close-symbol-peer () ()
  (let ((buffer *lsp-project-test-symbol-peer*))
    (when (lsp-project-test-live-buffer-p buffer)
      (let ((workspace (lsp-project-test-workspace buffer)))
        (delete-buffer buffer)
        (when workspace
          (lem-lsp-mode::dispose-workspace workspace))))
    (setf *lsp-project-test-symbol-peer* nil)
    (when (lsp-project-test-live-buffer-p *lsp-project-test-a-one*)
      (switch-to-buffer *lsp-project-test-a-one*))
    (lsp-project-test-report "CLOSE symbol-peer=yes")))

(define-command lem-yath-test-lsp-record-workspaces () ()
  (lsp-project-test-record-workspaces "manual"))

(define-command lem-yath-test-lsp-record-location () ()
  (let* ((pulse *jump-feedback-current-pulse*)
         (overlay
           (and pulse
                (jump-feedback-pulse-active-p pulse)
                (jump-feedback-pulse-overlay pulse))))
    (lsp-project-test-report
     (concatenate
      'string
      "LOCATION file=~a line=~d column=~d pulse=~a pulse-line=~a "
      "pulse-buffer=~a view-line=~d")
     (or (buffer-filename (current-buffer)) "none")
     (line-number-at-point (current-point))
     (point-charpos (current-point))
     (lsp-project-test-yes-no overlay)
     (or (and overlay (line-number-at-point (overlay-start overlay))) "none")
     (lsp-project-test-yes-no
      (and overlay (eq (current-buffer) (overlay-buffer overlay))))
     (line-number-at-point (window-view-point (current-window))))))

(define-command lem-yath-test-lsp-record-workspace-symbol-source () ()
  (let* ((session *workspace-symbol-session*)
         (window
           (or (and session
                    (workspace-symbol-session-origin-window session))
               (current-window))))
    (with-current-window window
      (lsp-project-test-report
       (concatenate
        'string
        "SYMBOL_SOURCE file=~a line=~d column=~d "
        "view-line=~d view-column=~d hscroll=~a "
        "prompt=~a preview=~a query=~s candidates=~{~a~^,~} "
        "requests=~d workspaces=~d")
       (or (buffer-filename (current-buffer)) "none")
       (line-number-at-point (current-point))
       (point-charpos (current-point))
       (line-number-at-point (window-view-point window))
       (point-charpos (window-view-point window))
       (or (window-parameter window 'lem-core::horizontal-scroll-start) 0)
       (lsp-project-test-yes-no session)
       (lsp-project-test-yes-no
        (and session
             (workspace-symbol-session-preview-candidate session)))
       (if session
           (workspace-symbol-session-query session)
           "")
       (if session
           (mapcar #'workspace-symbol-candidate-label
                   (workspace-symbol-session-candidates session))
           nil)
       (if session
           (length (workspace-symbol-session-requests session))
           0)
       (if session
           (length (workspace-symbol-session-workspaces session))
           0)))))

(define-command lem-yath-test-lsp-close-project-a () ()
  (dolist (buffer (list *lsp-project-test-a-one*
                        *lsp-project-test-a-two*))
    (when (lsp-project-test-live-buffer-p buffer)
      (delete-buffer buffer)))
  (lsp-project-test-record-workspaces "idle-a"))

(define-command lem-yath-test-lsp-disable-project-a-two () ()
  (unless (lsp-project-test-live-buffer-p *lsp-project-test-a-two*)
    (editor-error "Project A fixture buffer is not live"))
  (with-current-buffer *lsp-project-test-a-two*
    (lem-lsp-mode::lsp-mode nil)
    (lsp-project-test-report
     "DISABLE owned=~a completion=~a definitions=~a references=~a revert=~a"
     (lsp-project-test-yes-no
      (lem-lsp-mode::buffer-workspace *lsp-project-test-a-two* nil))
     (lsp-project-test-yes-no
      (variable-value 'lem/language-mode:completion-spec))
     (lsp-project-test-yes-no
      (variable-value 'lem/language-mode:find-definitions-function))
     (lsp-project-test-yes-no
      (variable-value 'lem/language-mode:find-references-function))
     (lsp-project-test-yes-no
      (buffer-value *lsp-project-test-a-two* 'revert-buffer-function)))))

(define-command lem-yath-test-lsp-enable-project-a-two () ()
  (unless (lsp-project-test-live-buffer-p *lsp-project-test-a-two*)
    (editor-error "Project A fixture buffer is not live"))
  (with-current-buffer *lsp-project-test-a-two*
    (lem-lsp-mode::lsp-mode t)
    (lsp-project-test-report
     "REENABLE owned=~a"
     (lsp-project-test-yes-no
      (lem-lsp-mode::buffer-workspace *lsp-project-test-a-two* nil)))))

(define-command lem-yath-test-lsp-handler-binding-restoration () ()
  (unless (lsp-project-test-live-buffer-p *lsp-project-test-a-two*)
    (editor-error "Project A fixture buffer is not live"))
  (let* ((buffer *lsp-project-test-a-two*)
         (variable 'lem/language-mode:find-definitions-function)
         (initially-active
           (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
         (saved-global (variable-value variable :global))
         (saved-local nil)
         (before-unbound nil)
         (inherited-a nil)
         (installed nil)
         (after-unbound nil)
         (restored-a nil)
         (follows-b nil))
    (unwind-protect
         (progn
           (when initially-active
             (with-current-buffer buffer
               (lem-lsp-mode::lsp-mode nil)))
           (setf saved-local
                 (lem-lsp-mode::capture-editor-variable-binding
                  buffer variable))
           (buffer-unbound buffer
                           (lsp-project-test-editor-variable-key variable))
           (setf (variable-value variable :global)
                 'lsp-project-test-handler-a
                 before-unbound
                 (not (lsp-project-test-editor-variable-locally-bound-p
                       buffer variable))
                 inherited-a
                 (eq 'lsp-project-test-handler-a
                     (variable-value variable :default buffer)))
           (with-current-buffer buffer
             (lem-lsp-mode::lsp-mode t))
           (setf installed
                 (and (lsp-project-test-editor-variable-locally-bound-p
                       buffer variable)
                      (eq #'lem-lsp-mode::lsp-find-definitions
                          (variable-value variable :default buffer))))
           (with-current-buffer buffer
             (lem-lsp-mode::lsp-mode nil))
           (setf after-unbound
                 (not (lsp-project-test-editor-variable-locally-bound-p
                       buffer variable))
                 restored-a
                 (eq 'lsp-project-test-handler-a
                     (variable-value variable :default buffer))
                 (variable-value variable :global)
                 'lsp-project-test-handler-b
                 follows-b
                 (eq 'lsp-project-test-handler-b
                     (variable-value variable :default buffer))))
      (when (mode-active-p buffer 'lem-lsp-mode::lsp-mode)
        (with-current-buffer buffer
          (lem-lsp-mode::lsp-mode nil)))
      (when saved-local
        (lem-lsp-mode::restore-editor-variable-binding
         buffer variable saved-local))
      (setf (variable-value variable :global) saved-global)
      (when initially-active
        (with-current-buffer buffer
          (lem-lsp-mode::lsp-mode t))))
    (lsp-project-test-report
     (concatenate
      'string
      "HANDLER-RESTORE before-unbound=~a inherited-a=~a installed=~a "
      "after-unbound=~a restored-a=~a follows-b=~a active=~a")
     (lsp-project-test-yes-no before-unbound)
     (lsp-project-test-yes-no inherited-a)
     (lsp-project-test-yes-no installed)
     (lsp-project-test-yes-no after-unbound)
     (lsp-project-test-yes-no restored-a)
     (lsp-project-test-yes-no follows-b)
     (lsp-project-test-yes-no
      (mode-active-p buffer 'lem-lsp-mode::lsp-mode)))))

(define-command lem-yath-test-lsp-record-project-a-diagnostics () ()
  (let ((workspace
          (lem-lsp-mode::buffer-workspace *lsp-project-test-a-one* nil)))
    (lsp-project-test-report
     (concatenate
      'string
      "DIAGNOSTIC phase=a count=~d timer=~a current=~a "
      "init-timer=~a spinner=~a")
     (lsp-project-test-diagnostic-count *lsp-project-test-a-one*)
     (lsp-project-test-yes-no
      (lem-lsp-mode::buffer-diagnostic-idle-timer
       *lsp-project-test-a-one*))
     (lsp-project-test-yes-no
      (and workspace
           (lem-lsp-mode::workspace-response-current-p
            workspace *lsp-project-test-a-one*)))
     (lsp-project-test-yes-no
      (and workspace
           (lem-lsp-mode::workspace-initialization-timer workspace)))
     (lsp-project-test-yes-no
      (and workspace
           (lem-lsp-mode::workspace-startup-spinner workspace))))))

(define-command lem-yath-test-lsp-save-a-to-b () ()
  (let* ((buffer *lsp-project-test-a-one*)
         (destination
           (lsp-project-test-path
            "LEM_YATH_LSP_TEST_PROJECT_B" "migrated+raw.fixture"))
         (old-workspace (lem-lsp-mode::buffer-workspace buffer nil))
         (had-diagnostics (plusp (lsp-project-test-diagnostic-count buffer)))
         (had-timer
           (not (null (lem-lsp-mode::buffer-diagnostic-idle-timer buffer)))))
    (setf *lsp-project-test-pre-save-a-workspace* old-workspace)
    (switch-to-buffer buffer)
    (write-file destination)
    (let ((new-workspace
            (buffer-value buffer 'lem-lsp-mode::lsp-workspace)))
      (setf *lsp-project-test-post-save-b-workspace* new-workspace)
      (lsp-project-test-report
       (concatenate
        'string
        "SAVE-AS file=~a opened=~a migrated=~a stale-old=~a current-new=~a "
        "diagnostics-clean=~a timer-clean=~a")
       (buffer-filename buffer)
       (or (lem-lsp-mode::buffer-opened-uri buffer) "none")
       (lsp-project-test-yes-no
        (and new-workspace
             (eq new-workspace
                 (lem-lsp-mode::buffer-workspace
                  *lsp-project-test-b-one* nil))))
       (lsp-project-test-yes-no
        (and old-workspace
             (lem-lsp-mode::workspace-response-current-p
              old-workspace buffer)))
       (lsp-project-test-yes-no
        (and new-workspace
             (lem-lsp-mode::workspace-response-current-p
              new-workspace buffer)))
       (lsp-project-test-yes-no
        (and had-diagnostics
             (null (lem-lsp-mode::buffer-diagnostic-overlays buffer))))
       (lsp-project-test-yes-no
        (and had-timer
             (null (lem-lsp-mode::buffer-diagnostic-idle-timer buffer))))))))

(define-command lem-yath-test-lsp-edit-migrated () ()
  (let ((buffer *lsp-project-test-a-one*))
    (unless (lsp-project-test-live-buffer-p buffer)
      (editor-error "Migrated fixture buffer is not live"))
    (switch-to-buffer buffer)
    (move-point (current-point) (buffer-end-point buffer))
    (insert-string (current-point) "post-migration-change")
    (save-buffer buffer)
    (let ((workspace (lem-lsp-mode::buffer-workspace buffer nil)))
      (lsp-project-test-report
       "EDIT-MIGRATED opened=~a current=~a changed=~a"
       (or (lem-lsp-mode::buffer-opened-uri buffer) "none")
       (lsp-project-test-yes-no
        (and workspace
             (lem-lsp-mode::workspace-response-current-p workspace buffer)))
       (lsp-project-test-yes-no
        (search "post-migration-change"
                (points-to-string (buffer-start-point buffer)
                                  (buffer-end-point buffer))))))))

(define-command lem-yath-test-lsp-stale-diagnostic-contract () ()
  (let* ((buffer *lsp-project-test-a-one*)
         (old-workspace *lsp-project-test-pre-save-a-workspace*)
         (new-workspace *lsp-project-test-post-save-b-workspace*)
         (before (lsp-project-test-diagnostic-count buffer))
         (diagnostic
           (make-instance
            'lsp:diagnostic
            :range (make-instance
                    'lsp:range
                    :start (make-instance 'lsp:position :line 0 :character 0)
                    :end (make-instance 'lsp:position :line 0 :character 1))
            :severity lsp:diagnostic-severity-error
            :message "stale diagnostic"))
         (params
           (make-instance 'lsp:publish-diagnostics-params
                          :uri (lem-lsp-mode::buffer-uri buffer)
                          :diagnostics (vector diagnostic))))
    (when old-workspace
      (lem-lsp-mode::highlight-diagnostics old-workspace params))
    (lsp-project-test-report
     (concatenate
      'string
      "STALE-DIAGNOSTIC unchanged=~a old-current=~a new-current=~a "
      "count=~d timer=~a")
     (lsp-project-test-yes-no
      (= before (lsp-project-test-diagnostic-count buffer)))
     (lsp-project-test-yes-no
      (and old-workspace
           (lem-lsp-mode::workspace-response-current-p old-workspace buffer)))
     (lsp-project-test-yes-no
      (and new-workspace
           (lem-lsp-mode::workspace-response-current-p new-workspace buffer)))
     (lsp-project-test-diagnostic-count buffer)
     (lsp-project-test-yes-no
      (lem-lsp-mode::buffer-diagnostic-idle-timer buffer)))))

(define-command lem-yath-test-lsp-change-migrated-major-mode () ()
  (let* ((buffer *lsp-project-test-a-one*)
         (had-diagnostics (plusp (lsp-project-test-diagnostic-count buffer)))
         (had-timer
           (not (null (lem-lsp-mode::buffer-diagnostic-idle-timer buffer)))))
    (setf *lsp-project-test-mode-change-had-diagnostics* had-diagnostics
          *lsp-project-test-mode-change-had-timer* had-timer)
    (change-buffer-mode buffer 'lem/buffer/fundamental-mode:fundamental-mode)
    (switch-to-buffer buffer)
    (lsp-project-test-report "MODE-CHANGE phase=requested")))

(define-command lem-yath-test-lsp-record-major-mode-cleanup () ()
  (let ((buffer *lsp-project-test-a-one*)
        (workspace *lsp-project-test-post-save-b-workspace*))
    (lsp-project-test-report
     (concatenate
      'string
      "MODE-CHANGE phase=done owned=~a lsp=~a completion=~a definitions=~a "
      "references=~a revert=~a opened=~a diagnostics-clean=~a "
      "timer-clean=~a stale=~a")
     (lsp-project-test-yes-no
      (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
     (lsp-project-test-yes-no
      (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
     (lsp-project-test-yes-no
      (variable-value 'lem/language-mode:completion-spec :buffer buffer))
     (lsp-project-test-yes-no
      (variable-value 'lem/language-mode:find-definitions-function
                      :buffer buffer))
     (lsp-project-test-yes-no
      (variable-value 'lem/language-mode:find-references-function
                      :buffer buffer))
     (lsp-project-test-yes-no
      (buffer-value buffer 'revert-buffer-function))
     (lsp-project-test-yes-no (lem-lsp-mode::buffer-opened-uri buffer))
     (lsp-project-test-yes-no
      (and *lsp-project-test-mode-change-had-diagnostics*
           (null (lem-lsp-mode::buffer-diagnostic-overlays buffer))))
     (lsp-project-test-yes-no
      (and *lsp-project-test-mode-change-had-timer*
           (null (lem-lsp-mode::buffer-diagnostic-idle-timer buffer))))
     (lsp-project-test-yes-no
      (lem-lsp-mode::workspace-response-current-p workspace buffer)))))

(define-command lem-yath-test-lsp-start-timeout () ()
  (setf *lsp-project-test-saved-initialize-timeout*
        lem-lsp-mode::*workspace-initialize-timeout*
        lem-lsp-mode::*workspace-initialize-timeout* 1
        *lsp-project-test-timeout-buffer*
        (lsp-project-test-open
         "LEM_YATH_LSP_TEST_TIMEOUT_ROOT"
         "timeout.fixture"
         'lem-yath-lsp-timeout-test-mode)
        *lsp-project-test-timeout-workspace*
        (buffer-value *lsp-project-test-timeout-buffer*
                      'lem-lsp-mode::lsp-workspace))
  (switch-to-buffer *lsp-project-test-timeout-buffer*)
  (lsp-project-test-report "TIMEOUT phase=start"))

(define-command lem-yath-test-lsp-record-timeout () ()
  (let ((workspace *lsp-project-test-timeout-workspace*)
        (buffer *lsp-project-test-timeout-buffer*))
    (setf lem-lsp-mode::*workspace-initialize-timeout*
          *lsp-project-test-saved-initialize-timeout*)
    (lsp-project-test-report
     (concatenate
      'string
      "TIMEOUT phase=done state=~a timer=~a owned=~a lsp=~a "
      "spinner=~a handlers=~a global=~d workspaces=~d")
     (and workspace (lem-lsp-mode::workspace-state workspace))
     (lsp-project-test-yes-no
      (and workspace
           (lem-lsp-mode::workspace-initialization-timer workspace)))
     (lsp-project-test-yes-no
      (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
     (lsp-project-test-yes-no
      (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
     (lsp-project-test-yes-no
      (and workspace
           (lem-lsp-mode::workspace-startup-spinner workspace)))
     (lsp-project-test-yes-no
      (or (variable-value 'lem/language-mode:completion-spec :buffer buffer)
          (variable-value 'lem/language-mode:find-definitions-function
                          :buffer buffer)
          (variable-value 'lem/language-mode:find-references-function
                          :buffer buffer)
          (buffer-value buffer 'revert-buffer-function)))
     lem-lsp-mode::*workspace-initialize-timeout*
     (length (lem-lsp-mode::all-workspaces)))
    ))

(define-command lem-yath-test-lsp-start-pending () ()
  (setf *lsp-project-test-pending-buffer*
        (lsp-project-test-open
         "LEM_YATH_LSP_TEST_PENDING_ROOT"
         "pending.fixture"
         'lem-yath-lsp-pending-test-mode)
        *lsp-project-test-pending-workspace*
        (buffer-value *lsp-project-test-pending-buffer*
                      'lem-lsp-mode::lsp-workspace))
  (switch-to-buffer *lsp-project-test-pending-buffer*)
  (lsp-project-test-report "PENDING phase=start"))

(define-command lem-yath-test-lsp-edit-pending () ()
  (let ((buffer *lsp-project-test-pending-buffer*)
        (workspace *lsp-project-test-pending-workspace*))
    (unless (lsp-project-test-live-buffer-p buffer)
      (editor-error "Pending fixture buffer is not live"))
    (with-current-buffer buffer
      (move-point (current-point) (buffer-end-point buffer))
      (insert-string (current-point) "pending-change"))
    (lsp-project-test-report
     "PENDING phase=edited state=~a owned=~a changed=~a"
     (and workspace (lem-lsp-mode::workspace-state workspace))
     (lsp-project-test-yes-no
      (eq workspace (buffer-value buffer 'lem-lsp-mode::lsp-workspace)))
     (lsp-project-test-yes-no
      (search "pending-change"
              (points-to-string (buffer-start-point buffer)
                                (buffer-end-point buffer)))))
    (buffer-unmark buffer)))

(define-command lem-yath-test-lsp-cancel-pending () ()
  (let ((workspace *lsp-project-test-pending-workspace*)
        (buffer *lsp-project-test-pending-buffer*))
    (with-current-buffer buffer
      (lem-lsp-mode::lsp-mode nil))
    (lsp-project-test-report
     (concatenate
      'string
      "PENDING phase=done state=~a timer=~a spinner=~a owned=~a "
      "lsp=~a workspaces=~d")
     (and workspace (lem-lsp-mode::workspace-state workspace))
     (lsp-project-test-yes-no
      (and workspace
           (lem-lsp-mode::workspace-initialization-timer workspace)))
     (lsp-project-test-yes-no
      (and workspace
           (lem-lsp-mode::workspace-startup-spinner workspace)))
     (lsp-project-test-yes-no
      (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
     (lsp-project-test-yes-no
      (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
     (length (lem-lsp-mode::all-workspaces)))))

(define-command lem-yath-test-lsp-start-slow-shutdown () ()
  (setf *lsp-project-test-slow-buffer*
        (lsp-project-test-open
         "LEM_YATH_LSP_TEST_SLOW_ROOT"
         "slow.fixture"
         'lem-yath-lsp-slow-shutdown-test-mode))
  (switch-to-buffer *lsp-project-test-slow-buffer*)
  (lsp-project-test-report "SLOW phase=start"))

(define-command lem-yath-test-lsp-record-slow-shutdown () ()
  (let ((buffer *lsp-project-test-slow-buffer*))
    (lsp-project-test-report
     "SLOW phase=done owned=~a lsp=~a handlers=~a workspaces=~d"
     (lsp-project-test-yes-no
      (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
     (lsp-project-test-yes-no
      (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
     (lsp-project-test-yes-no
      (or (variable-value 'lem/language-mode:completion-spec :buffer buffer)
          (variable-value 'lem/language-mode:find-definitions-function
                          :buffer buffer)
          (variable-value 'lem/language-mode:find-references-function
                          :buffer buffer)
          (buffer-value buffer 'revert-buffer-function)))
     (length (lem-lsp-mode::all-workspaces)))))

(define-command lem-yath-test-lsp-prepare-idle-a-anchor () ()
  (setf *lsp-project-test-idle-a-anchor*
        (lsp-project-test-open
         "LEM_YATH_LSP_TEST_PROJECT_A" "idle.fixture"))
  (switch-to-buffer *lsp-project-test-idle-a-anchor*)
  (with-current-buffer *lsp-project-test-idle-a-anchor*
    (lem-lsp-mode::lsp-mode nil))
  (lsp-project-test-report
   "IDLE-A phase=ready owned=~a lsp=~a eligible=~a workspaces=~d"
   (lsp-project-test-yes-no
    (buffer-value *lsp-project-test-idle-a-anchor*
                  'lem-lsp-mode::lsp-workspace))
   (lsp-project-test-yes-no
    (mode-active-p *lsp-project-test-idle-a-anchor* 'lem-lsp-mode::lsp-mode))
   (lsp-project-test-yes-no
    (lem-lsp-mode::lsp-buffer-eligible-p *lsp-project-test-idle-a-anchor*))
   (length (lem-lsp-mode::all-workspaces))))

(define-command lem-yath-test-lsp-record-idle-a-shutdown () ()
  (lsp-project-test-report
   "IDLE-A phase=stopped owned=~a lsp=~a workspaces=~d"
   (lsp-project-test-yes-no
    (buffer-value *lsp-project-test-idle-a-anchor*
                  'lem-lsp-mode::lsp-workspace))
   (lsp-project-test-yes-no
    (mode-active-p *lsp-project-test-idle-a-anchor* 'lem-lsp-mode::lsp-mode))
   (length (lem-lsp-mode::all-workspaces))))

(defun lsp-project-test-report-idle-a-reenabled ()
  (let ((workspace
          (lem-lsp-mode::buffer-workspace
           *lsp-project-test-idle-a-anchor* nil)))
    (lsp-project-test-report
     (concatenate
      'string
      "IDLE-A phase=running owned=~a state=~a opened=~a "
      "init-timer=~a workspaces=~d")
     (lsp-project-test-yes-no workspace)
     (and workspace (lem-lsp-mode::workspace-state workspace))
     (or (lem-lsp-mode::buffer-opened-uri
          *lsp-project-test-idle-a-anchor*) "none")
     (lsp-project-test-yes-no
     (and workspace
           (lem-lsp-mode::workspace-initialization-timer workspace)))
     (length (lem-lsp-mode::all-workspaces)))))

(define-command lem-yath-test-lsp-reenable-idle-a () ()
  (switch-to-buffer *lsp-project-test-idle-a-anchor*)
  (with-current-buffer *lsp-project-test-idle-a-anchor*
    (lem-lsp-mode::lsp-mode t))
  (let ((workspace
          (buffer-value *lsp-project-test-idle-a-anchor*
                        'lem-lsp-mode::lsp-workspace)))
    (cond
      ((and workspace (eq :ready (lem-lsp-mode::workspace-state workspace)))
       (lsp-project-test-report-idle-a-reenabled))
      (workspace
       (lem-lsp-mode::queue-workspace-continuation
        workspace
        *lsp-project-test-idle-a-anchor*
        #'lsp-project-test-report-idle-a-reenabled))))
  (lsp-project-test-report "IDLE-A phase=reenable"))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*))
  (define-key keymap "F12" 'lem-yath-test-lsp-record-location)
  (define-key keymap "F10" 'lem-yath-test-lsp-bottom)
  (define-key keymap "F9" 'lem-yath-test-lsp-activate-project-a)
  (define-key keymap "F11"
    'lem-yath-test-lsp-record-workspace-symbol-source))

(define-key *workspace-symbol-prompt-keymap* "F11"
  'lem-yath-test-lsp-record-workspace-symbol-source)

(lsp-project-test-report "READY")
