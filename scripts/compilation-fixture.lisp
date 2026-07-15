(in-package :lem-yath)

;;; Real-editor inspector for scripts/compilation-test.sh.

(defvar *compilation-test-report*
  (uiop:getenv "LEM_YATH_COMPILATION_REPORT"))
(defvar *compilation-test-root*
  (uiop:ensure-directory-pathname
   (pathname (uiop:getenv "LEM_YATH_COMPILATION_ROOT"))))
(defvar *compilation-test-source*
  (pathname (uiop:getenv "LEM_YATH_COMPILATION_SOURCE")))
(defvar *compilation-test-guardian-path-report*
  (uiop:getenv "LEM_YATH_COMPILATION_GUARDIAN_PATH_REPORT"))
(defvar *compilation-test-old-session* nil)
(defvar *compilation-test-old-process* nil)
(defvar *compilation-test-old-reader-thread* nil)
(defvar *compilation-test-provider-seeded-p* nil)
(defvar *compilation-test-drain-counts* (make-hash-table :test #'eq))
(defvar *compilation-test-original-drain-predicate* nil)
(defvar *compilation-test-expected-make-command*
  (uiop:getenv "LEM_YATH_EXPECTED_MAKE_COMMAND"))
(defvar *compilation-test-bash-env*
  (uiop:getenv "LEM_YATH_COMPILATION_BASH_ENV"))
(defvar *compilation-test-shadow-path*
  (uiop:getenv "LEM_YATH_COMPILATION_SHADOW_PATH"))
(defvar *compilation-test-pythonpath*
  (uiop:getenv "LEM_YATH_COMPILATION_PYTHONPATH"))

;; Make the captured project environment actively hostile to the trusted
;; guardian while preserving legitimate inner-shell semantics.  A variable
;; name beginning with "--" also proves unusual captured names survive the
;; private frame and raw execve environment unchanged.
(when *compilation-test-bash-env*
  (sb-posix:setenv "BASH_ENV" *compilation-test-bash-env* 1)
  (sb-posix:setenv
   "SHELLOPTS" "braceexpand:errexit:hashall:interactive-comments" 1)
  (sb-posix:setenv "--help" "captured-option-name" 1))
(when *compilation-test-shadow-path*
  (sb-posix:setenv
   "PATH"
   (format nil "~a:~a"
           *compilation-test-shadow-path*
           (or (uiop:getenv "PATH") ""))
   1))
(when *compilation-test-pythonpath*
  (sb-posix:setenv "PYTHONPATH" *compilation-test-pythonpath* 1))
(when *compilation-test-guardian-path-report*
  (with-open-file (stream *compilation-test-guardian-path-report*
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (write-line (if *compilation-guardian-path*
                    (uiop:native-namestring *compilation-guardian-path*)
                    "<missing>")
                stream)))
(defun compilation-test-output-burst-drained-probe (octet-count buffer)
  "Record positive underfull calls made by the active live reader."
  (let ((session *compilation-session*))
    (when (and (plusp octet-count)
               (< octet-count (length buffer))
               session
               (eq (bt2:current-thread)
                   (compilation-session-reader-thread session)))
      (incf (gethash session *compilation-test-drain-counts* 0))))
  (funcall *compilation-test-original-drain-predicate* octet-count buffer))

;; Keep the production predicate intact while observing its actual reader-side
;; use.  Static calls from this fixture are excluded by the thread identity.
(unless (eq (symbol-function 'compilation-output-burst-drained-p)
            (symbol-function
             'compilation-test-output-burst-drained-probe))
  (setf *compilation-test-original-drain-predicate*
        (symbol-function 'compilation-output-burst-drained-p)
        (symbol-function 'compilation-output-burst-drained-p)
        #'compilation-test-output-burst-drained-probe))

;; Keep timing assertions deterministic on a loaded build host.  Reload tests
;; later restore the production default from compilation.lisp.
(setf *compilation-force-kill-delay* 3)

(defun compilation-test-log (control &rest arguments)
  (with-open-file (stream *compilation-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun compilation-test-binding (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun compilation-test-buffer-text (buffer)
  (points-to-string (buffer-start-point buffer)
                    (buffer-end-point buffer)))

(defun compilation-test-linux-process-state (pid)
  (handler-case
      (with-open-file
          (stream (format nil "/proc/~d/stat" pid) :direction :input)
        (let* ((line (read-line stream))
               (command-end (position #\) line :from-end t)))
          (and command-end
               (< (+ command-end 2) (length line))
               (char line (+ command-end 2)))))
    (file-error () nil)))

(defun compilation-test-process-outcome (pid)
  "Wait briefly for PID to disappear or settle as a zombie."
  (loop :repeat 100
        :for state := (compilation-test-linux-process-state pid)
        :when (null state)
          :return :absent
        :when (char= state #\Z)
          :return :zombie
        :when (char= state #\X)
          :return :exiting
        :do (sleep 0.01)
        :finally (return :running)))

(defun compilation-test-marker-attribute (buffer marker)
  (with-point ((point (buffer-start-point buffer)))
    (when (search-forward-regexp point (cl-ppcre:quote-meta-chars marker))
      (character-offset point (- (length marker)))
      (text-property-at point :attribute))))

(define-command compilation-test-static-contract () ()
  (let* ((map *lem-yath-compilation-mode-keymap*)
         (bindings
           `((,map "Return" lem-yath-compilation-visit-error)
             (,map "g o" lem-yath-compilation-display-error)
             (,map "M-Return" lem-yath-compilation-display-error)
             (,map "S-Return" lem-yath-compilation-display-error)
             (,map "Tab" lem-yath-compilation-next-error)
             (,map "S-Tab" lem-yath-compilation-previous-error)
             (,map "g j" lem-yath-compilation-next-error)
             (,map "g k" lem-yath-compilation-previous-error)
             (,map "C-j" lem-yath-compilation-next-error)
             (,map "C-k" lem-yath-compilation-previous-error)
             (,map "[ [" lem-yath-compilation-previous-file)
             (,map "] ]" lem-yath-compilation-next-file)
             (,map "g r" lem-yath-recompile)
             (,map "C-c C-k" lem-yath-interrupt-compilation)
             (,map "q" quit-active-window)
             (,map "Z Z" quit-active-window)
             (,map "Z Q" lem-vi-mode/commands:vi-quit)
             (,*global-keymap* "M-g n" lem-yath-next-error)
             (,*global-keymap* "M-g p" lem-yath-previous-error)))
         (binding-ok
           (every (lambda (entry)
                    (destructuring-bind (keymap keys command) entry
                      (eq command (compilation-test-binding keymap keys))))
                  bindings))
         (leader
           (leader-binding-command lem-vi-mode:*normal-keymap* "c c"))
         (expected *compilation-test-expected-make-command*)
         (make (executable-find "make"))
         (pinned-ok
           (and *compilation-bash-program*
                *compilation-guardian-python-program*
                *compilation-nproc-program*
                *compilation-guardian-path*
                (probe-file *compilation-bash-program*)
                (probe-file *compilation-guardian-python-program*)
                (probe-file *compilation-nproc-program*)
                (probe-file *compilation-guardian-path*)
                (or (not *compilation-test-shadow-path*)
                    (and
                     (not (search
                           *compilation-test-shadow-path*
                           (namestring *compilation-bash-program*)))
                     (not (search
                           *compilation-test-shadow-path*
                           (namestring
                            *compilation-guardian-python-program*)))
                     (not (search
                           *compilation-test-shadow-path*
                           (namestring *compilation-nproc-program*)))))))
         (drain-buffer
           (make-array 8192 :element-type '(unsigned-byte 8)))
         (drain-ok
           (and (compilation-output-burst-drained-p 0 drain-buffer)
                (compilation-output-burst-drained-p 1 drain-buffer)
                (not (compilation-output-burst-drained-p
                      (length drain-buffer) drain-buffer))))
         (parser-session
           (make-compilation-session :directory *compilation-test-root*))
         (samples
           (list
            (format nil "~a:2:3: error: gcc"
                    (uiop:native-namestring
                     (merge-pathnames "main.c" *compilation-test-root*)))
            (format nil "  --> ~a:3:5"
                    (uiop:native-namestring
                     (merge-pathnames "secondary.rs" *compilation-test-root*)))
            (format nil "~a:4:2: go"
                    (uiop:native-namestring
                     (merge-pathnames "worker.go" *compilation-test-root*)))
            (format nil "  File \"~a\", line 5, in test"
                    (uiop:native-namestring
                     (merge-pathnames "test_sample.py" *compilation-test-root*)))
            (format nil "~a:6:7: F401 ruff"
                    (uiop:native-namestring
                     (merge-pathnames "test_sample.py" *compilation-test-root*)))
            (format nil "error: bad at ~a:7:4"
                    (uiop:native-namestring
                     (merge-pathnames "default.nix" *compilation-test-root*)))))
         (parsed
           (loop :for sample :in samples
                 :for output-line :from 1
                 :count (compilation-parse-diagnostic
                         parser-session sample output-line)))
         (ok (and binding-ok
                  (eq leader 'lem-yath-compile)
                  make
                  pinned-ok
                  drain-ok
                  expected
                  (string= expected (compilation-default-command))
                  (= parsed (length samples)))))
    (compilation-test-log
     "STATIC ~a leader=~a bindings=~a make=~a pinned=~a drain=~a default=~s parsed=~d"
     (if ok "PASS" "FAIL") leader binding-ok (if make "yes" "no")
     pinned-ok drain-ok (compilation-default-command) parsed)))

(defun compilation-test-active-session ()
  (or (buffer-value (current-buffer) :lem-yath-compilation-session)
      *compilation-session*))

(define-command compilation-test-record-state () ()
  (let* ((buffer (current-buffer))
         (session (compilation-test-active-session))
         (local-session
           (buffer-value buffer :lem-yath-compilation-session))
         (diagnostic-index
           (and local-session
                (compilation-diagnostic-index-at-point local-session))))
    (compilation-test-log
     "STATE buffer=~a mode=~a line=~d column=~d diag=~a count=~d session=~a readonly=~a undo=~a drain-positive-underfull=~d"
     (buffer-name buffer)
     (buffer-major-mode buffer)
     (line-number-at-point (current-point))
     (point-charpos (current-point))
     (if diagnostic-index diagnostic-index "none")
     (if session (length (compilation-session-diagnostics session)) 0)
     (if session (compilation-session-state session) "none")
     (buffer-read-only-p buffer)
     (if (buffer-enable-undo-p buffer) "on" "off")
     (if session
         (gethash session *compilation-test-drain-counts* 0)
         0))))

(define-command compilation-test-inspect-ansi () ()
  (let* ((session (compilation-test-active-session))
         (buffer (and session (compilation-session-buffer session)))
         (text (and buffer (compilation-test-buffer-text buffer)))
         (tail (and session (compilation-session-ansi-tail session))))
    (compilation-test-log
     "ANSI tail=~d escape=~a marker=~a styled=~a diagnostics=~d state=~a"
     (if tail (length tail) -1)
     (if (and text (find (code-char 27) text)) "yes" "no")
     (if (and text (search "ANSI-SPLIT" text)) "yes" "no")
     (if (and buffer
              (compilation-test-marker-attribute buffer "ANSI-SPLIT"))
         "yes" "no")
     (if session (length (compilation-session-diagnostics session)) 0)
     (if session (compilation-session-state session) "none"))))

(define-command compilation-test-show-compilation () ()
  (unless (and *compilation-session*
               (compilation-session-owns-buffer-p *compilation-session*))
    (editor-error "No compilation buffer"))
  (let ((window (pop-to-buffer
                 (compilation-session-buffer *compilation-session*))))
    (setf (current-window) window)))

(define-command compilation-test-show-source () ()
  (let ((buffer (find-file-buffer
                 (merge-pathnames "main.c" *compilation-test-root*))))
    (let ((window (pop-to-buffer buffer)))
      (setf (current-window) window))))

(define-command compilation-test-capture-old-session () ()
  (setf *compilation-test-old-session* *compilation-session*
        *compilation-test-old-process*
        (and *compilation-test-old-session*
             (compilation-session-process *compilation-test-old-session*))
        *compilation-test-old-reader-thread*
        (and *compilation-test-old-session*
             (compilation-session-reader-thread
              *compilation-test-old-session*)))
  (compilation-test-log
   "CAPTURE state=~a"
   (and *compilation-test-old-session*
        (compilation-session-state *compilation-test-old-session*))))

(defun compilation-test-report-old-cleanup ()
  "Report teardown evidence retained independently of cleared session slots."
  (let ((old *compilation-test-old-session*))
    (compilation-test-log
     (concatenate
      'string
      "CLEANUP old=~a active=~a process=~a saved-process=~a pid=~a "
      "control=~a reader=~a saved-reader=~a state=~a buffer=~a")
     (if old "yes" "no")
     (if *compilation-session* "set" "none")
     (if (and old (compilation-session-process old)) "set" "nil")
     (if (and *compilation-test-old-process*
              (ignore-errors
                (uiop:process-alive-p *compilation-test-old-process*)))
         "live"
         "dead")
     (if (and old (compilation-session-pid old)) "set" "nil")
     (if (and old (compilation-session-control-armed-p old)) "armed" "nil")
     (if (and old (compilation-session-reader-thread old)) "set" "nil")
     (if (and *compilation-test-old-reader-thread*
              (ignore-errors
                (bt2:thread-alive-p
                 *compilation-test-old-reader-thread*)))
         "live"
         "dead")
     (if old (compilation-session-state old) "none")
     (if (and old
              (deleted-buffer-p (compilation-session-buffer old)))
         "deleted"
         "present"))))

(define-command compilation-test-inject-stale () ()
  (let ((old *compilation-test-old-session*))
    (unless old
      (editor-error "No captured session"))
    (compilation-queue-event
     (lambda ()
       (compilation-deliver-chunk old "INJECTED-STALE\n")
       (compilation-deliver-exit old 99 nil nil)
       (let* ((active *compilation-session*)
              (buffer (and active (compilation-session-buffer active)))
              (text (and buffer (compilation-test-buffer-text buffer))))
         (compilation-test-log
          "STALE active-state=~a fresh=~a injected=~a old-status=~a"
          (and active (compilation-session-state active))
          (if (and text (search "FRESH-ONLY" text)) "yes" "no")
          (if (and text (search "INJECTED-STALE" text)) "yes" "no")
          (if (and text (search "code 99" text)) "yes" "no")))))))

(define-command compilation-test-delete-origin-window () ()
  "Leave the compilation log as the frame's sole ordinary window."
  (let* ((session (compilation-test-active-session))
         (compilation-buffer
           (and session (compilation-session-buffer session)))
         (origin-window
           (and session (compilation-session-origin-window session))))
    (unless (and session
                 (eq (current-buffer) compilation-buffer)
                 origin-window
                 (not (eq origin-window (current-window)))
                 (not (deleted-window-p origin-window)))
      (editor-error "The compilation/source window pair is unavailable"))
    (delete-window origin-window)
    (let* ((windows (window-list))
           (compilation-count
             (count compilation-buffer windows :key #'window-buffer :test #'eq)))
      (compilation-test-log
       "WINDOW-PREP current=~a windows=~d compilation=~d origin-deleted=~a"
       (buffer-name (current-buffer))
       (length windows)
       compilation-count
       (if (deleted-window-p origin-window) "yes" "no")))))

(define-command compilation-test-inspect-windows () ()
  (let* ((session (compilation-test-active-session))
         (compilation-buffer
           (and session (compilation-session-buffer session)))
         (source-buffer
           (find-file-buffer
            (merge-pathnames "main.c" *compilation-test-root*)))
         (windows (window-list))
         (compilation-windows
           (remove-if-not (lambda (window)
                            (eq (window-buffer window) compilation-buffer))
                          windows))
         (source-windows
           (remove-if-not (lambda (window)
                            (eq (window-buffer window) source-buffer))
                          windows)))
    (compilation-test-log
     "WINDOWS current=~a windows=~d compilation=~d source=~d distinct=~a"
     (buffer-name (current-buffer))
     (length windows)
     (length compilation-windows)
     (length source-windows)
     (if (and (= (length compilation-windows) 1)
              (= (length source-windows) 1)
              (not (eq (first compilation-windows)
                       (first source-windows))))
         "yes"
         "no"))))

(define-command compilation-test-no-reader-cleanup () ()
  "Exercise no-reader cleanup, or inspect a previously captured teardown."
  (if *compilation-test-old-session*
      (compilation-test-report-old-cleanup)
      (let* ((buffer (make-buffer " *compilation no-reader test*"
                                  :temporary t
                                  :enable-undo-p nil))
             (session
               (make-compilation-session
                :buffer buffer
                :origin-buffer buffer
                :command "exec sleep 30"
                :directory *compilation-test-root*
                :environment (lint-capture-environment)))
             (stream nil)
             (pid nil)
             (outcome nil))
        (unwind-protect
             (handler-case
                 (progn
                   (setf (buffer-value buffer
                                       :lem-yath-compilation-session)
                         session)
                   (compilation-launch-process session)
                   (setf stream
                         (uiop:process-info-output
                          (compilation-session-process session))
                         pid (compilation-session-pid session)
                         (compilation-session-state session) :running)
                   (compilation-detach-session session :test-no-reader)
                   (setf outcome (compilation-test-process-outcome pid))
                   (compilation-test-log
                    (concatenate
                     'string
                     "NOREADER child=~(~a~) stream=~a process=~a pid=~a "
                     "control=~a reader=~a state=~(~a~)")
                    outcome
                    (if (and stream (open-stream-p stream)) "open" "closed")
                    (if (compilation-session-process session) "set" "nil")
                    (if (compilation-session-pid session) "set" "nil")
                    (if (compilation-session-control-armed-p session)
                        "armed"
                        "nil")
                    (if (compilation-session-reader-thread session)
                        "set"
                        "nil")
                    (compilation-session-state session)))
               (error (condition)
                 (compilation-test-log "NOREADER ERROR ~a" condition)))
          (when (compilation-session-process session)
            (ignore-errors
              (compilation-detach-session session :test-no-reader-cleanup)))
          (unless (deleted-buffer-p buffer)
            (setf (buffer-value buffer :lem-yath-compilation-session) nil)
            (delete-buffer buffer))))))

(define-command compilation-test-provider-and-read-only-contract () ()
  "Seed diagnostic routing, then inspect `go' and result-buffer protections."
  (if (not *compilation-test-provider-seeded-p*)
      (progn
        (setf *compilation-test-provider-seeded-p* t
              *lem-yath-next-error-source* :diagnostic)
        (compilation-test-log "PROVIDER seeded=~a"
                              *lem-yath-next-error-source*))
      (let* ((buffer (current-buffer))
             (before (compilation-test-buffer-text buffer))
             (blocked-p nil))
        (handler-case
            (insert-string (buffer-point buffer) "FORBIDDEN-MUTATION")
          (lem/buffer/errors:read-only-error ()
            (setf blocked-p t)))
        (compilation-test-log
         "CONTRACT provider=~a readonly=~a mutation=~a unchanged=~a undo=~a"
         *lem-yath-next-error-source*
         (buffer-read-only-p buffer)
         (if blocked-p "blocked" "allowed")
         (if (string= before (compilation-test-buffer-text buffer))
             "yes"
             "no")
         (if (buffer-enable-undo-p buffer) "on" "off"))
        (setf *compilation-test-provider-seeded-p* nil))))

(define-command compilation-test-reload () ()
  (handler-case
      (progn
        (load *compilation-test-source*)
        (load *compilation-test-source*)
        (compilation-test-log
         "RELOAD command=~a leader=~a next=~a kill-hook=~d exit-hook=~d"
         (if (get-command 'lem-yath-compile) "yes" "no")
         (leader-binding-command lem-vi-mode:*normal-keymap* "c c")
         (compilation-test-binding *global-keymap* "M-g n")
         (count 'compilation-kill-buffer-hook
                (variable-value 'kill-buffer-hook :global t)
                :key #'car :test #'eq)
         (count 'compilation-exit-editor-hook *exit-editor-hook*
                :key #'car :test #'eq)))
    (error (condition)
      (compilation-test-log "RELOAD ERROR ~a" condition))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      *lem-yath-compilation-mode-keymap*))
  (define-key keymap "F1" 'compilation-test-delete-origin-window)
  (define-key keymap "F2" 'compilation-test-no-reader-cleanup)
  (define-key keymap "F3" 'compilation-test-inspect-windows)
  (define-key keymap "F4" 'compilation-test-reload)
  (define-key keymap "F5" 'compilation-test-static-contract)
  (define-key keymap "F6" 'compilation-test-show-compilation)
  (define-key keymap "F7" 'compilation-test-show-source)
  (define-key keymap "F8" 'compilation-test-capture-old-session)
  (define-key keymap "F9" 'compilation-test-inject-stale)
  (define-key keymap "F10" 'compilation-test-inspect-ansi)
  (define-key keymap "F11"
    'compilation-test-provider-and-read-only-contract)
  (define-key keymap "F12" 'compilation-test-record-state))

(compilation-test-log "READY")
