(in-package :lem-yath)

(defvar *persistence-test-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_PERSISTENCE_TEST_ROOT")))

(defvar *persistence-test-report*
  (uiop:getenv "LEM_YATH_PERSISTENCE_TEST_REPORT"))

(defvar *persistence-test-phase*
  (or (uiop:getenv "LEM_YATH_PERSISTENCE_TEST_PHASE") "unknown"))

(defvar *persistence-test-source*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PERSISTENCE_SOURCE")))

(defvar *persistence-test-record-sample* 0)
(defvar *persistence-test-background-buffer* nil)
(defvar *persistence-test-custom-buffer* nil)
(defvar *persistence-test-custom-revert-count* 0)
(defvar *persistence-test-save-as-race-directory* nil)

(defun persistence-test-path (relative)
  (merge-pathnames relative *persistence-test-root*))

(defun persistence-test-log (control &rest arguments)
  (with-open-file (stream *persistence-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun persistence-test-yes-no (value)
  (if value "yes" "no"))

(defun persistence-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (#\\ (write-string "\\\\" stream))
                (otherwise (write-char character stream))))))

(defun persistence-test-buffer-text (buffer)
  (points-to-string (buffer-start-point buffer)
                    (buffer-end-point buffer)))

(defun persistence-test-file-exists-p (buffer)
  (and (buffer-filename buffer)
       (uiop:file-exists-p (buffer-filename buffer))))

(defun persistence-test-baseline-current-p (buffer)
  (alexandria:when-let* ((path (buffer-file-path-key buffer))
                         (baseline
                           (buffer-value
                            buffer 'lem-yath-file-state-signature)))
    (file-signatures-equal-p
     baseline (file-state-signature path :digest t))))

(defun persistence-test-record-buffer (label buffer)
  (let ((point (buffer-point buffer)))
    (persistence-test-log
     (concatenate
      'string
      "BUFFER phase=~a sample=~d label=~a file=~a text=~a modified=~a "
      "line=~d column=~d position=~d end=~d at-end=~a exists=~a")
     *persistence-test-phase*
     (incf *persistence-test-record-sample*)
     label
     (if (buffer-filename buffer)
         (file-namestring (buffer-filename buffer))
         "none")
     (persistence-test-encode (persistence-test-buffer-text buffer))
     (persistence-test-yes-no (buffer-modified-p buffer))
     (line-number-at-point point)
     (point-column point)
     (position-at-point point)
     (position-at-point (buffer-end-point buffer))
     (persistence-test-yes-no (point= point (buffer-end-point buffer)))
     (persistence-test-yes-no (persistence-test-file-exists-p buffer)))))

(defun persistence-test-hook-name-contains-p (entry fragment)
  (let ((callback (car entry)))
    (and (symbolp callback)
         (search fragment (symbol-name callback) :test #'char-equal))))

(defun persistence-test-safe-hook-count ()
  (count-if (lambda (entry)
              (persistence-test-hook-name-contains-p
               entry "SAFE-AUTO-REVERT"))
            *pre-command-hook*))

(defun persistence-test-safe-timer-live-p ()
  (and *safe-auto-revert-timer*
       (not (timer-expired-p *safe-auto-revert-timer*))))

(defun persistence-test-dangerous-hook-count ()
  (count 'lem-core/commands/file::ask-revert-buffer
         *pre-command-hook*
         :key #'car
         :test #'eq))

(defun persistence-test-api-present-p ()
  (every #'fboundp
         '(safe-auto-revert-check-buffer
           safe-auto-revert-check-all
           persistence-state-pathname
           load-persistence-state
           flush-persistence-state
           record-buffer-place
           restore-buffer-place)))

(define-command lem-yath-test-persistence-reload-and-record-hooks () ()
  (load *persistence-test-source*)
  (load *persistence-test-source*)
  (persistence-test-log
   "HOOK dangerous=~d safe=~d timer=~a api=~a"
   (persistence-test-dangerous-hook-count)
   (persistence-test-safe-hook-count)
   (persistence-test-yes-no (persistence-test-safe-timer-live-p))
   (persistence-test-yes-no (persistence-test-api-present-p))))

(define-command lem-yath-test-persistence-record-current () ()
  (persistence-test-record-buffer "current" (current-buffer)))

(define-command lem-yath-test-persistence-record-save-state () ()
  (let ((buffer (current-buffer)))
    (persistence-test-log
     "SAVE-STATE text=~a modified=~a baseline=~a"
     (persistence-test-encode (persistence-test-buffer-text buffer))
     (persistence-test-yes-no (buffer-modified-p buffer))
     (persistence-test-yes-no
      (persistence-test-baseline-current-p buffer)))))

(define-command lem-yath-test-persistence-record-save-as-state () ()
  (let ((buffer (current-buffer)))
    (persistence-test-log
     "SAVE-AS name=~a file=~a text=~a modified=~a"
     (buffer-name buffer)
     (if (buffer-filename buffer)
         (file-namestring (buffer-filename buffer))
         "none")
     (persistence-test-encode (persistence-test-buffer-text buffer))
     (persistence-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-persistence-write-existing-target () ()
  (lem-core/commands/file:write-file
   (namestring (persistence-test-path "save-as/target.txt"))))

(defun persistence-test-save-as-race-target ()
  (persistence-test-path "save-as-race/target.txt"))

(defun persistence-test-create-save-as-race-target (buffer)
  (remove-hook (variable-value 'before-save-hook :buffer buffer)
               'persistence-test-create-save-as-race-target)
  (let ((target (persistence-test-save-as-race-target)))
    (unless (uiop:file-exists-p target)
      (with-open-file (stream target
                              :direction :output
                              :if-exists :error
                              :if-does-not-exist :create)
        (format stream "RACE-TARGET~%")))))

(define-command lem-yath-test-persistence-setup-save-as-race () ()
  (let ((buffer (make-buffer "*persistence-save-as-race*")))
    (switch-to-buffer buffer)
    (insert-string (buffer-start-point buffer) (format nil "RACE-LOCAL~%"))
    (setf *persistence-test-save-as-race-directory*
          (buffer-directory buffer))
    (add-hook (variable-value 'before-save-hook :buffer buffer)
              'persistence-test-create-save-as-race-target
              20000)
    (persistence-test-log
     "RACE-SETUP name=~a file=~a modified=~a"
     (buffer-name buffer)
     (if (buffer-filename buffer) "present" "none")
     (persistence-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-persistence-write-save-as-race () ()
  (lem-core/commands/file:write-file
   (namestring (persistence-test-save-as-race-target))))

(define-command lem-yath-test-persistence-record-save-as-race () ()
  (let ((buffer (current-buffer)))
    (persistence-test-log
     (concatenate
      'string
      "RACE-STATE name=~a file=~a directory-restored=~a "
      "text=~a modified=~a")
     (buffer-name buffer)
     (if (buffer-filename buffer) "present" "none")
     (persistence-test-yes-no
      (equal (buffer-directory buffer)
             *persistence-test-save-as-race-directory*))
     (persistence-test-encode (persistence-test-buffer-text buffer))
     (persistence-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-persistence-quit-active-window-with-kill () ()
  (lem-core/commands/window:quit-active-window t))

(defun persistence-test-large-baseline (buffer)
  (buffer-value buffer 'lem-yath-file-state-signature))

(define-command lem-yath-test-persistence-prepare-large-baseline () ()
  (let* ((buffer (current-buffer))
         (path (buffer-file-path-key buffer))
         (signature
           (file-state-signature path :digest t :full-digest t)))
    (setf (buffer-value buffer 'lem-yath-file-state-signature) signature)
    (persistence-test-log
     "LARGE-PREPARED length=~d modified=~a digest=yes"
     (1- (position-at-point (buffer-end-point buffer)))
     (persistence-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-persistence-normalize-large-metadata () ()
  (let* ((buffer (current-buffer))
         (path (buffer-file-path-key buffer))
         (old-digest (seventh (persistence-test-large-baseline buffer)))
         (current (file-state-signature path)))
    ;; Simulate equal inode/size/mtime/ctime while retaining the digest of the
    ;; originally visited bytes.  Explicit save safety must compare full
    ;; content even beyond the background-revert digest threshold.
    (setf (buffer-value buffer 'lem-yath-file-state-signature)
          (append (subseq current 0 6) (list old-digest)))
    (persistence-test-log
     "LARGE-NORMALIZED size=~d digest=yes"
     (fourth current))))

(define-command lem-yath-test-persistence-record-large-state () ()
  (let ((buffer (current-buffer)))
    (persistence-test-log
     "LARGE-STATE length=~d first=~a last=~a modified=~a"
     (1- (position-at-point (buffer-end-point buffer)))
     (or (character-at (buffer-start-point buffer)) "none")
     (or (character-at (buffer-end-point buffer) -1) "none")
     (persistence-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-persistence-record-write-policy () ()
  (persistence-test-log
   (concatenate
    'string
    "WRITE-POLICY auto-save=~a input-hook=~d timer=~a backups=~a "
    "modified=~a")
   (persistence-test-yes-no
    (mode-active-p (current-buffer) 'lem/auto-save:auto-save-mode))
   (count 'lem/auto-save::count-keys *input-hook* :key #'car :test #'eq)
   (persistence-test-yes-no lem/auto-save::*timer*)
   (persistence-test-yes-no lem/auto-save:*make-backup-files*)
   (persistence-test-yes-no (buffer-modified-p (current-buffer)))))

(define-command lem-yath-test-persistence-check-current () ()
  (safe-auto-revert-check-buffer (current-buffer) :force-digest t)
  (persistence-test-record-buffer "check-current" (current-buffer)))

(define-command lem-yath-test-persistence-open-delete () ()
  (let ((buffer (find-file-buffer
                 (persistence-test-path "auto/delete.txt"))))
    (switch-to-buffer buffer)
    (persistence-test-log "OPEN label=delete file=~a"
                          (file-namestring (buffer-filename buffer)))))

(define-command lem-yath-test-persistence-check-all () ()
  (safe-auto-revert-check-all :force t)
  (persistence-test-record-buffer "check-all-current" (current-buffer))
  (if *persistence-test-background-buffer*
      (persistence-test-log
       "GLOBAL text=~a modified=~a exists=~a"
       (persistence-test-encode
        (persistence-test-buffer-text *persistence-test-background-buffer*))
       (persistence-test-yes-no
        (buffer-modified-p *persistence-test-background-buffer*))
       (persistence-test-yes-no
        (persistence-test-file-exists-p
         *persistence-test-background-buffer*)))
      (persistence-test-log
       "GLOBAL text=none modified=no exists=no")))

(defun persistence-test-custom-revert (buffer)
  (declare (ignore buffer))
  (incf *persistence-test-custom-revert-count*))

(define-command lem-yath-test-persistence-setup-custom-dirty () ()
  (setf *persistence-test-custom-revert-count* 0
        *persistence-test-custom-buffer*
        (find-file-buffer (persistence-test-path "auto/custom.txt")))
  (setf (lem-core/commands/file:revert-buffer-function
         *persistence-test-custom-buffer*)
        #'persistence-test-custom-revert)
  (insert-string (buffer-end-point *persistence-test-custom-buffer*)
                 (format nil "LOCAL-CUSTOM~%"))
  (switch-to-buffer *persistence-test-custom-buffer*)
  (persistence-test-log
   "CUSTOM-SETUP modified=~a text=~a"
   (persistence-test-yes-no
    (buffer-modified-p *persistence-test-custom-buffer*))
   (persistence-test-encode
    (persistence-test-buffer-text *persistence-test-custom-buffer*))))

(define-command lem-yath-test-persistence-check-custom-dirty () ()
  (safe-auto-revert-check-all :force t)
  (persistence-test-log
   "CUSTOM count=~d modified=~a text=~a"
   *persistence-test-custom-revert-count*
   (persistence-test-yes-no
    (buffer-modified-p *persistence-test-custom-buffer*))
   (persistence-test-encode
    (persistence-test-buffer-text *persistence-test-custom-buffer*))))

(define-command lem-yath-test-persistence-named-prompt () ()
  (let ((input (prompt-for-string
                "Persistence prompt: "
                :history-symbol 'lem-yath-citar)))
    (persistence-test-log "PROMPT-ACCEPT value=~a"
                          (persistence-test-encode input))))

(define-command lem-yath-test-persistence-record-prompt-input () ()
  (persistence-test-log
   "PROMPT-INPUT value=~a"
   (persistence-test-encode
    (lem/prompt-window::get-input-string))))

(define-command lem-yath-test-persistence-record-search-input () ()
  (persistence-test-log
   "SEARCH-INPUT kind=~a value=~a"
   (if (and (boundp 'lem/isearch::*isearch-prompt*)
            (search "Regexp" lem/isearch::*isearch-prompt*
                    :test #'char-equal))
       "regexp"
       "literal")
   (persistence-test-encode
    (if (boundp 'lem/isearch::*isearch-string*)
        lem/isearch::*isearch-string*
        ""))))

(defun persistence-test-prompt-history ()
  (lem/common/history:history-data-list
   (lem/prompt-window::get-history 'lem-yath-citar)))

(defun persistence-test-prompt-snapshot-values (symbol)
  (second
   (find (prompt-symbol-key symbol)
         (persistence-prompt-history-snapshot)
         :key #'first
         :test #'equal)))

(defun persistence-test-seed-prompt-security-state ()
  (let ((safe (lem/prompt-window::get-history 'lem-yath-citar)))
    (dotimes (index 105)
      (lem/common/history:add-history
       safe (format nil "cap-~3,'0d" index)))
    (dolist (symbol '(lem-yath-persistence-unknown
                      lem-yath-pg
                      lem-yath-pg-conninfo))
      (lem/common/history:add-history
       (lem/prompt-window::get-history symbol)
       (format nil "private-~(~a~)" symbol)))))

(defun persistence-test-record-prompt-security ()
  (let ((safe-live (persistence-test-prompt-history))
        (safe-snapshot
          (persistence-test-prompt-snapshot-values 'lem-yath-citar)))
    (persistence-test-log
     (concatenate
      'string
      "PROMPT-SECURITY live=~d snapshot=~d safe-head=~a "
      "unknown=~a pg=~a conninfo=~a")
     (length safe-live)
     (length safe-snapshot)
     (or (first safe-snapshot) "none")
     (persistence-test-yes-no
      (persistence-test-prompt-snapshot-values
       'lem-yath-persistence-unknown))
     (persistence-test-yes-no
      (persistence-test-prompt-snapshot-values 'lem-yath-pg))
     (persistence-test-yes-no
      (persistence-test-prompt-snapshot-values 'lem-yath-pg-conninfo)))))

(define-command lem-yath-test-persistence-prompt-security () ()
  (if (string= *persistence-test-phase* "prompt-security")
      (progn
        (persistence-test-seed-prompt-security-state)
        (flush-persistence-state :record-places nil))
      (load-persistence-state))
  (persistence-test-record-prompt-security))

(defun persistence-test-killring-length ()
  (length (persistence-kill-ring-snapshot)))

(defun persistence-test-killring-entries ()
  (loop :for (text options) :in (persistence-kill-ring-snapshot)
        :collect (format nil "~a[~{~(~a~)~^,~}]"
                         (persistence-test-encode text)
                         options)))

(defun persistence-test-format-kill-entries (entries)
  (loop :for (text options) :in entries
        :collect (format nil "~a[~{~(~a~)~^,~}]"
                         (persistence-test-encode text)
                         options)))

(defun persistence-test-kill-head-line-p ()
  (multiple-value-bind (text options)
      (lem/common/killring:peek-killring-item (current-killring) 0)
    (and (string= text "same")
         (equal options '(:vi-line)))))

(define-command lem-yath-test-persistence-kill-semantics () ()
  (if (string= *persistence-test-phase* "kill-semantics")
      (let ((killring (lem/common/killring:make-killring 120)))
        (setf lem-core::*killring* killring)
        (lem/common/killring:push-killring-item killring "older")
        (lem/common/killring:push-killring-item killring "same")
        (lem/common/killring:push-killring-item
         killring "same" :options '(:vi-line))
        (let ((distinct (= 3 (persistence-test-killring-length))))
          (lem/common/killring:rotate-killring killring)
          (let ((physical
                  (equal (persistence-kill-ring-snapshot)
                         '(("same" (:vi-line))
                           ("same" nil)
                           ("older" nil)))))
            ;; This is an exact duplicate of the physical head.  Suppression
            ;; must still reset a prior yank-pop rotation to offset zero.
            (lem/common/killring:push-killring-item
             killring "same" :options '(:vi-line))
            (persistence-test-log
             (concatenate
              'string
              "KILL-SEMANTICS distinct=~a physical=~a count=~d "
              "offset=~d head-line=~a")
             (persistence-test-yes-no distinct)
             (persistence-test-yes-no physical)
             (persistence-test-killring-length)
             (lem/common/killring::killring-offset killring)
             (persistence-test-yes-no
              (persistence-test-kill-head-line-p)))
            (flush-persistence-state :record-places nil))))
      (progn
        (load-persistence-state)
        (persistence-test-log
         "KILL-VERIFY count=~d entries=~{~a~^|~}"
         (persistence-test-killring-length)
         (persistence-test-killring-entries)))))

(defun persistence-test-before-exit-snapshot ()
  (persistence-test-log "EXIT-KILL live=~{~a~^|~}"
                        (persistence-test-killring-entries)))

(defun persistence-test-after-exit-snapshot ()
  (persistence-test-log
   "EXIT-KILL disk=~{~a~^|~}"
   (persistence-test-format-kill-entries
    (getf (read-persistence-state-file) :kill-ring))))

(define-command lem-yath-test-persistence-record-state () ()
  (persistence-test-log
   (concatenate
    'string
    "STATE path=~a prompts=~{~a~^|~} literal=~{~a~^|~} "
    "regexp=~{~a~^|~} places=~d kill-count=~d kills=~{~a~^|~}")
   (uiop:native-namestring (persistence-state-pathname))
   (mapcar #'persistence-test-encode
           (persistence-test-prompt-history))
   (mapcar #'persistence-test-encode *literal-search-history*)
   (mapcar #'persistence-test-encode *regexp-search-history*)
   (length (persistence-place-snapshot))
   (persistence-test-killring-length)
   (persistence-test-killring-entries))
  (when (member *persistence-test-phase* '("writer" "failure")
                :test #'string=)
    (exit-editor)))

(define-command lem-yath-test-persistence-flush () ()
  (flush-persistence-state)
  (persistence-test-log "FLUSH path=~a exists=~a"
                        (uiop:native-namestring
                         (persistence-state-pathname))
                        (persistence-test-yes-no
                         (uiop:file-exists-p
                          (persistence-state-pathname)))))

(defun persistence-test-concurrent-label ()
  (cond
    ((string= *persistence-test-phase* "concurrent-a") "concurrent-a")
    ((string= *persistence-test-phase* "concurrent-b") "concurrent-b")
    (t nil)))

(define-command lem-yath-test-persistence-concurrent () ()
  (let ((label (persistence-test-concurrent-label)))
    (if label
        (progn
          (lem/common/history:add-history
           (lem/prompt-window::get-history 'lem-yath-citar)
           label)
          (lem/common/killring:push-killring-item
           (current-killring)
           label
           :options (and (string= label "concurrent-a") '(:vi-line)))
          (record-buffer-place (current-buffer))
          (flush-persistence-state)
          (persistence-test-log
           "CONCURRENT-WRITE phase=~a position=~d"
           *persistence-test-phase*
           (position-at-point (current-point))))
        (progn
          (load-persistence-state)
          (let* ((a-buffer
                   (find-file-buffer
                    (persistence-test-path "concurrent/a.txt")))
                 (b-buffer
                   (find-file-buffer
                    (persistence-test-path "concurrent/b.txt"))))
            (restore-buffer-place a-buffer)
            (restore-buffer-place b-buffer)
            (persistence-test-log
             (concatenate
              'string
              "CONCURRENT-VERIFY a=~d b=~d prompts=~{~a~^|~} "
              "kill-count=~d kills=~{~a~^|~}")
             (position-at-point (buffer-point a-buffer))
             (position-at-point (buffer-point b-buffer))
             (mapcar #'persistence-test-encode
                     (persistence-test-prompt-history))
             (persistence-test-killring-length)
             (persistence-test-killring-entries)))))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F1" 'lem-yath-test-persistence-record-save-state)
  (define-key keymap "F2" 'lem-yath-test-persistence-record-write-policy)
  (define-key keymap "F4" 'lem-yath-test-persistence-record-save-as-state)
  (define-key keymap "F5" 'lem-yath-test-persistence-record-current)
  (define-key keymap "F6" 'lem-yath-test-persistence-check-current)
  (define-key keymap "F7" 'lem-yath-test-persistence-check-all)
  (define-key keymap "F8" 'lem-yath-test-persistence-check-custom-dirty)
  (define-key keymap "F9"
    'lem-yath-test-persistence-reload-and-record-hooks)
  (define-key keymap "F10" 'lem-yath-test-persistence-record-state)
  (define-key keymap "F11" 'lem-yath-test-persistence-flush)
  (define-key keymap "F12" 'lem-yath-test-persistence-concurrent))

(define-key lem/prompt-window::*prompt-mode-keymap*
  "F4" 'lem-yath-test-persistence-record-prompt-input)

(define-key lem/isearch:*isearch-keymap*
  "F3" 'lem-yath-test-persistence-record-search-input)

;; Keep the persisted-ring assertions independent of the host clipboard and
;; prior test runs.  Vi yanks still exercise the real kill ring and metadata.
(disable-clipboard)

(when (string= *persistence-test-phase* "writer")
  (add-hook *exit-editor-hook* 'persistence-test-before-exit-snapshot 10000)
  (add-hook *exit-editor-hook* 'persistence-test-after-exit-snapshot -10000))

(when (string= *persistence-test-phase* "auto")
  (setf *persistence-test-background-buffer*
        (find-file-buffer
         (persistence-test-path "auto/background.txt"))))

(persistence-test-log "READY phase=~a" *persistence-test-phase*)
