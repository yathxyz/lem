(in-package :lem-yath)

(defvar *daily-workflows-fixture-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_DAILY_WORKFLOWS_ROOT")))

(defvar *daily-workflows-fixture-report*
  (uiop:getenv "LEM_YATH_DAILY_WORKFLOWS_REPORT"))

(defun daily-workflows-fixture-path (relative)
  (merge-pathnames relative *daily-workflows-fixture-root*))

(defun daily-workflows-fixture-log (control &rest arguments)
  (with-open-file (stream *daily-workflows-fixture-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun daily-workflows-fixture-write (relative contents)
  (let ((path (daily-workflows-fixture-path relative)))
    (ensure-directories-exist path)
    (alexandria:write-string-into-file contents path :if-exists :supersede)
    path))

(defun daily-workflows-fixture-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun daily-workflows-fixture-native-file-name (path)
  (let* ((native (uiop:native-namestring path))
         (separator (position #\/ native :from-end t)))
    (if separator (subseq native (1+ separator)) native)))

(defun daily-workflows-fixture-native-basename (path)
  (let* ((native (if (stringp path) path (uiop:native-namestring path)))
         (separator (position #\/ native :from-end t)))
    (if separator (subseq native (1+ separator)) native)))

(defun daily-workflows-fixture-encode (string)
  (with-output-to-string (stream)
    (loop for character across string
          do (case character
               (#\Newline (write-string "\\n" stream))
               (#\Return (write-string "\\r" stream))
               (#\\ (write-string "\\\\" stream))
               (otherwise (write-char character stream))))))

(defun daily-workflows-fixture-record-buffer (label)
  (daily-workflows-fixture-log
   "BUFFER label=~a text=~a"
   label
   (daily-workflows-fixture-encode
    (daily-workflows-fixture-buffer-text))))

(defun daily-workflows-fixture-record-visual (label)
  (if (lem-vi-mode/visual:visual-p)
      (destructuring-bind (start end) (lem-vi-mode/visual:visual-range)
        (daily-workflows-fixture-log
         "VISUAL label=~a active=yes type=~a point=~d start=~d end=~d"
         label
         (cond
           ((lem-vi-mode/visual:visual-line-p) "line")
           ((lem-vi-mode/visual:visual-screen-line-p) "screen-line")
           ((lem-vi-mode/visual:visual-block-p) "block")
           (t "char"))
         (position-at-point (current-point))
         (position-at-point start)
         (position-at-point end)))
      (daily-workflows-fixture-log
       "VISUAL label=~a active=no point=~d start=-1 end=-1"
       label
       (position-at-point (current-point))))
  (daily-workflows-fixture-record-buffer label))

(defun daily-workflows-fixture-recent-path (index)
  (daily-workflows-fixture-path
   (format nil "recent/recent-~3,'0d.txt" index)))

(defun daily-workflows-fixture-populate-recent-files ()
  (dotimes (index 305)
    (let ((path
            (daily-workflows-fixture-write
             (format nil "recent/recent-~3,'0d.txt" index)
             (if (= index 42)
                 (format nil "RECENT TARGET 042~%")
                 (format nil "recent fixture ~3,'0d~%" index)))))
      (multiple-value-bind (buffer new-file-p) (find-file-buffer path)
        (declare (ignore new-file-p))
        (delete-buffer buffer))))
  ;; Reopening an older entry must move it to the front without duplicating it.
  (multiple-value-bind (buffer new-file-p)
      (find-file-buffer (daily-workflows-fixture-recent-path 42))
    (declare (ignore new-file-p))
    (delete-buffer buffer)))

(defun daily-workflows-fixture-record-mru (phase)
  (let* ((recent (lem-core/commands/file:recent-files))
         (target (namestring (daily-workflows-fixture-recent-path 42)))
         (late (namestring (daily-workflows-fixture-recent-path 5)))
         (oldest (namestring (daily-workflows-fixture-recent-path 0)))
         (first (first recent)))
    (daily-workflows-fixture-log
     (concatenate
      'string
      "MRU phase=~a limit=~s count=~d first=~a target-count=~d "
      "late-index=~s oldest-present=~a")
     phase
     lem-core/commands/file:*file-history-limit*
     (length recent)
     (if first (file-namestring first) "none")
     (count target recent :test #'string=)
     (position late recent :test #'string=)
     (if (member oldest recent :test #'string=) "yes" "no"))))

(defun daily-workflows-fixture-record-preseeded-mru (phase)
  (let* ((history (lem-core/commands/file:file-history))
         (memory (lem/common/history:history-data-list history))
         (history-path (merge-pathnames "history/files" (lem-home)))
         (disk (uiop:read-file-form history-path))
         (expected
           (loop :for index :from 5 :below 305
                 :collect
                 (namestring
                  (daily-workflows-fixture-path
                   (format nil "preseed/preseed-~3,'0d.txt" index)))))
         (recent (reverse memory))
         (oldest (namestring
                  (daily-workflows-fixture-path
                   "preseed/preseed-000.txt")))
         (first (first recent)))
    (daily-workflows-fixture-log
     (concatenate
      'string
      "MRU-PRESEED phase=~a limit=~s count=~d index=~d first=~a "
      "retained-oldest=~a oldest-present=~a memory-order=~a disk-order=~a")
     phase
     lem-core/commands/file:*file-history-limit*
     (length recent)
     (lem/common/history::history-index history)
     (if first (file-namestring first) "none")
     (if memory (file-namestring (first memory)) "none")
     (if (member oldest recent :test #'string=) "yes" "no")
     (if (equal memory expected) "yes" "no")
     (if (equal disk expected) "yes" "no"))))

(define-command lem-yath-test-record-visual-before () ()
  (daily-workflows-fixture-record-visual "visual-before"))

(define-command lem-yath-test-record-visual-after () ()
  (daily-workflows-fixture-record-visual "visual-after"))

(define-command lem-yath-test-record-line-before-duplicate () ()
  (daily-workflows-fixture-log
   "POINT label=line-before-duplicate point=~d"
   (position-at-point (current-point))))

(define-command lem-yath-test-record-line-after-duplicate () ()
  (daily-workflows-fixture-record-buffer "line-after-duplicate")
  (daily-workflows-fixture-log
   "POINT label=line-after-duplicate point=~d"
   (position-at-point (current-point))))

(define-command lem-yath-test-record-line-after-undo () ()
  (daily-workflows-fixture-record-buffer "line-after-undo"))

(define-command lem-yath-test-record-structural-guard () ()
  (daily-workflows-fixture-record-buffer "structural-guard"))

(define-command lem-yath-test-record-current-buffer () ()
  (daily-workflows-fixture-log
   "CURRENT name=~a file=~a text=~a"
   (buffer-name (current-buffer))
   (if (buffer-filename (current-buffer))
       (file-namestring (buffer-filename (current-buffer)))
       "none")
   (daily-workflows-fixture-encode
    (daily-workflows-fixture-buffer-text))))

(define-command lem-yath-test-record-find-name-current () ()
  (let ((buffer (current-buffer)))
    (with-point ((point (current-point)))
      (line-start point)
      (let ((path (text-property-at point :find-name-path)))
        (daily-workflows-fixture-log
         "FIND-CURRENT name=~a readonly=~a path=~a"
         (buffer-name buffer)
         (if (buffer-read-only-p buffer) "yes" "no")
         (if path
             (daily-workflows-fixture-native-file-name path)
             "none")))))
  (daily-workflows-fixture-record-buffer "find-current"))

(define-command lem-yath-test-record-find-name-persistence () ()
  (let ((buffer (get-buffer *find-name-buffer-name*)))
    (daily-workflows-fixture-log
     "FIND-PERSIST exists=~a readonly=~a current=~a"
     (if buffer "yes" "no")
     (if (and buffer (buffer-read-only-p buffer)) "yes" "no")
     (buffer-name (current-buffer)))))

(define-command lem-yath-test-record-find-name-marks () ()
  (multiple-value-bind (line current) (find-name-current-row)
    (declare (ignore line))
    (let ((marked
            (mapcar
             (lambda (path)
               (daily-workflows-fixture-encode
                (daily-workflows-fixture-native-basename path)))
             (find-name-marked-paths))))
      (daily-workflows-fixture-log
       "FIND-MARKS count=~d current=~a marked=~{~a~^,~}"
       (length marked)
       (if current
           (daily-workflows-fixture-encode
            (daily-workflows-fixture-native-basename current))
           "none")
       marked))))

(define-command lem-yath-test-submit-find-name-root () ()
  "Submit the exact fixture root without selecting an automatic child row."
  (lem/prompt-window::replace-prompt-input
   (namestring (daily-workflows-fixture-path "find-name/")))
  (lem/prompt-window::prompt-execute))

(define-command lem-yath-test-submit-find-name-ops-root () ()
  (lem/prompt-window::replace-prompt-input
   (namestring (daily-workflows-fixture-path "find-name-ops/")))
  (lem/prompt-window::prompt-execute))

(define-command lem-yath-test-find-name-copy-to-target () ()
  (find-name-copy-to
   (namestring (daily-workflows-fixture-path "find-name-copy-target/")))
  (daily-workflows-fixture-log "FIND-COPY-COMMAND done"))

(defun daily-workflows-fixture-key-command (keys)
  (let* ((prefix (lem-core::lookup-keybind (lem-core::parse-keyspec keys)))
         (command (and prefix (lem-core::prefix-suffix prefix))))
    (if command (string command) "none")))

(define-command lem-yath-test-find-name-bindings () ()
  (daily-workflows-fixture-log
   "FIND-BINDINGS C=~a R=~a D=~a m=~a"
   (daily-workflows-fixture-key-command "C")
   (daily-workflows-fixture-key-command "R")
   (daily-workflows-fixture-key-command "D")
   (daily-workflows-fixture-key-command "m")))

(define-command lem-yath-test-find-name-rename-to-target () ()
  (find-name-rename-to
   (namestring (daily-workflows-fixture-path "find-name-ops/renamed.op")))
  (daily-workflows-fixture-log "FIND-RENAME-COMMAND done"))

(define-command lem-yath-test-use-slow-find () ()
  (setf *find-name-program*
        (uiop:parse-native-namestring
         (uiop:getenv "LEM_YATH_DAILY_WORKFLOWS_SLOW_FIND")))
  (daily-workflows-fixture-log "FIND-SLOW READY"))

(define-command lem-yath-test-find-name-buffer-guards () ()
  (let ((collision-rejected-p nil)
        (collision-intact-p nil)
        (stale-start-rejected-p nil)
        (stale-intact-p nil)
        (root-copy-rejected-p nil))
    (let ((buffer (make-buffer *find-name-buffer-name* :enable-undo-p nil)))
      (unwind-protect
           (progn
             (insert-string (buffer-end-point buffer) "COLLISION SENTINEL")
             (handler-case
                 (lem-yath-find-name
                  (namestring (daily-workflows-fixture-path "find-name/"))
                  "*.match")
               (error ()
                 (setf collision-rejected-p t)))
             (setf collision-intact-p
                   (string= "COLLISION SENTINEL"
                            (points-to-string (buffer-start-point buffer)
                                              (buffer-end-point buffer)))))
        (when (member buffer (buffer-list) :test #'eq)
          (delete-buffer buffer))))
    (let ((buffer (ensure-find-name-buffer)))
      (unwind-protect
           (progn
             (setf (buffer-value buffer :find-name-generation) 41)
             (with-buffer-read-only buffer nil
               (erase-buffer buffer)
               (insert-string (buffer-end-point buffer) "STALE SENTINEL"))
             (change-buffer-mode
              buffer 'lem/buffer/fundamental-mode:fundamental-mode)
             (handler-case
                 (start-find-name-search
                  buffer *daily-workflows-fixture-root* "*")
               (error ()
                 (setf stale-start-rejected-p t)))
             (render-find-name-results
              buffer *daily-workflows-fixture-root* "*" 41 nil nil)
             (setf stale-intact-p
                   (string= "STALE SENTINEL"
                            (points-to-string (buffer-start-point buffer)
                                              (buffer-end-point buffer)))))
        (when (member buffer (buffer-list) :test #'eq)
          (delete-buffer buffer))))
    (handler-case
        (find-name-destination-pairs
         '("/") (namestring (daily-workflows-fixture-path "find-name/")))
      (error ()
        (setf root-copy-rejected-p t)))
    (daily-workflows-fixture-log
     (concatenate
      'string
      "FIND-GUARDS collision-rejected=~a collision-intact=~a "
      "stale-start-rejected=~a stale-intact=~a root-copy-rejected=~a")
     (if collision-rejected-p "yes" "no")
     (if collision-intact-p "yes" "no")
     (if stale-start-rejected-p "yes" "no")
     (if stale-intact-p "yes" "no")
     (if root-copy-rejected-p "yes" "no"))))

(define-command lem-yath-test-setup-buffer-list () ()
  (let* ((alpha-path
           (daily-workflows-fixture-write
            "buffer-list/daily-alpha-buffer.txt"
            (format nil "DAILY ALPHA BUFFER OTHER~%")))
         (beta-path
           (daily-workflows-fixture-write
            "buffer-list/daily-zz-target-buffer.txt"
            (format nil "DAILY BETA BUFFER TARGET~%")))
         (alpha-buffer (find-file-buffer alpha-path))
         (beta-buffer (find-file-buffer beta-path)))
    (daily-workflows-fixture-log
     "BUFFER-LIST READY alpha=~a beta=~a"
     (buffer-name alpha-buffer)
     (buffer-name beta-buffer))))

(define-command lem-yath-test-add-control-recent () ()
  "Put a newline-containing pathname at the head of the recent-file MRU."
  (let* ((path
           (daily-workflows-fixture-write
            (format nil "recent/control~%name.txt")
            (format nil "CONTROL RECENT TARGET~%")))
         (buffer (find-file-buffer path)))
    (delete-buffer buffer)
    (lem/common/history:add-history
     (lem-core/commands/file:file-history)
     (namestring path)
     :allow-duplicates nil
     :move-to-top t)
    (daily-workflows-fixture-log
     "CONTROL-RECENT READY label=~a"
     (completion-path-display-string (namestring path)))
    (lem-yath-find-recent-file)))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F3" 'lem-yath-test-record-line-before-duplicate)
  (define-key keymap "F5" 'lem-yath-test-record-visual-before)
  (define-key keymap "F6" 'lem-yath-test-record-visual-after)
  (define-key keymap "F7" 'lem-yath-test-record-line-after-duplicate)
  (define-key keymap "F8" 'lem-yath-test-record-line-after-undo)
  (define-key keymap "F9" 'lem-yath-test-record-structural-guard)
  (define-key keymap "F10" 'lem-yath-test-record-current-buffer)
  (define-key keymap "F11" 'lem-yath-test-record-find-name-current)
  (define-key keymap "F12" 'lem-yath-test-record-find-name-persistence)
  (define-key keymap "F2" 'lem-yath-test-record-find-name-marks))

(define-key lem/prompt-window::*prompt-mode-keymap*
  "F4" 'lem-yath-test-submit-find-name-root)
(define-key lem/prompt-window::*prompt-mode-keymap*
  "F1" 'lem-yath-test-submit-find-name-ops-root)

(let ((phase (or (uiop:getenv "LEM_YATH_DAILY_WORKFLOWS_PHASE") "editing")))
  (cond
    ((string= phase "populate")
     (daily-workflows-fixture-populate-recent-files)
     (daily-workflows-fixture-record-mru phase))
    ((string= phase "verify")
     (daily-workflows-fixture-record-mru phase))
    ((member phase '("preseed" "preseed-verify") :test #'string=)
     (daily-workflows-fixture-record-preseeded-mru phase))
    ((string= phase "editing"))
    (t
     (error "Unknown daily-workflows fixture phase: ~a" phase)))
  (daily-workflows-fixture-log "READY ~a" phase))
