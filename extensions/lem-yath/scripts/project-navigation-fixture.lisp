(in-package :lem-yath)

;; Keep accepted Consult-project-buffer feedback observable across the tmux
;; report round-trip.  Production retains the audited 30 ms delay.
(setf *jump-feedback-delay-ms* 300)

(defvar *project-navigation-test-report*
  (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_REPORT"))

(defvar *project-navigation-test-phase*
  (or (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_PHASE") "unknown"))

(defvar *project-navigation-test-alpha*
  (canonical-project-directory
   (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_ALPHA")))

(defvar *project-navigation-test-alpha-sibling*
  (canonical-project-directory
    (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING")))

(defvar *project-navigation-test-alpha-alias*
  (uiop:ensure-directory-pathname
   (uiop:parse-native-namestring
    (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_ALPHA_ALIAS"))))

(defvar *project-navigation-test-beta*
  (canonical-project-directory
   (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_BETA")))

(defvar *project-navigation-test-gamma*
  (canonical-project-directory
   (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_GAMMA")))

(defvar *project-navigation-test-submodule-dot*
  (canonical-project-directory
   (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_DOT")))

(defvar *project-navigation-test-submodule-outside*
  (canonical-project-directory
   (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE")))

(defvar *project-navigation-test-submodule-outside-target*
  (canonical-project-directory
   (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET")))

(defvar *project-navigation-test-submodule-cycle*
  (canonical-project-directory
   (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE")))

(defvar *project-navigation-test-submodule-cycle-child*
  (canonical-project-directory
   (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD")))

(defvar *project-navigation-test-request-state*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_REQUEST_STATE")))

(defvar *project-navigation-test-request-helper*
  (uiop:parse-native-namestring
    (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_REQUEST_HELPER")))

(defvar *project-navigation-test-preview-fixtures*
  (uiop:ensure-directory-pathname
   (uiop:parse-native-namestring
    (uiop:getenv "LEM_YATH_PROJECT_NAVIGATION_PREVIEW_FIXTURES"))))

(defvar *project-navigation-test-alpha-buffer* nil)
(defvar *project-navigation-test-sibling-buffer* nil)
(defvar *project-navigation-test-alpha-build-buffer* nil)
(defvar *project-navigation-test-sibling-build-buffer* nil)
(defvar *project-navigation-test-history-sample* 0)
(defvar *project-navigation-test-picker-source-window* nil)
(defvar *project-navigation-test-picker-duplicate-buffer* nil)
(defvar *project-navigation-test-picker-alias-buffer* nil)
(defvar *project-navigation-test-picker-last-preview-buffer* nil)
(defvar *project-navigation-test-picker-preview-buffers* nil)
(defvar *project-navigation-test-picker-history-snapshot* nil)
(defvar *project-navigation-test-picker-buffer-list-snapshot* nil)
(defvar *project-navigation-test-picker-completion-function* nil)
(defvar *project-navigation-test-picker-provider-call-count* 0)
(defvar *project-navigation-test-picker-preview-read-function* nil)
(defvar *project-navigation-test-picker-preview-read-count* 0)
(defvar *project-navigation-test-picker-find-hook-count* 0)
(defvar *project-navigation-test-picker-kill-hook-count* 0)
(defvar *project-navigation-test-picker-state-sample* 0)
(defvar *project-navigation-test-picker-point-position* 7)
(defvar *project-navigation-test-picker-view-position* 1)
(defvar *project-navigation-test-picker-horizontal-scroll* 4)

(defun project-navigation-test-path (root relative)
  (project-absolute-path root relative))

(defun project-navigation-test-log (control &rest arguments)
  (with-open-file (stream *project-navigation-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun project-navigation-test-yes-no (value)
  (if value "yes" "no"))

(defun project-navigation-test-root-label (root)
  (cond
    ((null root) "none")
    ((uiop:pathname-equal root *project-navigation-test-alpha*) "alpha")
    ((uiop:pathname-equal root *project-navigation-test-alpha-sibling*)
     "alpha-sibling")
    ((uiop:pathname-equal root *project-navigation-test-beta*) "beta")
    ((uiop:pathname-equal root *project-navigation-test-gamma*) "gamma")
    (t "other")))

(defun project-navigation-test-root-count (label roots)
  (count label roots :test #'string=))

(defun project-navigation-test-history-pathname ()
  (merge-pathnames "history/projects" (lem-home)))

(define-command lem-yath-test-project-navigation-record-history () ()
  (incf *project-navigation-test-history-sample*)
  (let* ((roots (mapcar #'project-navigation-test-root-label
                        (saved-project-roots)))
         (display (if roots
                      (format nil "~{~a~^,~}" roots)
                      "none")))
    (project-navigation-test-log
     (concatenate
      'string
      "HISTORY phase=~a sample=~d roots=~a count=~d "
      "alpha=~d beta=~d gamma=~d disk=~a")
     *project-navigation-test-phase*
     *project-navigation-test-history-sample*
     display
     (length roots)
     (project-navigation-test-root-count "alpha" roots)
     (project-navigation-test-root-count "beta" roots)
     (project-navigation-test-root-count "gamma" roots)
     (project-navigation-test-yes-no
      (uiop:file-exists-p (project-navigation-test-history-pathname))))))

(defun project-navigation-test-log-history-action (action)
  (let* ((roots (mapcar #'project-navigation-test-root-label
                        (saved-project-roots)))
         (display (if roots
                      (format nil "~{~a~^,~}" roots)
                      "none")))
    (project-navigation-test-log
     "HISTORY-ACTION phase=~a action=~a roots=~a alpha=~d beta=~d gamma=~d"
     *project-navigation-test-phase*
     action
     display
     (project-navigation-test-root-count "alpha" roots)
     (project-navigation-test-root-count "beta" roots)
     (project-navigation-test-root-count "gamma" roots))))

(define-command lem-yath-test-project-navigation-remember-gamma () ()
  (remember-project-root *project-navigation-test-gamma*)
  (project-navigation-test-log-history-action "remember-gamma"))

(define-command lem-yath-test-project-navigation-core-remember-alpha () ()
  (lem-core/commands/project::remember-project
   (uiop:native-namestring *project-navigation-test-alpha*))
  (project-navigation-test-log-history-action "core-remember-alpha"))

(define-command lem-yath-test-project-navigation-core-remember-beta () ()
  (lem-core/commands/project::remember-project
   (uiop:native-namestring *project-navigation-test-beta*))
  (project-navigation-test-log-history-action "core-remember-beta"))

(define-command lem-yath-test-project-navigation-core-forget-beta () ()
  (lem-core/commands/project::forget-project
   (uiop:native-namestring *project-navigation-test-beta*))
  (project-navigation-test-log-history-action "core-forget-beta"))

(define-command lem-yath-test-project-navigation-core-forget-gamma () ()
  (lem-core/commands/project::forget-project
   (uiop:native-namestring *project-navigation-test-gamma*))
  (project-navigation-test-log-history-action "core-forget-gamma"))

(defun project-navigation-test-signals-error-p (function)
  (handler-case
      (progn (funcall function) nil)
    (error () t)))

(define-command lem-yath-test-project-navigation-history-parser () ()
  (project-navigation-test-log
   "HISTORY-PARSER nil=~a strings=~a displaced=~a dispatch=~a mismatch=~a"
   (project-navigation-test-yes-no
    (null (parse-project-history-text (format nil "NIL~%"))))
   (project-navigation-test-yes-no
    (equal (parse-project-history-text "(\"/a/\" \"/b/\")")
           '("/a/" "/b/")))
   (project-navigation-test-yes-no
    (equal (parse-project-history-text
            "(#A((3) BASE-CHAR . \"/a/\"))")
           '("/a/")))
   (project-navigation-test-yes-no
    (project-navigation-test-signals-error-p
     (lambda () (parse-project-history-text "(#.(error \"unsafe\"))"))))
   (project-navigation-test-yes-no
    (project-navigation-test-signals-error-p
     (lambda ()
       (parse-project-history-text
        "(#A((2) BASE-CHAR . \"/a/\"))"))))))

(define-command lem-yath-test-project-navigation-history-refusal () ()
  (let ((rejected
          (project-navigation-test-signals-error-p
           (lambda ()
             (project-history-add
              (uiop:native-namestring
               *project-navigation-test-gamma*))))))
    (project-navigation-test-log "HISTORY-REFUSAL rejected=~a"
                                 (project-navigation-test-yes-no rejected))))

(define-command lem-yath-test-project-navigation-open-beta () ()
  (find-file
   (project-navigation-test-path
    *project-navigation-test-beta* "beta-main.txt"))
  (project-navigation-test-log "OPEN label=beta root=~a file=beta-main.txt"
                               (project-navigation-test-root-label
                                (lem-yath-project-root-for-directory
                                 (buffer-directory (current-buffer))))))

(defun project-navigation-test-leader-binding-p (keymap keys command)
  (eq command (leader-binding-command keymap keys)))

(defun project-navigation-test-key-bound-p (keymap keys)
  (not (null (lem-core::keymap-find keymap
                                    (lem-core::parse-keyspec keys)))))

(define-command lem-yath-test-project-navigation-static-checks () ()
  (let* ((normal
          (and
           (project-navigation-test-leader-binding-p
            lem-vi-mode:*normal-keymap* "p f" 'lem-yath-project-find-file)
           (project-navigation-test-leader-binding-p
            lem-vi-mode:*normal-keymap* "p g" 'lem-yath-project-grep)
           (project-navigation-test-leader-binding-p
            lem-vi-mode:*normal-keymap* "p p" 'lem-yath-project-switch)
           (project-navigation-test-leader-binding-p
            lem-vi-mode:*normal-keymap* "Space" 'lem-yath-project-buffers)))
        (visual
          (and
           (project-navigation-test-leader-binding-p
            lem-vi-mode:*visual-keymap* "p f" 'lem-yath-project-find-file)
           (project-navigation-test-leader-binding-p
            lem-vi-mode:*visual-keymap* "p g" 'lem-yath-project-grep)
           (project-navigation-test-leader-binding-p
            lem-vi-mode:*visual-keymap* "p p" 'lem-yath-project-switch)
           (project-navigation-test-leader-binding-p
            lem-vi-mode:*visual-keymap* "Space" 'lem-yath-project-buffers)))
         (project-dispatch (project-switch-keymap))
         (emacs-dispatch
           (and (every (lambda (key)
                         (project-navigation-test-key-bound-p
                          project-dispatch key))
                       '("f" "g" "d" "v" "e" "o"))
                (notany (lambda (key)
                          (project-navigation-test-key-bound-p
                           project-dispatch key))
                        '("s" "x")))))
    (project-navigation-test-log
     (concatenate
      'string
      "STATIC normal=~a visual=~a pf=~a pg=~a pp=~a space=~a "
      "leader-tree=~a emacs-dispatch=~a")
     (project-navigation-test-yes-no normal)
     (project-navigation-test-yes-no visual)
     (project-navigation-test-yes-no
      (project-navigation-test-leader-binding-p
       lem-vi-mode:*normal-keymap* "p f" 'lem-yath-project-find-file))
     (project-navigation-test-yes-no
      (project-navigation-test-leader-binding-p
       lem-vi-mode:*normal-keymap* "p g" 'lem-yath-project-grep))
     (project-navigation-test-yes-no
      (project-navigation-test-leader-binding-p
       lem-vi-mode:*normal-keymap* "p p" 'lem-yath-project-switch))
     (project-navigation-test-yes-no
      (project-navigation-test-leader-binding-p
       lem-vi-mode:*normal-keymap* "Space" 'lem-yath-project-buffers))
     (project-navigation-test-yes-no (evil-leader-bindings-ok-p))
     (project-navigation-test-yes-no emacs-dispatch))
    (project-navigation-test-log
     (concatenate
      'string
      "REGEXP escaped-alternation=~a raw-alternation=~a "
      "leading-close-class=~a escaped-close-class=~a negated-close-class=~a")
     (project-navigation-test-yes-no
      (string= "foo|bar" (project-regexp-to-extended "foo\\|bar")))
     (project-navigation-test-yes-no
      (string= "foo\\|bar" (project-regexp-to-extended "foo|bar")))
     (project-navigation-test-yes-no
      (string= "[]()]" (project-regexp-to-extended "[]()]")))
     (project-navigation-test-yes-no
      (string= "[\\]]" (project-regexp-to-extended "[\\]]")))
     (project-navigation-test-yes-no
      (string= "[^]]" (project-regexp-to-extended "[^]]"))))))

(defun project-navigation-test-marker (name)
  (merge-pathnames name *project-navigation-test-request-state*))

(defun project-navigation-test-touch-marker (name)
  (with-open-file (stream (project-navigation-test-marker name)
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (declare (ignore stream))))

(defun project-navigation-test-marker-exists-p (name)
  (not (null (uiop:file-exists-p (project-navigation-test-marker name)))))

(defun project-navigation-test-wait-for-marker (name &optional (seconds 15))
  (loop :repeat (* seconds 100)
        :when (project-navigation-test-marker-exists-p name)
          :return t
        :do (sleep 0.01)
        :finally (return nil)))

(defun project-navigation-test-clear-request-markers ()
  (dolist (name '("a-entered" "a-release" "a-attempted" "a-started"
                  "a-finished" "b-started" "b-release"))
    (ignore-errors (delete-file (project-navigation-test-marker name)))))

(defun project-navigation-test-run-request-helper (label request)
  (let ((bash (or (executable-find "bash")
                  (error "bash is unavailable"))))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (list (namestring bash)
               (uiop:native-namestring
                *project-navigation-test-request-helper*)
               label
               (project-native-directory
                *project-navigation-test-request-state*))
         :request request)
      (declare (ignore output))
      (unless (and (integerp status) (zerop status))
        (error "Request helper ~a failed: ~a" label error-output)))))

(defun project-navigation-test-request-process (request)
  (bt2:with-lock-held ((project-request-lock request))
    (project-request-process request)))

(define-command lem-yath-test-project-navigation-cancellation () ()
  "Exercise two real file-request workers across a deterministic launch race."
  (project-navigation-test-clear-request-markers)
  (let ((original-candidates (symbol-function 'project-file-candidates))
        (original-prompt
          (symbol-function 'prompt-for-project-file-candidates))
        (request-a nil)
        (request-b nil)
        (seen-a nil)
        (seen-b nil)
        (thread-a nil)
        (thread-b nil)
        (published '())
        (request-a-error nil)
        (request-b-error nil)
        (a-cancelled nil)
        (b-live nil)
        (b-owned nil))
    (labels
        ((restore-functions ()
           (setf (symbol-function 'project-file-candidates)
                 original-candidates
                 (symbol-function 'prompt-for-project-file-candidates)
                 original-prompt))
         (record-result ()
           (restore-functions)
           (project-navigation-test-log
            (concatenate
             'string
             "REQUEST-RACE a-cancelled=~a b-live=~a a-launch=~a "
             "b-owned=~a a-published=~a b-published=~a propagated=~a")
            (project-navigation-test-yes-no a-cancelled)
            (project-navigation-test-yes-no b-live)
            (project-navigation-test-yes-no
             (project-navigation-test-marker-exists-p "a-started"))
            (project-navigation-test-yes-no b-owned)
            (project-navigation-test-yes-no
             (member "request-a.txt" published :test #'string=))
            (project-navigation-test-yes-no
             (member "request-b.txt" published :test #'string=))
            (project-navigation-test-yes-no
             (and (eq seen-a request-a) (eq seen-b request-b)))))
         (fail-test (condition)
           (project-navigation-test-touch-marker "a-release")
           (project-navigation-test-touch-marker "b-release")
           (when request-a
             (ignore-errors (cancel-project-request request-a)))
           (when request-b
             (ignore-errors (cancel-project-request request-b)))
           (when thread-a
             (ignore-errors (bt2:join-thread thread-a)))
           (when thread-b
             (ignore-errors (bt2:join-thread thread-b)))
           (restore-functions)
           (project-navigation-test-log
            "REQUEST-RACE a-cancelled=no b-live=no a-launch=no b-owned=no a-published=no b-published=no propagated=no")
           (project-navigation-test-log "REQUEST-RACE-ERROR ~a" condition))
         (collect-candidates (root &key request)
           (cond
             ((uiop:pathname-equal
               (canonical-project-directory root)
               *project-navigation-test-alpha*)
              (setf seen-a request)
              (project-navigation-test-touch-marker "a-entered")
              (unless (project-navigation-test-wait-for-marker "a-release")
                (error "Timed out waiting to release request A"))
              (project-navigation-test-touch-marker "a-attempted")
              (unwind-protect
                   (handler-case
                       (progn
                         (project-navigation-test-run-request-helper "a" request)
                         '("request-a.txt"))
                     (error (condition)
                       (setf request-a-error (princ-to-string condition))
                       (error condition)))
                (project-navigation-test-touch-marker "a-finished")))
             ((uiop:pathname-equal
               (canonical-project-directory root)
              *project-navigation-test-beta*)
              (setf seen-b request)
              (handler-case
                  (progn
                    (project-navigation-test-run-request-helper "b" request)
                    '("request-b.txt"))
                (error (condition)
                  (setf request-b-error (princ-to-string condition))
                  (error condition))))
             (t
              (funcall original-candidates root :request request))))
         (record-prompt (root files)
           (declare (ignore root))
           (when files
             (push (first files) published))
           nil))
      (handler-case
          (progn
            (setf (symbol-function 'project-file-candidates)
                  #'collect-candidates
                  (symbol-function 'prompt-for-project-file-candidates)
                  #'record-prompt)
            (setf thread-a
                  (project-find-file-at-root *project-navigation-test-alpha*)
                  request-a *active-project-file-request*)
            (unless (project-navigation-test-wait-for-marker "a-entered")
              (error "Request A never entered candidate collection"))
            (cancel-project-request request-a)
            (setf a-cancelled (project-request-cancelled-p request-a)
                  thread-b
                  (project-find-file-at-root *project-navigation-test-beta*)
                  request-b *active-project-file-request*)
            (unless (project-navigation-test-wait-for-marker "b-started")
              (error
               (concatenate
                'string
                "Request B never launched its helper process "
                "(cancelled=~s active=~s process=~s a-error=~s b-error=~s)")
               (and request-b (project-request-cancelled-p request-b))
               (eq request-b *active-project-file-request*)
               (and request-b (project-request-process request-b))
               request-a-error
               request-b-error))
            (let ((process-b
                    (project-navigation-test-request-process request-b)))
              (setf b-live (and process-b (uiop:process-alive-p process-b)))
              (project-navigation-test-touch-marker "a-release")
              (unless
                  (loop :repeat 500
                        :when (or
                               (project-navigation-test-marker-exists-p
                                "a-started")
                               (project-navigation-test-marker-exists-p
                                "a-finished"))
                          :return t
                        :do (sleep 0.01)
                        :finally (return nil))
                (error "Request A never attempted its late launch"))
              ;; Re-cancelling A while B is live must only inspect A's process.
              (cancel-project-request request-a)
              (sleep 0.05)
              (setf b-owned
                    (and process-b
                         (eq process-b
                             (project-navigation-test-request-process
                              request-b))
                         (uiop:process-alive-p process-b))))
            (project-navigation-test-touch-marker "a-release")
            (project-navigation-test-touch-marker "b-release")
            (bt2:make-thread
             (lambda ()
               (bt2:join-thread thread-a)
               (bt2:join-thread thread-b)
               ;; Both workers enqueue delivery before they exit.  Queue the
               ;; recorder behind those deliveries so publication is observed.
               (send-event (lambda () (send-event #'record-result))))
             :name "lem-yath/test-project-request-race"))
        (error (condition)
          (fail-test condition))))))

(defun project-navigation-test-command-directory (arguments options)
  (let ((position (position "-C" arguments :test #'string=)))
    (cond
      ((and position (nth (1+ position) arguments))
       (canonical-project-directory (nth (1+ position) arguments)))
      ((getf options :directory)
       (canonical-project-directory (getf options :directory))))))

(defun project-navigation-test-bounded-git-files (root)
  "Run submodule enumeration while bounding and counting canonical visits."
  (let ((original (symbol-function 'run-project-program))
        (visits (make-hash-table :test #'equal))
        (launches 0)
        (capped nil)
        (failure nil)
        (files nil))
    (unwind-protect
         (progn
           (setf
            (symbol-function 'run-project-program)
            (lambda (arguments &rest options)
              (when (member "ls-files" arguments :test #'string=)
                (alexandria:when-let
                    ((directory
                       (project-navigation-test-command-directory
                        arguments options)))
                  (incf launches)
                  (incf (gethash (project-native-directory directory)
                                 visits 0))
                  (when (> launches 8)
                    (setf capped t)
                    (error "Submodule recursion exceeded the test bound"))))
              (apply original arguments options)))
           (handler-case
               (setf files (git-project-files root))
             (error (condition)
               (setf failure condition))))
      (setf (symbol-function 'run-project-program) original))
    (values files visits capped failure)))

(defun project-navigation-test-visit-count (root visits)
  (gethash (project-native-directory root) visits 0))

(defun project-navigation-test-visits-once-p (visits)
  (loop :for count :being :the :hash-values :of visits
        :always (= count 1)))

(define-command lem-yath-test-project-navigation-submodule-safety () ()
  (multiple-value-bind (dot-files dot-visits dot-capped dot-failure)
      (project-navigation-test-bounded-git-files
       *project-navigation-test-submodule-dot*)
    (declare (ignore dot-files))
    (multiple-value-bind
          (outside-files outside-visits outside-capped outside-failure)
        (project-navigation-test-bounded-git-files
         *project-navigation-test-submodule-outside*)
      (multiple-value-bind
            (cycle-files cycle-visits cycle-capped cycle-failure)
          (project-navigation-test-bounded-git-files
           *project-navigation-test-submodule-cycle*)
        (let ((dot-safe
                (and (null dot-failure)
                     (not dot-capped)
                     (= 1 (project-navigation-test-visit-count
                           *project-navigation-test-submodule-dot*
                           dot-visits))))
              (outside-safe
                (and (null outside-failure)
                     (not outside-capped)
                     (zerop
                      (project-navigation-test-visit-count
                       *project-navigation-test-submodule-outside-target*
                       outside-visits))
                     (notany
                      (lambda (file)
                        (alexandria:starts-with-subseq "escape/" file))
                      outside-files)))
              (cycle-safe
                (and (null cycle-failure)
                     (not cycle-capped)
                     (= 1 (project-navigation-test-visit-count
                           *project-navigation-test-submodule-cycle*
                           cycle-visits))
                     (= 1 (project-navigation-test-visit-count
                           *project-navigation-test-submodule-cycle-child*
                           cycle-visits))
                     (member "child/child.txt" cycle-files :test #'string=)))
              (visited-once
                (and (project-navigation-test-visits-once-p dot-visits)
                     (project-navigation-test-visits-once-p outside-visits)
                     (project-navigation-test-visits-once-p cycle-visits)))
              (bounded
                (and (null dot-failure) (not dot-capped)
                     (null outside-failure) (not outside-capped)
                     (null cycle-failure) (not cycle-capped))))
          (project-navigation-test-log
           "SUBMODULE-SAFETY dot=~a outside=~a cycle=~a visited-once=~a bounded=~a"
           (project-navigation-test-yes-no dot-safe)
           (project-navigation-test-yes-no outside-safe)
           (project-navigation-test-yes-no cycle-safe)
           (project-navigation-test-yes-no visited-once)
           (project-navigation-test-yes-no bounded)))))))

(defun project-navigation-test-delete-buffer-if-present (name)
  (alexandria:when-let ((buffer (get-buffer name)))
    (delete-buffer buffer)))

(defun project-navigation-test-make-directory-buffer (name directory text)
  (project-navigation-test-delete-buffer-if-present name)
  (let ((buffer (make-buffer name :directory
                             (project-native-directory directory))))
    (insert-string (buffer-end-point buffer) text)
    buffer))

(define-command lem-yath-test-project-navigation-setup-buffers () ()
  (setf *project-navigation-test-alpha-buffer*
        (find-file-buffer
         (project-navigation-test-path
          *project-navigation-test-alpha* "alpha-main.txt"))
        *project-navigation-test-sibling-buffer*
        (find-file-buffer
         (project-navigation-test-path
          *project-navigation-test-alpha-sibling* "sibling-only.txt"))
        *project-navigation-test-alpha-build-buffer*
        (project-navigation-test-make-directory-buffer
         "*alpha-build*"
         (project-navigation-test-path
          *project-navigation-test-alpha* "build/")
         "ALPHA NONFILE BUILD BUFFER")
        *project-navigation-test-sibling-build-buffer*
        (project-navigation-test-make-directory-buffer
         "*sibling-build*"
         (project-navigation-test-path
          *project-navigation-test-alpha-sibling* "build/")
         "SIBLING NONFILE BUILD BUFFER"))
  (switch-to-buffer *project-navigation-test-alpha-buffer*)
  (project-navigation-test-log
   "SETUP current=alpha alpha-file=yes sibling-file=yes alpha-nonfile=yes sibling-nonfile=yes"))

(defun project-navigation-test-add-recent-file (pathname)
  (lem/common/history:add-history
   (lem-core/commands/file:file-history)
   (uiop:native-namestring pathname)
   :allow-duplicates nil
   :move-to-top t
   :test #'string=))

(defun project-navigation-test-picker-find-hook (buffer)
  (declare (ignore buffer))
  (incf *project-navigation-test-picker-find-hook-count*))

(defun project-navigation-test-picker-kill-hook (buffer)
  (when (alexandria:starts-with-subseq " Preview:" (buffer-name buffer))
    (incf *project-navigation-test-picker-kill-hook-count*)))

(defun project-navigation-test-position-point (point position)
  (move-to-position
   point
   (max 1
        (min position
             (position-at-point
              (buffer-end-point (point-buffer point)))))))

(defun project-navigation-test-reset-picker-origin-state ()
  (switch-to-buffer *project-navigation-test-alpha-buffer*)
  (setf *project-navigation-test-picker-source-window* (current-window))
  (project-navigation-test-position-point
   (buffer-point *project-navigation-test-alpha-buffer*)
   *project-navigation-test-picker-point-position*)
  (project-navigation-test-position-point
   (window-view-point *project-navigation-test-picker-source-window*)
   *project-navigation-test-picker-view-position*)
  (setf (window-parameter
         *project-navigation-test-picker-source-window*
         'lem-core::horizontal-scroll-start)
        *project-navigation-test-picker-horizontal-scroll*))

(defun project-navigation-test-reset-picker-invariants ()
  (setf *project-navigation-test-picker-last-preview-buffer* nil
        *project-navigation-test-picker-preview-buffers* nil
        *project-navigation-test-picker-history-snapshot*
        (copy-list (lem-core/commands/file:recent-files))
        *project-navigation-test-picker-buffer-list-snapshot*
        (copy-list (buffer-list))))

(define-command lem-yath-test-project-navigation-setup-picker () ()
  (project-navigation-test-delete-buffer-if-present "src/recent-preview.txt")
  (project-navigation-test-delete-buffer-if-present "*alias-build*")
  (setf *project-navigation-test-picker-duplicate-buffer*
        (project-navigation-test-make-directory-buffer
         "src/recent-preview.txt"
         *project-navigation-test-alpha*
         "DUPLICATE PROJECT BUFFER")
        *project-navigation-test-picker-alias-buffer*
        (make-buffer
         "*alias-build*"
         :directory
         (uiop:native-namestring
          *project-navigation-test-alpha-alias*)))
  (insert-string
   (buffer-end-point *project-navigation-test-picker-alias-buffer*)
   "ALIASED PROJECT BUFFER")
  (project-navigation-test-add-recent-file
   (merge-pathnames "src/recent-preview.txt"
                    *project-navigation-test-alpha-alias*))
  (project-navigation-test-add-recent-file
   (project-navigation-test-path
    *project-navigation-test-alpha* "src/lexical-out.txt"))
  (project-navigation-test-add-recent-file
   (project-navigation-test-path
    *project-navigation-test-alpha* "src/recent-preview.txt"))
  (lem/common/history:save-file (lem-core/commands/file:file-history))
  (setf *project-navigation-test-picker-find-hook-count* 0
        *project-navigation-test-picker-kill-hook-count* 0
        *project-navigation-test-picker-provider-call-count* 0
        *project-navigation-test-picker-preview-read-count* 0
        *project-navigation-test-picker-point-position* 7
        *project-navigation-test-picker-state-sample* 0)
  (unless *project-navigation-test-picker-completion-function*
    (setf *project-navigation-test-picker-completion-function*
          (symbol-function 'project-picker-completion-items)))
  (setf (symbol-function 'project-picker-completion-items)
        (lambda (session input)
          (incf *project-navigation-test-picker-provider-call-count*)
          (funcall *project-navigation-test-picker-completion-function*
                   session input)))
  (unless *project-navigation-test-picker-preview-read-function*
    (setf *project-navigation-test-picker-preview-read-function*
          (symbol-function 'project-picker-read-preview-text)))
  (setf (symbol-function 'project-picker-read-preview-text)
        (lambda (pathname)
          (incf *project-navigation-test-picker-preview-read-count*)
          (funcall *project-navigation-test-picker-preview-read-function*
                   pathname)))
  (remove-hook *find-file-hook* 'project-navigation-test-picker-find-hook)
  (add-hook *find-file-hook* 'project-navigation-test-picker-find-hook)
  (remove-hook (variable-value 'kill-buffer-hook :global t)
               'project-navigation-test-picker-kill-hook)
  (add-hook (variable-value 'kill-buffer-hook :global t)
            'project-navigation-test-picker-kill-hook)
  (project-navigation-test-reset-picker-origin-state)
  (project-navigation-test-reset-picker-invariants)
  (project-navigation-test-log
   "PICKER-SETUP duplicate=~a recent=~a lexical=~a alias-buffer=~a hooks=~d"
   (project-navigation-test-yes-no
    (and *project-navigation-test-picker-duplicate-buffer*
         (null (buffer-filename
                *project-navigation-test-picker-duplicate-buffer*))))
   (project-navigation-test-yes-no
    (member
     (uiop:native-namestring
      (project-navigation-test-path
       *project-navigation-test-alpha* "src/recent-preview.txt"))
     *project-navigation-test-picker-history-snapshot*
     :test #'string=))
   (project-navigation-test-yes-no
    (member
     (uiop:native-namestring
      (project-navigation-test-path
       *project-navigation-test-alpha* "src/lexical-out.txt"))
     *project-navigation-test-picker-history-snapshot*
     :test #'string=))
   (project-navigation-test-yes-no
    *project-navigation-test-picker-alias-buffer*)
   *project-navigation-test-picker-find-hook-count*))

(define-command lem-yath-test-project-navigation-bounded-preview () ()
  (let ((small
          (project-picker-read-preview-text
           (merge-pathnames "small.txt"
                            *project-navigation-test-preview-fixtures*)))
        (large
          (project-picker-read-preview-text
           (merge-pathnames "large.txt"
                            *project-navigation-test-preview-fixtures*)))
        (binary
          (project-picker-read-preview-text
           (merge-pathnames "binary.bin"
                            *project-navigation-test-preview-fixtures*)))
        (fifo
          (project-picker-read-preview-text
           (merge-pathnames "fifo"
                            *project-navigation-test-preview-fixtures*))))
    (project-navigation-test-log
     "PICKER-BOUNDED small=~a large=~a binary=~a fifo=~a"
     (project-navigation-test-yes-no
      (string= small (format nil "line one~%line two~%")))
     (project-navigation-test-yes-no (null large))
     (project-navigation-test-yes-no (null binary))
     (project-navigation-test-yes-no (null fifo)))))

(define-command lem-yath-test-project-navigation-reset-picker-origin () ()
  (project-navigation-test-reset-picker-origin-state)
  (project-navigation-test-reset-picker-invariants)
  (project-navigation-test-log "PICKER-ORIGIN reset=yes"))

(define-command lem-yath-test-project-navigation-edit-picker-origin () ()
  (let ((text "ASYNC "))
    (with-current-buffer *project-navigation-test-alpha-buffer*
      (insert-string (buffer-start-point (current-buffer)) text))
    (incf *project-navigation-test-picker-point-position* (length text))
    (project-navigation-test-log
     "PICKER-EDIT point=~d view=~d"
     *project-navigation-test-picker-point-position*
     *project-navigation-test-picker-view-position*)))

(define-command lem-yath-test-project-navigation-seed-many-recent () ()
  (let ((target
          (project-navigation-test-path
           *project-navigation-test-alpha* "src/deep-recent-target.txt")))
    (project-navigation-test-add-recent-file target)
    (dotimes (index 130)
      (project-navigation-test-add-recent-file
       (project-navigation-test-path
        *project-navigation-test-alpha*
        (format nil "src/stale-recent-~3,'0d.txt" index))))
    (lem/common/history:save-file (lem-core/commands/file:file-history))
    (project-navigation-test-reset-picker-origin-state)
    (project-navigation-test-reset-picker-invariants)
    (let* ((history-index
             (position (uiop:native-namestring target)
                       *project-navigation-test-picker-history-snapshot*
                       :test #'string=))
           (picker-files
             (project-picker-recent-files *project-navigation-test-alpha*))
           (candidate-index
             (position target picker-files
                       :test #'project-picker-file-equal-p)))
      (project-navigation-test-log
       (concatenate
        'string
        "PICKER-MANY history-index=~d candidate-index=~d "
        "beyond-hundred=~a")
       (or history-index -1)
       (or candidate-index -1)
       (project-navigation-test-yes-no
        (and candidate-index (> candidate-index 100)))))))

(define-command lem-yath-test-project-navigation-preview-read-error () ()
  (let* ((session (make-project-picker-session :active-p t))
         (kill-before *project-navigation-test-picker-kill-hook-count*)
         (pathname
           (project-navigation-test-path
            *project-navigation-test-alpha* "src/missing-preview-file.txt"))
         (name " Preview:missing-preview-file.txt")
         (result (project-picker-read-preview-buffer session pathname))
         (remaining (get-buffer name)))
    (let ((listed (and remaining (member remaining (buffer-list) :test #'eq))))
      (project-navigation-test-log
       (concatenate
        'string
        "PICKER-PREVIEW-ERROR result=~a slot=~a remaining=~a "
        "listed=~a kill-hooks=~d")
       (if (null result) "nil" "non-nil")
       (if (null (project-picker-session-preview-buffer session))
           "nil"
           "live")
       (project-navigation-test-yes-no remaining)
       (project-navigation-test-yes-no listed)
       (- *project-navigation-test-picker-kill-hook-count* kill-before))
      (when remaining
        (ignore-errors
          (with-global-variable-value (kill-buffer-hook nil)
            (delete-buffer remaining)))))))

(defun project-navigation-test-picker-source-label (buffer)
  (cond
    ((null buffer) "none")
    ((eq buffer *project-navigation-test-alpha-buffer*) "origin")
    ((eq buffer *project-navigation-test-picker-duplicate-buffer*) "duplicate")
    ((eq buffer *project-navigation-test-alpha-build-buffer*) "alpha-build")
    ((buffer-temporary-p buffer) "temporary")
    ((and (buffer-filename buffer)
          (project-picker-file-equal-p
           (buffer-filename buffer)
           (project-navigation-test-path
            *project-navigation-test-alpha* "src/recent-preview.txt")))
     "normal-file")
    (t "other")))

(define-command lem-yath-test-project-navigation-picker-state () ()
  (incf *project-navigation-test-picker-state-sample*)
  (let* ((prompt (lem/prompt-window:current-prompt-window))
         (input
           (if prompt
               (handler-case
                   (lem/prompt-window::get-input-string)
                 (error () "unavailable"))
               "none"))
         (item
           (and prompt
                (handler-case
                    (completion-focused-item)
                  (error () nil))))
         (focus
           (if item
               (lem/completion-mode:completion-item-label item)
               "none"))
         (group
           (if item
               (or (lem/completion-mode:completion-item-group item) "none")
               "none"))
         (window *project-navigation-test-picker-source-window*)
         (buffer (and (project-picker-live-window-p window)
                      (window-buffer window)))
         (temporary (and buffer (buffer-temporary-p buffer)))
         (point-position
           (and window
                (project-picker-live-window-p window)
                (position-at-point (window-point window))))
         (view-position
           (and window
                (project-picker-live-window-p window)
                (position-at-point (window-view-point window))))
         (horizontal
           (and window
                (project-picker-live-window-p window)
                (window-parameter window 'lem-core::horizontal-scroll-start)))
         (exact
           (and (eq buffer *project-navigation-test-alpha-buffer*)
                (= point-position
                   *project-navigation-test-picker-point-position*)
                (= view-position
                   *project-navigation-test-picker-view-position*)
                (eql horizontal
                     *project-navigation-test-picker-horizontal-scroll*)))
         (pulse *jump-feedback-current-pulse*)
         (pulse-overlay
           (and pulse
                (jump-feedback-pulse-active-p pulse)
                (jump-feedback-pulse-overlay pulse))))
    (when temporary
      (setf *project-navigation-test-picker-last-preview-buffer* buffer)
      (pushnew buffer *project-navigation-test-picker-preview-buffers*
               :test #'eq))
    (project-navigation-test-log
     (concatenate
      'string
      "PICKER-STATE sample=~d prompt=~a input=~s focus=~s group=~s calls=~d reads=~d "
      "source=~a temp=~a temp-listed=~a "
      "preview-deleted=~a hooks=~d kill-hooks=~d history-same=~a exact=~a "
      "pulse=~a pulse-source=~a pulse-line=~a "
      "mru-same=~a point=~a view=~a horizontal=~a")
     *project-navigation-test-picker-state-sample*
     (project-navigation-test-yes-no prompt)
     input
     focus
     group
     *project-navigation-test-picker-provider-call-count*
     *project-navigation-test-picker-preview-read-count*
     (project-navigation-test-picker-source-label buffer)
     (project-navigation-test-yes-no temporary)
     (project-navigation-test-yes-no
      (and temporary (member buffer (buffer-list) :test #'eq)))
     (project-navigation-test-yes-no
      (and *project-navigation-test-picker-preview-buffers*
           (every #'deleted-buffer-p
                  *project-navigation-test-picker-preview-buffers*)))
     *project-navigation-test-picker-find-hook-count*
     *project-navigation-test-picker-kill-hook-count*
     (project-navigation-test-yes-no
      (equal *project-navigation-test-picker-history-snapshot*
             (lem-core/commands/file:recent-files)))
     (project-navigation-test-yes-no exact)
     (project-navigation-test-yes-no pulse-overlay)
     (project-navigation-test-picker-source-label
      (and pulse-overlay (overlay-buffer pulse-overlay)))
     (or (and pulse-overlay
              (line-number-at-point (overlay-start pulse-overlay)))
         "none")
     (project-navigation-test-yes-no
      (equal *project-navigation-test-picker-buffer-list-snapshot*
             (buffer-list)))
     (or point-position "none")
     (or view-position "none")
     (or horizontal "none"))))

(define-command lem-yath-test-project-navigation-finish-picker () ()
  (when *project-navigation-test-picker-completion-function*
    (setf (symbol-function 'project-picker-completion-items)
          *project-navigation-test-picker-completion-function*
          *project-navigation-test-picker-completion-function* nil))
  (when *project-navigation-test-picker-preview-read-function*
    (setf (symbol-function 'project-picker-read-preview-text)
          *project-navigation-test-picker-preview-read-function*
          *project-navigation-test-picker-preview-read-function* nil))
  (remove-hook *find-file-hook* 'project-navigation-test-picker-find-hook)
  (remove-hook (variable-value 'kill-buffer-hook :global t)
               'project-navigation-test-picker-kill-hook)
  (project-navigation-test-reset-picker-origin-state)
  (project-navigation-test-log
   "PICKER-FINISH hooks=~d kill-hooks=~d"
   *project-navigation-test-picker-find-hook-count*
   *project-navigation-test-picker-kill-hook-count*))

(define-command lem-yath-test-project-navigation-record-candidates () ()
  (let* ((files (project-file-candidates *project-navigation-test-alpha*))
         (unique (= (length files)
                    (length (remove-duplicates files :test #'string=))))
         (relative (every #'safe-project-relative-path-p files))
         (submodule-file "vendor/child/nested/child-file.txt")
         (submodule-gitlink "vendor/child")
         (submodule-directory
           (project-navigation-test-path
            *project-navigation-test-alpha* "vendor/child/nested/"))
         (submodule-root
           (lem-yath-project-root-for-directory submodule-directory)))
    (project-navigation-test-log
     (concatenate
      'string
      "CANDIDATES root=alpha tracked=~a untracked=~a ignored=~a "
      "ignored-tree=~a git-internal=~a sibling=~a relative=~a unique=~a")
     (project-navigation-test-yes-no
      (member "src/tracked-target.txt" files :test #'string=))
     (project-navigation-test-yes-no
      (member "src/untracked-target.txt" files :test #'string=))
     (project-navigation-test-yes-no
      (member "ignored-target.txt" files :test #'string=))
     (project-navigation-test-yes-no
      (member "ignored-dir/secret.txt" files :test #'string=))
     (project-navigation-test-yes-no
      (some (lambda (file)
              (alexandria:starts-with-subseq ".git/" file))
            files))
     (project-navigation-test-yes-no
      (member "sibling-only.txt" files :test #'string=))
     (project-navigation-test-yes-no relative)
     (project-navigation-test-yes-no unique))
    (project-navigation-test-log
     "SUBMODULE file=~a gitlink=~a merged-root=~a"
     (project-navigation-test-yes-no
      (member submodule-file files :test #'string=))
     (project-navigation-test-yes-no
      (member submodule-gitlink files :test #'string=))
     (project-navigation-test-root-label submodule-root))))

(define-command lem-yath-test-project-navigation-record-buffers () ()
  (let* ((buffers (project-buffers-at-root *project-navigation-test-alpha*))
         (names (mapcar #'buffer-name buffers))
         (alpha-file
           (member (buffer-name *project-navigation-test-alpha-buffer*)
                   names :test #'string=))
         (alpha-nonfile (member "*alpha-build*" names :test #'string=))
         (sibling-file
           (member (buffer-name *project-navigation-test-sibling-buffer*)
                   names :test #'string=))
         (sibling-nonfile (member "*sibling-build*" names :test #'string=)))
    (project-navigation-test-log
     (concatenate
      'string
      "BUFFERS root=alpha alpha-file=~a alpha-nonfile=~a sibling-file=~a "
      "sibling-nonfile=~a fileless=~a exact=~a")
     (project-navigation-test-yes-no alpha-file)
     (project-navigation-test-yes-no alpha-nonfile)
     (project-navigation-test-yes-no sibling-file)
     (project-navigation-test-yes-no sibling-nonfile)
     (project-navigation-test-yes-no
      (and *project-navigation-test-alpha-build-buffer*
           (null (buffer-filename
                  *project-navigation-test-alpha-build-buffer*))))
     (project-navigation-test-yes-no
      (and alpha-file alpha-nonfile
           (not sibling-file) (not sibling-nonfile)
           (= 2 (length buffers)))))))

(defun project-navigation-test-relative-path (path root)
  (if (null path)
      "none"
      (let* ((root (project-native-directory root))
             (path (uiop:native-namestring (truename path)))
             (root-without-slash (string-right-trim "/" root)))
        (cond
          ((string= path root-without-slash) ".")
          ((string= path root) ".")
          ((alexandria:starts-with-subseq root path)
           (subseq path (length root)))
          (t "outside")))))

(defun project-navigation-test-record-current (label)
  (let* ((buffer (current-buffer))
         (root (lem-yath-project-root-for-directory
                (buffer-directory buffer))))
    (project-navigation-test-log
     "CURRENT label=~a root=~a name=~a file=~a directory=~a"
     label
     (project-navigation-test-root-label root)
     (buffer-name buffer)
     (project-navigation-test-relative-path (buffer-filename buffer) root)
     (project-navigation-test-relative-path (buffer-directory buffer) root))))

(define-command lem-yath-test-project-navigation-record-spc-space () ()
  (project-navigation-test-record-current "spc-space"))

(define-command lem-yath-test-project-navigation-record-spc-p-f () ()
  (project-navigation-test-record-current "spc-p-f"))

(define-command lem-yath-test-project-navigation-record-spc-p-p () ()
  (project-navigation-test-record-current "spc-p-p")
  (let* ((roots (saved-project-roots))
         (labels (mapcar #'project-navigation-test-root-label roots)))
    (project-navigation-test-log
     "SWITCH dispatch=find-file gamma-known=~a mru-first=~a"
     (project-navigation-test-yes-no
      (member "gamma" labels :test #'string=))
     (if labels (first labels) "none"))))

(defun project-navigation-test-count-substring (needle haystack)
  (loop :with start := 0
        :for position := (search needle haystack :start2 start)
        :while position
        :count t
        :do (setf start (+ position (length needle)))))

(defvar *project-navigation-test-grep-writeback-focus-pending* t)

(define-command lem-yath-test-project-navigation-record-grep () ()
  (let* ((current (current-buffer))
         (buffer (if (alexandria:starts-with-subseq
                      "*peek-source*" (buffer-name current))
                     current
                     (get-buffer "*peek-source*")))
         (text (and buffer
                    (points-to-string (buffer-start-point buffer)
                                      (buffer-end-point buffer))))
         (alpha (and text (search "SHARED_GREP ALPHA" text)))
         (tracked-build (and text (search "SHARED_GREP TRACKED BUILD" text)))
         (sibling (and text (search "SHARED_GREP SIBLING" text)))
         (ignored (and text (search "SHARED_GREP IGNORED" text))))
    (project-navigation-test-log
     (concatenate
      'string
      "GREP alpha=~a tracked-build=~a sibling=~a ignored=~a matches=~d "
      "readonly=~a active=~a enter=~a finish=~a delete=~a unmark=~a "
      "unmark-all=~a abort=~a exit=~a "
      "ex=~a ex-count=~d")
     (project-navigation-test-yes-no alpha)
     (project-navigation-test-yes-no tracked-build)
     (project-navigation-test-yes-no sibling)
     (project-navigation-test-yes-no ignored)
     (if text
         (project-navigation-test-count-substring "SHARED_GREP" text)
         0)
     (project-navigation-test-yes-no
      (and buffer (buffer-read-only-p buffer)))
     (project-navigation-test-yes-no
      (and buffer (project-grep-edit-active-p buffer)))
     (project-navigation-test-yes-no
      (project-navigation-test-key-bound-p
       lem/grep::*peek-grep-mode-keymap* "C-c C-p"))
     (project-navigation-test-yes-no
      (project-navigation-test-key-bound-p
       lem/grep::*peek-grep-mode-keymap* "C-c C-c"))
     (project-navigation-test-yes-no
      (project-navigation-test-key-bound-p
       lem/grep::*peek-grep-mode-keymap* "C-c C-d"))
     (project-navigation-test-yes-no
      (project-navigation-test-key-bound-p
       lem/grep::*peek-grep-mode-keymap* "C-c C-r"))
     (project-navigation-test-yes-no
      (project-navigation-test-key-bound-p
       lem/grep::*peek-grep-mode-keymap* "C-c C-u"))
     (project-navigation-test-yes-no
      (project-navigation-test-key-bound-p
       lem/grep::*peek-grep-mode-keymap* "C-c C-k"))
     (project-navigation-test-yes-no
      (project-navigation-test-key-bound-p
       lem/grep::*peek-grep-mode-keymap* "C-x C-q"))
     (project-navigation-test-yes-no
      (eq (lem-vi-mode/ex-core::find-ex-command "w")
          'project-grep-ex-write))
     (count 'project-grep-ex-write
            lem-vi-mode/ex-core::*command-table*
            :key #'second :test #'eq))
    (when *project-navigation-test-grep-writeback-focus-pending*
      (setf *project-navigation-test-grep-writeback-focus-pending* nil)
      (project-navigation-test-focus-grep-writeback))
    (lem-yath-test-project-navigation-record-grep-writeback)))

(defun project-navigation-test-grep-buffer ()
  (let ((current (current-buffer)))
    (if (alexandria:starts-with-subseq
         "*peek-source*" (buffer-name current))
        current
        (get-buffer "*peek-source*"))))

(defun project-navigation-test-focus-grep-writeback ()
  (let ((buffer (project-navigation-test-grep-buffer)))
    (unless buffer
      (editor-error "No project grep result buffer"))
    (unless (eq buffer (current-buffer))
      (switch-to-buffer buffer))
    (let ((point (current-point)))
      (buffer-start point)
      (let ((match (search-forward point "SHARED_GREP A")))
        (unless match
          (editor-error "No editable Alpha grep result")))
      (window-see (current-window)))
    (project-navigation-test-log
     "GREP-WRITEBACK focus=yes column=~d readonly=~s previous-readonly=~s"
     (point-charpos (current-point))
     (text-property-at (current-point) :read-only)
     (text-property-at (current-point) :read-only -1))))

(define-command lem-yath-test-project-navigation-record-grep-writeback () ()
  (let* ((path (project-navigation-test-path
                *project-navigation-test-alpha* "src/tracked-target.txt"))
         (source (find-file-buffer path))
         (grep-buffer (project-navigation-test-grep-buffer))
         (source-text
           (points-to-string (buffer-start-point source)
                             (buffer-end-point source)))
         (grep-text
           (and grep-buffer
                (points-to-string (buffer-start-point grep-buffer)
                                  (buffer-end-point grep-buffer))))
         (disk-text (uiop:read-file-string path)))
    (let* ((record
             (find-if
              (lambda (record)
                (string= (project-grep-edit-record-relative record)
                         "src/tracked-target.txt"))
              (and grep-buffer (project-grep-edit-records grep-buffer))))
           (status (and record (project-grep-edit-record-status record))))
      (project-navigation-test-log
       (concatenate
        'string
        "GREP-WRITEBACK result=~a source=~a modified=~a disk=~a "
        "abort-result=~a abort-source=~a exit-result=~a exit-source=~a "
        "stale-result=~a external-source=~a "
        "active=~a readonly=~a status=~a")
     (project-navigation-test-yes-no
        (and grep-text (search "SHARED_GREP ASTAGED_LPHA" grep-text)))
     (project-navigation-test-yes-no
        (search "SHARED_GREP ASTAGED_LPHA" source-text))
     (project-navigation-test-yes-no (buffer-modified-p source))
     (project-navigation-test-yes-no
        (search "SHARED_GREP ASTAGED_LPHA" disk-text))
       (project-navigation-test-yes-no
        (and grep-text (search "ABORT_" grep-text)))
       (project-navigation-test-yes-no (search "ABORT_" source-text))
       (project-navigation-test-yes-no
        (and grep-text (search "EXIT_" grep-text)))
       (project-navigation-test-yes-no (search "EXIT_" source-text))
       (project-navigation-test-yes-no
        (and grep-text (search "STALE_" grep-text)))
       (project-navigation-test-yes-no (search "EXTERNAL_" source-text))
       (project-navigation-test-yes-no
        (and grep-buffer (project-grep-edit-active-p grep-buffer)))
       (project-navigation-test-yes-no
        (and grep-buffer (buffer-read-only-p grep-buffer)))
       (or status 'none)))))

(define-command lem-yath-test-project-navigation-focus-grep-edit () ()
  (project-navigation-test-focus-grep-writeback))

(define-command lem-yath-test-project-navigation-stale-grep-source () ()
  (let* ((path (project-navigation-test-path
                *project-navigation-test-alpha* "src/tracked-target.txt"))
         (source (find-file-buffer path))
         (point (buffer-point source)))
    (buffer-start point)
    (unless (search-forward point "SHARED_GREP A")
      (editor-error "No source row for stale grep test"))
    (insert-string point "EXTERNAL_")
    (project-navigation-test-log
     "GREP-STALE source=yes modified=~a"
     (project-navigation-test-yes-no (buffer-modified-p source)))))

(define-command lem-yath-test-project-navigation-record-grep-escape () ()
  (let* ((state (lem-vi-mode/core:current-state))
         (grep-buffer (project-navigation-test-grep-buffer))
         (grep-text
           (and grep-buffer
                (points-to-string (buffer-start-point grep-buffer)
                                  (buffer-end-point grep-buffer)))))
    (project-navigation-test-log
     "GREP-ESCAPE normal=~a state=~a result=~a"
     (project-navigation-test-yes-no
      (and state
           (lem-vi-mode/core:state=
            state
            (lem-vi-mode/core:ensure-state
             'lem-vi-mode/states:normal))))
     (if state (type-of state) 'none)
     (project-navigation-test-yes-no
      (and grep-text
           (search "SHARED_GREP ASTAGED_LPHA" grep-text))))))

(define-command lem-yath-test-project-navigation-multiline-guard () ()
  (let* ((buffer (current-buffer))
         (before (points-to-string (buffer-start-point buffer)
                                   (buffer-end-point buffer)))
         (blocked nil))
    (handler-case
        (insert-string (current-point) (format nil "BROKEN~%ROW"))
      (editor-error ()
        (setf blocked t)))
    (project-navigation-test-log
     "GREP-MULTILINE blocked=~a unchanged=~a active=~a"
     (project-navigation-test-yes-no blocked)
     (project-navigation-test-yes-no
      (string= before
               (points-to-string (buffer-start-point buffer)
                                 (buffer-end-point buffer))))
     (project-navigation-test-yes-no
     (project-grep-edit-active-p buffer)))))

(define-command lem-yath-test-project-navigation-record-grep-delete () ()
  (let* ((grep-buffer (project-navigation-test-grep-buffer))
         (records (and grep-buffer (project-grep-edit-records grep-buffer)))
         (path (project-navigation-test-path
                *project-navigation-test-alpha* "src/delete-target.txt"))
         (source (find-file-buffer path))
         (source-text
           (points-to-string (buffer-start-point source)
                             (buffer-end-point source)))
         (disk-text (uiop:read-file-string path))
         (original
           (format nil
                   "DELETE_GREP FIRST~%KEEP ONE~%DELETE_GREP MIDDLE~%KEEP TWO~%DELETE_GREP FINAL"))
         (remaining (format nil "KEEP ONE~%KEEP TWO~%")))
    (project-navigation-test-log
     "GREP-DELETE records=~d marked=~d ignored=~d pending=~d blank=~d active=~a readonly=~a source=~a disk=~a modified=~a"
     (length records)
     (count-if #'project-grep-edit-record-deletion-p records)
     (count-if #'project-grep-edit-record-ignored-p records)
     (count-if #'project-grep-record-changed-p records)
     (count-if (lambda (record)
                 (zerop (length (project-grep-record-current-text record))))
               records)
     (project-navigation-test-yes-no
      (and grep-buffer (project-grep-edit-active-p grep-buffer)))
     (project-navigation-test-yes-no
      (and grep-buffer (buffer-read-only-p grep-buffer)))
     (cond ((string= source-text original) "original")
           ((string= source-text remaining) "remaining")
           (t "other"))
     (if (string= disk-text original) "original" "other")
     (project-navigation-test-yes-no (buffer-modified-p source)))))

(define-command lem-yath-test-project-navigation-submit-gamma () ()
  (lem/prompt-window::replace-prompt-input
   (project-native-directory *project-navigation-test-gamma*))
  (lem/prompt-window::prompt-execute))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F5" 'lem-yath-test-project-navigation-record-spc-space)
  (define-key keymap "F6" 'lem-yath-test-project-navigation-record-spc-p-f)
  (define-key keymap "F7" 'lem-yath-test-project-navigation-record-spc-p-p)
  (define-key keymap "F8" 'lem-yath-test-project-navigation-record-grep)
  (define-key keymap "F9" 'lem-yath-test-project-navigation-cancellation)
  (define-key keymap "F10" 'lem-yath-test-project-navigation-picker-state)
  (define-key keymap "F11" 'lem-yath-test-project-navigation-edit-picker-origin)
  (define-key keymap "F2" 'lem-yath-test-project-navigation-focus-grep-edit)
  (define-key keymap "F3" 'lem-yath-test-project-navigation-stale-grep-source))

(define-key *project-picker-keymap*
  "F10" 'lem-yath-test-project-navigation-picker-state)
(define-key *project-picker-keymap*
  "F11" 'lem-yath-test-project-navigation-edit-picker-origin)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F10" 'lem-yath-test-project-navigation-picker-state)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F11" 'lem-yath-test-project-navigation-edit-picker-origin)
(define-key lem/prompt-window::*prompt-mode-keymap*
  "F10" 'lem-yath-test-project-navigation-picker-state)
(define-key lem/prompt-window::*prompt-mode-keymap*
  "F11" 'lem-yath-test-project-navigation-edit-picker-origin)
(pushnew 'lem-yath-test-project-navigation-picker-state
         *auto-completion-continue-commands*)
(pushnew 'lem-yath-test-project-navigation-edit-picker-origin
         *auto-completion-continue-commands*)

(define-key lem/peek-source:*peek-source-keymap*
  "F8" 'lem-yath-test-project-navigation-record-grep)
(define-key lem/peek-source:*peek-source-keymap*
  "F12" 'lem-yath-test-project-navigation-record-grep-escape)
(define-key lem/peek-source:*peek-source-keymap*
  "F2" 'lem-yath-test-project-navigation-focus-grep-edit)
(define-key lem/peek-source:*peek-source-keymap*
  "F3" 'lem-yath-test-project-navigation-stale-grep-source)
(define-key lem/peek-source:*peek-source-keymap*
  "F4" 'lem-yath-test-project-navigation-multiline-guard)
(define-key lem/peek-source:*peek-source-keymap*
  "F1" 'lem-yath-test-project-navigation-record-grep-delete)
(define-key lem/prompt-window::*prompt-mode-keymap*
  "F4" 'lem-yath-test-project-navigation-submit-gamma)

(register-project-grep-ex-write)
(register-project-grep-ex-write)

(project-navigation-test-log "READY phase=~a"
                             *project-navigation-test-phase*)
