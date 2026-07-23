(in-package :lem-yath)

(setf (uiop:getenv "PATH")
      (format nil "~a:~a"
              (uiop:getenv "LEM_YATH_ACTIONS_FAKE_BIN")
              (uiop:getenv "PATH")))

(defvar *actions-fixture-report*
  (uiop:getenv "LEM_YATH_ACTIONS_REPORT"))
(defvar *actions-fixture-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_ACTIONS_ROOT")))
(defvar *actions-fixture-source-buffer* nil)
(defvar *actions-fixture-buffer* nil)
(defvar *actions-fixture-accept-count* 0)

(defun actions-fixture-log (control &rest arguments)
  (with-open-file (stream *actions-fixture-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun actions-fixture-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (#\\ (write-string "\\\\" stream))
                (otherwise (write-char character stream))))))

(defun actions-fixture-buffer-text (&optional (buffer (current-buffer)))
  (points-to-string (buffer-start-point buffer)
                    (buffer-end-point buffer)))

(defun actions-fixture-killring-head ()
  (lem/common/killring:peek-killring-item (current-killring) 0))

(defun actions-fixture-visual-name ()
  (if (lem-vi-mode/visual:visual-p)
      (cond
        ((lem-vi-mode/visual:visual-line-p) "line")
        ((lem-vi-mode/visual:visual-screen-line-p) "screen-line")
        ((lem-vi-mode/visual:visual-block-p) "block")
        (t "char"))
      "none"))

(define-command lem-yath-test-actions-record-state () ()
  (let ((buffer (current-buffer)))
    (actions-fixture-log
     "STATE buffer=~a file=~a visual=~a point=~d kill=~a text=~a"
     (buffer-name buffer)
     (if (buffer-filename buffer)
         (file-namestring (buffer-filename buffer))
         "none")
     (actions-fixture-visual-name)
     (position-at-point (current-point))
     (actions-fixture-encode (actions-fixture-killring-head))
     (actions-fixture-encode (actions-fixture-buffer-text buffer)))))

(defun actions-fixture-definition-handler (point)
  (actions-fixture-log
   "HANDLER kind=definition symbol=~a buffer=~a"
   (or (symbol-string-at-point point) "none")
   (buffer-name (point-buffer point))))

(defun actions-fixture-reference-handler (point)
  (actions-fixture-log
   "HANDLER kind=references symbol=~a buffer=~a"
   (or (symbol-string-at-point point) "none")
   (buffer-name (point-buffer point))))

(defun actions-fixture-install-language-handlers (buffer)
  (setf (variable-value 'lem/language-mode:find-definitions-function
                        :buffer buffer)
        #'actions-fixture-definition-handler
        (variable-value 'lem/language-mode:find-references-function
                        :buffer buffer)
        #'actions-fixture-reference-handler))

(define-command lem-yath-test-actions-source () ()
  (unless (and *actions-fixture-source-buffer*
               (member *actions-fixture-source-buffer*
                       (buffer-list)
                       :test #'eq))
    (editor-error "The actions fixture source buffer is gone"))
  (switch-to-buffer *actions-fixture-source-buffer*)
  (buffer-start (current-point)))

(define-command lem-yath-test-actions-buffer () ()
  (unless (and *actions-fixture-buffer*
               (member *actions-fixture-buffer* (buffer-list) :test #'eq))
    (editor-error "The actions fixture buffer is gone"))
  (switch-to-buffer *actions-fixture-buffer*)
  (buffer-start (current-point)))

(define-command lem-yath-test-actions-record-buffer () ()
  (if (and *actions-fixture-buffer*
           (member *actions-fixture-buffer* (buffer-list) :test #'eq))
      (actions-fixture-log
       "BUFFER live=yes modified=~a text=~a"
       (if (buffer-modified-p *actions-fixture-buffer*) "yes" "no")
       (actions-fixture-encode
        (actions-fixture-buffer-text *actions-fixture-buffer*)))
      (actions-fixture-log "BUFFER live=no")))

(defun actions-fixture-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap
                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun actions-fixture-collection-size (collection)
  (etypecase collection
    (null 0)
    (list (length collection))
    (vector (length collection))
    (hash-table (hash-table-count collection))))

(define-command lem-yath-test-actions-static () ()
  (actions-fixture-log
   "XDG path=~a"
   (or (ignore-errors (executable-find "xdg-open")) "none"))
  (let ((failures 0))
    (labels ((check (condition name)
               (actions-fixture-log
                "~a STATIC ~a"
                (if condition "PASS" "FAIL")
                name)
               (unless condition
                 (incf failures))))
      (check (eq 'lem-yath-act
                 (leader-binding-command
                  lem-vi-mode:*normal-keymap* "e a"))
             "normal-leader-action")
      (check (eq 'lem-yath-act
                 (leader-binding-command
                  lem-vi-mode:*visual-keymap* "e a"))
             "visual-leader-action")
      (check (eq 'lem-yath-act-completion
                 (actions-fixture-key-command
                  lem/completion-mode::*completion-mode-keymap* "C-c a"))
             "completion-local-action")
      (check (= 1 (count 'lem-yath-act-completion
                         *auto-completion-continue-commands*))
             "auto-completion-action-whitelisted-once")
      (check (plusp
              (actions-fixture-collection-size
               (action-target-providers)))
             "target-provider-registry")
      (check (plusp
              (actions-fixture-collection-size
               (action-definitions)))
             "action-definition-registry")
      (let ((origin (snapshot-action-origin))
            (aborted nil))
        (unwind-protect
             (progn
               (register-action-target-provider
                'actions-fixture-aborting-provider
                'action-target
                (lambda (provider-origin)
                  (declare (ignore provider-origin))
                  (error 'editor-abort))
                :priority -1000)
               (handler-case
                   (detect-action-target :origin origin)
                 (editor-abort ()
                   (setf aborted t))))
          (remhash 'actions-fixture-aborting-provider
                   *action-target-provider-registry*))
        (check (and aborted (action-origin-cleaned-p origin))
               "aborting-provider-cleans-origin"))
      (let ((origin (snapshot-action-origin))
            (target nil)
            (aborted nil))
        (unwind-protect
             (progn
               (register-action-target-provider
                'actions-fixture-target-before-abort
                'buffer-action-target
                (lambda (provider-origin)
                  (setf target
                        (make-instance
                         'buffer-action-target
                         :origin provider-origin
                         :buffer (action-origin-buffer provider-origin))))
                :priority -2000)
               (register-action-target-provider
                'actions-fixture-aborting-all-provider
                'action-target
                (lambda (provider-origin)
                  (declare (ignore provider-origin))
                  (error 'editor-abort))
                :priority -1999)
               (handler-case
                   (detect-action-targets :origin origin)
                 (editor-abort ()
                   (setf aborted t))))
          (remhash 'actions-fixture-target-before-abort
                   *action-target-provider-registry*)
          (remhash 'actions-fixture-aborting-all-provider
                   *action-target-provider-registry*))
        (check (and aborted target
                    (action-target-cleaned-p target)
                    (action-origin-cleaned-p origin))
               "multi-target-abort-cleans-owned-state"))
      (let* ((targets (detect-action-targets))
             (origin (and targets (action-target-origin (first targets)))))
        (unwind-protect
             (check (and (> (length targets) 1)
                         (every (lambda (target)
                                  (eq origin (action-target-origin target)))
                                targets))
                    "multi-targets-share-origin")
          (mapc #'cleanup-action-target targets))
        (check (and origin
                    (action-origin-cleaned-p origin)
                    (every #'action-target-cleaned-p targets))
               "multi-target-cleanup-idempotent"))
      (actions-fixture-log
       "SUMMARY STATIC ~a failures=~d providers=~d actions=~d"
       (if (zerop failures) "PASS" "FAIL")
       failures
       (actions-fixture-collection-size (action-target-providers))
       (actions-fixture-collection-size (action-definitions))))))

(define-command lem-yath-test-actions-install-native-menu () ()
  (lem-yath-test-actions-source)
  (buffer-end (current-point))
  (setf (lem-core::buffer-context-menu (current-buffer))
        (make-instance
         'lem/context-menu:context-menu
         :items
         (list
          (lem/context-menu:make-item
           :label "Native fixture action"
           :description "delegated by actions"
           :callback
           (lambda (window)
             (declare (ignore window))
             (actions-fixture-log "NATIVE selected=yes"))))))
  (actions-fixture-log "NATIVE ready=yes"))

(defun actions-fixture-completion-item (label insertion)
  (lem/completion-mode:make-completion-item
   :label label
   :filter-text label
   :insert-text insertion
   :start (lem/prompt-window::current-prompt-start-point)
   :end (buffer-end-point (current-buffer))
   :accept-action
   (lambda ()
     (incf *actions-fixture-accept-count*)
     (actions-fixture-log
      "COMPLETION accept=~d label=~a input=~a"
      *actions-fixture-accept-count*
      label
      (actions-fixture-encode
       (lem/prompt-window::get-input-string))))))

(defun actions-fixture-completion-provider (input)
  (declare (ignore input))
  (list (actions-fixture-completion-item
         "ACTION-CANDIDATE" "accepted-action-candidate")
        (actions-fixture-completion-item
         "SECONDARY-CANDIDATE-WITH-LONGER-LABEL" "secondary-value")))

(define-command lem-yath-test-actions-completion () ()
  (setf *actions-fixture-accept-count* 0)
  (handler-case
      (let ((result
              (prompt-for-string
               "Action completion: "
               :completion-function
               #'actions-fixture-completion-provider
               :history-symbol 'lem-yath-test-actions-completion)))
        (actions-fixture-log
         "COMPLETION result=~a accept=~d"
         (actions-fixture-encode result)
         *actions-fixture-accept-count*))
    (editor-abort ()
      (actions-fixture-log
       "COMPLETION aborted=yes accept=~d"
       *actions-fixture-accept-count*))))

(define-command lem-yath-test-actions-record-prompt () ()
  (let* ((context lem/completion-mode::*completion-context*)
         (popup (and context
                     (lem/completion-mode::context-popup-menu context)))
         (item (and popup (lem/popup-menu:get-focus-item popup))))
    (actions-fixture-log
     "PROMPT live=~a completion=~a focus=~a input=~a kill=~a accept=~d"
     (if (lem/prompt-window:current-prompt-window) "yes" "no")
     (if context "yes" "no")
     (if item
         (lem/completion-mode:completion-item-label item)
         "none")
     (actions-fixture-encode
      (if (lem/prompt-window:current-prompt-window)
          (lem/prompt-window::get-input-string)
          ""))
     (actions-fixture-encode (actions-fixture-killring-head))
     *actions-fixture-accept-count*)))

(define-command lem-yath-test-actions-direct-completion-copy () ()
  (let ((target (detect-completion-action-target)))
    (unless target
      (actions-fixture-log "DIRECT target=none")
      (return-from lem-yath-test-actions-direct-completion-copy))
    (unwind-protect
         (let* ((context (completion-action-target-context target))
                (result (invoke-action-by-key target "w")))
           (actions-fixture-log
            (concatenate
             'string
             "DIRECT target=yes generation=~d presented=~d current=~a "
             "result=~a kill=~a accept=~d")
            (completion-action-target-generation target)
            (lem/completion-mode::context-presented-generation context)
            (if (completion-action-target-current-p target) "yes" "no")
            result
            (actions-fixture-encode (actions-fixture-killring-head))
            *actions-fixture-accept-count*))
      (cleanup-action-target target)))
  ;; Leave a distinct sentinel so the following real C-c a w must prove that
  ;; it dispatched rather than inheriting this diagnostic copy.
  (copy-to-clipboard-with-killring "completion-diagnostic-sentinel")
  (actions-fixture-log "DIRECT reset=completion-diagnostic-sentinel"))

(define-command lem-yath-test-actions-find-name () ()
  (lem-yath-find-name
   (merge-pathnames "find/" *actions-fixture-root*)
   "*.hit"))

(define-command lem-yath-test-actions-peek () ()
  (let* ((path (merge-pathnames "peek-target.txt" *actions-fixture-root*))
         (buffer (find-file-buffer path))
         (target (copy-point (buffer-start-point buffer) :temporary)))
    (lem/peek-source:with-collecting-sources (collector)
      (declare (ignore collector))
      (lem/peek-source:with-appending-source
          (point :move-function (lambda () (copy-point target :temporary)))
        (insert-string point "peek-target.txt:1: PEEK ACTION TARGET")))))

(define-command lem-yath-test-actions-stale-origin () ()
  (let* ((source *actions-fixture-source-buffer*)
         (buffer (make-buffer "*actions-stale-origin*"))
         (condition-seen nil)
         target)
    (unwind-protect
         (progn
           (switch-to-buffer buffer)
           (insert-string (current-point) "stale origin text")
           (buffer-start (current-point))
           (setf target (detect-action-target))
           (switch-to-buffer source)
           (delete-buffer buffer)
           (handler-case
               (invoke-action-by-key target "w")
             (condition ()
               (setf condition-seen t)))
           (actions-fixture-log
            "STALE origin-gone=yes condition=~a current-source=~a responsive=yes"
            (if condition-seen "yes" "no")
            (if (eq (current-buffer) source) "yes" "no")))
      (when (member buffer (buffer-list) :test #'eq)
        (delete-buffer buffer))
      (when target
        (cleanup-action-target target)))))

(define-command lem-yath-test-actions-deleted-file () ()
  (let* ((source *actions-fixture-source-buffer*)
         (path (merge-pathnames "deleted-target.txt"
                                *actions-fixture-root*))
         (buffer (make-buffer "*actions-deleted-file*"))
         (condition-seen nil)
         target)
    (unwind-protect
         (progn
           (switch-to-buffer buffer)
           (setf (buffer-directory buffer) *actions-fixture-root*)
           (insert-string (current-point) "deleted-target.txt")
           (buffer-start (current-point))
           (setf target (detect-action-target))
           (delete-file path)
           (handler-case
               (invoke-action-by-key target "Return")
             (condition ()
               (setf condition-seen t)))
           (actions-fixture-log
            "STALE file-gone=yes condition=~a current-origin=~a responsive=yes"
            (if condition-seen "yes" "no")
            (if (eq (current-buffer) buffer) "yes" "no")))
      (when target
        (cleanup-action-target target))
      (when (member buffer (buffer-list) :test #'eq)
        (switch-to-buffer source)
        (delete-buffer buffer)))))

(define-command lem-yath-test-actions-reload () ()
  (let* ((source-root
           (uiop:ensure-directory-pathname
            (uiop:getenv "LEM_YATH_SOURCE")))
         (actions-file (merge-pathnames "src/actions.lisp" source-root))
         (providers-before
           (actions-fixture-collection-size (action-target-providers)))
         (actions-before
           (actions-fixture-collection-size (action-definitions))))
    (load actions-file)
    (let ((providers-after
            (actions-fixture-collection-size (action-target-providers)))
          (actions-after
            (actions-fixture-collection-size (action-definitions))))
      (actions-fixture-log
       (concatenate
        'string
        "RELOAD providers-before=~d providers-after=~d "
        "actions-before=~d actions-after=~d normal=~a visual=~a completion=~a")
       providers-before
       providers-after
       actions-before
       actions-after
       (if (eq 'lem-yath-act
               (leader-binding-command
                lem-vi-mode:*normal-keymap* "e a"))
           "yes" "no")
       (if (eq 'lem-yath-act
               (leader-binding-command
                lem-vi-mode:*visual-keymap* "e a"))
           "yes" "no")
       (if (eq 'lem-yath-act-completion
               (actions-fixture-key-command
                lem/completion-mode::*completion-mode-keymap* "C-c a"))
           "yes" "no")))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*
                      lem/prompt-window::*prompt-mode-keymap*
                      lem/completion-mode::*completion-mode-keymap*
                      lem/peek-source:*peek-source-keymap*
                      *find-name-mode-keymap*))
  (define-key keymap "F5" 'lem-yath-test-actions-record-state))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F2" 'lem-yath-test-actions-record-buffer)
  (define-key keymap "F3" 'lem-yath-test-actions-buffer))

(dolist (keymap (list *global-keymap*
                      lem/prompt-window::*prompt-mode-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "F4" 'lem-yath-test-actions-direct-completion-copy)
  (define-key keymap "F9" 'lem-yath-test-actions-record-prompt))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F6" 'lem-yath-test-actions-static)
  (define-key keymap "F7" 'lem-yath-test-actions-source)
  (define-key keymap "F8" 'lem-yath-test-actions-install-native-menu)
  (define-key keymap "F10" 'lem-yath-test-actions-completion)
  (define-key keymap "F11" 'lem-yath-test-actions-find-name)
  (define-key keymap "F12" 'lem-yath-test-actions-peek)
  (define-key keymap "Shift-F6" 'lem-yath-test-actions-stale-origin)
  (define-key keymap "Shift-F7" 'lem-yath-test-actions-deleted-file)
  (define-key keymap "Shift-F8" 'lem-yath-test-actions-reload))

(setf *actions-fixture-source-buffer* (current-buffer))
(setf *actions-fixture-buffer*
      (find-file-buffer (uiop:getenv "LEM_YATH_ACTIONS_BUFFER")))
(add-hook
 (variable-value 'kill-buffer-hook :buffer *actions-fixture-buffer*)
 (lambda (buffer)
   (declare (ignore buffer))
   (actions-fixture-log "BUFFER killed=yes name=buffer-action.txt")))
(setf (buffer-directory *actions-fixture-source-buffer*)
      *actions-fixture-root*)
(actions-fixture-install-language-handlers *actions-fixture-source-buffer*)
(actions-fixture-log "READY")
