;;;; Persistent find-name-dired-style results for M-s f.

(in-package :lem-yath)

(defparameter *find-name-buffer-name* "*Find*")
(defconstant +find-name-buffer-owner+ 'lem-yath-find-name)
(defvar *find-name-mode-keymap* (make-keymap))
(defvar *find-name-program* nil
  "Absolute find executable override, primarily for controlled tests.")

(define-attribute find-name-marked-attribute
  (t :foreground :base0E :bold t))

(define-condition find-name-request-cancelled (condition) ())

(defstruct (find-name-request
            (:constructor %make-find-name-request (generation buffer)))
  generation
  buffer
  (cancelled-p nil)
  process
  (lock (bt2:make-lock :name "lem-yath/find-name-request")))

(define-major-mode lem-yath-find-name-mode nil
    (:name "Find Name"
     :keymap *find-name-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

;; Pinned Lem's Vi keymap assembly does not include ordinary major-mode maps.
(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-find-name-mode))
  (list *find-name-mode-keymap*))

(defun find-name-split-nul (string)
  "Return the nonempty NUL-terminated records in STRING."
  (loop :with start := 0
        :for end := (position #\Null string :start start)
        :while end
        :when (< start end)
          :collect (subseq string start end)
        :do (setf start (1+ end))))

(defun find-name-display-string (string)
  "Escape controls in STRING so one filesystem entry occupies one line."
  (with-output-to-string (stream)
    (loop :for character :across string
          :for code := (char-code character)
          :do (case character
                (#\\ (write-string "\\\\" stream))
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (otherwise
                 (if (or (< code 32) (= code 127))
                     (format stream "\\x~2,'0X;" code)
                     (write-char character stream)))))))

(defun find-name-relative-path (record)
  (if (alexandria:starts-with-subseq "./" record)
      (subseq record 2)
      record))

(defun find-name-absolute-path (root record)
  "Return RECORD below ROOT without invoking Common Lisp wildcard parsing."
  (if (string= record ".")
      root
      (uiop:parse-native-namestring
       (concatenate 'string
                    (uiop:native-namestring
                     (uiop:ensure-directory-pathname root))
                    (find-name-relative-path record)))))

(defun find-name-results (root output)
  "Turn GNU find's NUL OUTPUT into sorted (DISPLAY . ABSOLUTE) entries."
  (sort
   (mapcar
    (lambda (record)
      (cons record (find-name-absolute-path root record)))
    (find-name-split-nul output))
   #'string<
   :key #'car))

(defun find-name-owned-buffer-p (buffer)
  (and (eq (buffer-value buffer :find-name-owner)
           +find-name-buffer-owner+)
       (eq (buffer-major-mode buffer) 'lem-yath-find-name-mode)))

(defun ensure-find-name-buffer ()
  "Return our result buffer, refusing to repurpose an unrelated *Find*."
  (let ((buffer (get-buffer *find-name-buffer-name*)))
    (cond
      ((null buffer)
       (setf buffer (make-buffer *find-name-buffer-name* :enable-undo-p nil))
       (change-buffer-mode buffer 'lem-yath-find-name-mode)
       (setf (buffer-value buffer :find-name-owner)
             +find-name-buffer-owner+
             (buffer-value buffer :find-name-marks)
             (make-hash-table :test #'equal))
       buffer)
      ((find-name-owned-buffer-p buffer)
       buffer)
      (t
       (editor-error "Buffer ~a already exists and is not a find-name result buffer"
                     *find-name-buffer-name*)))))

(defun find-name-current-generation-p (buffer generation)
  (and (member buffer (buffer-list) :test #'eq)
       (find-name-owned-buffer-p buffer)
       (eql generation (buffer-value buffer :find-name-generation))))

(defun find-name-request-live-p (request)
  (bt2:with-lock-held ((find-name-request-lock request))
    (not (find-name-request-cancelled-p request))))

(defun find-name-request-current-p (request)
  (let ((buffer (find-name-request-buffer request)))
    (and (find-name-current-generation-p
         buffer (find-name-request-generation request))
         (eq request (buffer-value buffer :find-name-request))
         (find-name-request-live-p request))))

(defun cancel-find-name-request (request)
  "Invalidate REQUEST and terminate only the subprocess it owns."
  (let ((process nil))
    (bt2:with-lock-held ((find-name-request-lock request))
      (unless (find-name-request-cancelled-p request)
        (setf (find-name-request-cancelled-p request) t
              process (find-name-request-process request)
              (find-name-request-process request) nil)))
    (when process
      (ignore-errors (uiop:terminate-process process)))
    (not (null process))))

(defun find-name-insert-header (point root pattern status)
  (insert-string point (format nil "Find name results~%"))
  (insert-string point
                 (format nil "Directory: ~a~%"
                         (find-name-display-string
                          (uiop:native-namestring root))))
  (insert-string point
                 (format nil "Pattern:   ~a~%"
                         (find-name-display-string pattern)))
  (insert-string point (format nil "Status:    ~a~%~%" status)))

(defun render-find-name-searching (buffer root pattern)
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (find-name-insert-header (buffer-end-point buffer) root pattern "searching..."))
  (setf (buffer-read-only-p buffer) t)
  (buffer-start (buffer-point buffer))
  (redraw-display))

(defun render-find-name-cancelled (buffer root pattern generation)
  (when (find-name-current-generation-p buffer generation)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (find-name-insert-header
       (buffer-end-point buffer) root pattern "cancelled")
      (insert-string (buffer-end-point buffer)
                     (format nil "Search cancelled. Press g to retry.~%")))
    (setf (buffer-read-only-p buffer) t)
    (buffer-start (buffer-point buffer))
    (redraw-display)))

(defun find-name-mark-key (path)
  (uiop:native-namestring path))

(defun find-name-marks (buffer)
  (or (buffer-value buffer :find-name-marks)
      (setf (buffer-value buffer :find-name-marks)
            (make-hash-table :test #'equal))))

(defun find-name-marked-p (buffer path)
  (gethash (find-name-mark-key path) (find-name-marks buffer)))

(defun find-name-marked-paths (&optional (buffer (current-buffer)))
  "Return marked result paths in deterministic native-name order."
  (let ((paths '()))
    (maphash (lambda (key value)
               (when value (push key paths)))
             (find-name-marks buffer))
    (sort paths #'string<)))

(defun find-name-reconcile-marks (buffer results)
  "Discard marks that are absent from the newly completed RESULTS."
  (let ((present (make-hash-table :test #'equal))
        (marks (find-name-marks buffer))
        (stale '()))
    (dolist (result results)
      (setf (gethash (find-name-mark-key (cdr result)) present) t))
    (maphash (lambda (key value)
               (declare (ignore value))
               (unless (gethash key present)
                 (push key stale)))
             marks)
    (dolist (key stale)
      (remhash key marks))))

(defun render-find-name-results (buffer root pattern generation results error)
  "Render RESULTS only if GENERATION is still current for BUFFER."
  (when (find-name-current-generation-p buffer generation)
    (unless error
      (find-name-reconcile-marks buffer results))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (let ((point (buffer-end-point buffer)))
        (find-name-insert-header
         point root pattern
         (if error
             (format nil "failed: ~a" (find-name-display-string error))
             (format nil "~d ~a"
                     (length results)
                     (if (= 1 (length results)) "match" "matches"))))
        (cond
          (error
           (insert-string point
                          (format nil "Search failed. Press g to retry.~%")))
          ((null results)
           (insert-string point "(no matches)\n"))
          (t
           (with-point ((first-result point :right-inserting))
             (dolist (result results)
               (with-point ((start point :right-inserting))
                 (let ((marked-p (find-name-marked-p buffer (cdr result))))
                   (insert-string point (if marked-p "* " "  "))
                 (insert-string point
                                (format nil "~a~%"
                                        (find-name-display-string (car result))))
                   (put-text-property start point :find-name-path (cdr result))
                   (when marked-p
                     (put-text-property start point :attribute
                                        'find-name-marked-attribute)))))
             (move-point (buffer-point buffer) first-result))))))
    (setf (buffer-read-only-p buffer) t)
    (redraw-display)))

(defun find-name-read-stream (stream)
  (let ((chunk (make-string 8192))
        (output (make-string-output-stream)))
    (loop :for length := (read-sequence chunk stream)
          :until (zerop length)
          :do (write-sequence chunk output :end length))
    (get-output-stream-string output)))

(defun launch-find-name-process (arguments root request)
  "Launch ARGUMENTS and atomically attach the child to REQUEST."
  (bt2:with-lock-held ((find-name-request-lock request))
    (when (find-name-request-cancelled-p request)
      (error 'find-name-request-cancelled))
    (setf (find-name-request-process request)
          (uiop:launch-program arguments
                               :directory root
                               :output :stream
                               :error-output :stream))))

(defun release-find-name-process (request process)
  (bt2:with-lock-held ((find-name-request-lock request))
    (when (eq process (find-name-request-process request))
      (setf (find-name-request-process request) nil))))

(defun run-find-name (root pattern request)
  (let ((find (or *find-name-program* (executable-find "find"))))
    (unless find
      (error "GNU find is not available"))
    (let ((process nil)
          (finished-p nil)
          (error-thread nil))
      (unwind-protect
           (progn
             (setf process
                   (launch-find-name-process
                    (list (namestring find) "." "-name" pattern "-print0")
                    root request))
             (let ((error-output ""))
               (setf error-thread
                     (bt2:make-thread
                      (lambda ()
                        (setf error-output
                              (with-open-stream
                                  (stream (uiop:process-info-error-output process))
                                (find-name-read-stream stream))))
                      :name "lem-yath/find-name-stderr"))
               (let ((output
                       (with-open-stream
                           (stream (uiop:process-info-output process))
                         (find-name-read-stream stream)))
                     (exit-code (uiop:wait-process process)))
                 (bt2:join-thread error-thread)
                 (setf error-thread nil
                       finished-p t)
                 (unless (find-name-request-live-p request)
                   (error 'find-name-request-cancelled))
                 (if (and (integerp exit-code) (zerop exit-code))
                     (values (find-name-results root output) nil)
                     (values nil
                             (let ((message
                                     (string-trim
                                      '(#\Space #\Tab #\Newline #\Return)
                                      error-output)))
                               (if (plusp (length message))
                                   message
                                   (format nil "find exited with status ~a"
                                           exit-code))))))))
        (when (and process (not finished-p))
          (ignore-errors (uiop:terminate-process process))
          (ignore-errors (uiop:wait-process process)))
        (when error-thread
          (ignore-errors (bt2:join-thread error-thread)))
        (release-find-name-process request process)))))

(defun start-find-name-search (buffer root pattern &key preserve-marks)
  "Start a race-safe background search into persistent BUFFER."
  (unless (find-name-owned-buffer-p buffer)
    (editor-error "Not a find-name result buffer"))
  (alexandria:when-let ((previous (buffer-value buffer :find-name-request)))
    (cancel-find-name-request previous))
  (unless preserve-marks
    (clrhash (find-name-marks buffer)))
  (let* ((generation (1+ (or (buffer-value buffer :find-name-generation) 0)))
         (request (%make-find-name-request generation buffer)))
    (setf (buffer-value buffer :find-name-generation) generation
          (buffer-value buffer :find-name-root) root
          (buffer-value buffer :find-name-pattern) pattern
          (buffer-value buffer :find-name-request) request)
    (render-find-name-searching buffer root pattern)
    (bt2:make-thread
     (lambda ()
       (handler-case
           (multiple-value-bind (results error)
               (run-find-name root pattern request)
             (send-event
              (lambda ()
                (when (find-name-request-current-p request)
                  (setf (buffer-value buffer :find-name-request) nil)
                  (render-find-name-results
                   buffer root pattern generation results error)))))
         (find-name-request-cancelled ())
         (error (condition)
           (let ((message (princ-to-string condition)))
             (send-event
              (lambda ()
                (when (find-name-request-current-p request)
                  (setf (buffer-value buffer :find-name-request) nil)
                  (render-find-name-results
                   buffer root pattern generation nil message))))))))
     :name "lem-yath/find-name")))

(defun normalize-find-name-root (directory base)
  (uiop:ensure-directory-pathname
   (truename
    (merge-pathnames directory (uiop:ensure-directory-pathname base)))))

(define-command lem-yath-find-name (&optional directory pattern) ()
  "Find names recursively and show persistent results, like find-name-dired."
  (let* ((base (buffer-directory (current-buffer)))
         (directory
           (or directory
               (prompt-for-directory "Find name in directory: "
                                     :directory base
                                     :default base
                                     :existing t)))
         (pattern
           (or pattern
               (prompt-for-string "Name pattern: "
                                  :initial-value "*"
                                  :history-symbol 'lem-yath-find-name)))
         (root (normalize-find-name-root directory base))
         (buffer (ensure-find-name-buffer)))
    (setf (buffer-directory buffer) root)
    (switch-to-buffer buffer)
    (start-find-name-search buffer root pattern)))

(defun find-name-current-row ()
  "Return the current result line start and its exact path."
  (let ((line (copy-point (current-point) :temporary)))
    (line-start line)
    (values line (text-property-at line :find-name-path))))

(defun ensure-current-find-name-buffer ()
  (unless (find-name-owned-buffer-p (current-buffer))
    (editor-error "Not a find-name result buffer")))

(defun find-name-set-row-mark (line path marked-p)
  (let ((buffer (current-buffer))
        (key (find-name-mark-key path)))
    (if marked-p
        (setf (gethash key (find-name-marks buffer)) t)
        (remhash key (find-name-marks buffer)))
    (with-buffer-read-only buffer nil
      (delete-character line 1)
      (insert-character line (if marked-p #\* #\Space))
      (with-point ((end line :right-inserting))
        (line-end end)
        (put-text-property line end :find-name-path path)
        (put-text-property line end :attribute
                           (and marked-p 'find-name-marked-attribute))))))

(defun find-name-move-result-line (direction)
  (with-point ((next (current-point)))
    (loop :while (line-offset next direction)
          :do (line-start next)
          :when (text-property-at next :find-name-path)
            :do (move-point (current-point) next)
                (return t))))

(defun find-name-mark-lines (marked-p count)
  (ensure-current-find-name-buffer)
  (let ((count (or count 1)))
    (when (zerop count)
      (return-from find-name-mark-lines nil))
    (let ((direction (if (minusp count) -1 1)))
      (dotimes (index (abs count))
        (multiple-value-bind (line path) (find-name-current-row)
          (unless path
            (editor-error "No find result on this line"))
          (find-name-set-row-mark line path marked-p))
        (unless (find-name-move-result-line direction)
          (when (< index (1- (abs count)))
            (return)))))))

(define-command lem-yath-find-name-mark (&optional (count 1)) (:universal)
  "Mark COUNT result rows and advance, like Dired m."
  (find-name-mark-lines t count))

(define-command lem-yath-find-name-unmark (&optional (count 1)) (:universal)
  "Unmark COUNT result rows and advance, like Dired u."
  (find-name-mark-lines nil count))

(define-command lem-yath-find-name-unmark-all () ()
  "Remove every ordinary file mark, like Dired U."
  (ensure-current-find-name-buffer)
  (clrhash (find-name-marks (current-buffer)))
  (with-point ((line (buffer-start-point (current-buffer))))
    (loop
      (alexandria:when-let ((path (text-property-at line :find-name-path)))
        (find-name-set-row-mark line path nil))
      (unless (line-offset line 1) (return)))))

(define-command lem-yath-find-name-toggle-marks () ()
  "Toggle ordinary marks on every result row, like Dired t."
  (ensure-current-find-name-buffer)
  (with-point ((line (buffer-start-point (current-buffer))))
    (loop
      (alexandria:when-let ((path (text-property-at line :find-name-path)))
        (find-name-set-row-mark
         line path (not (find-name-marked-p (current-buffer) path))))
      (unless (line-offset line 1) (return)))))

(define-command lem-yath-find-name-open () ()
  "Open the exact find result on the current line."
  (with-point ((point (current-point)))
    (line-start point)
    (let ((path (text-property-at point :find-name-path)))
      (unless path
        (editor-error "No find result on this line"))
      (unless (uiop:probe-file* path)
        (editor-error "Find result no longer exists: ~a" path))
      (find-file path))))

(define-command lem-yath-find-name-refresh () ()
  "Repeat the search that produced the current *Find* buffer."
  (let* ((buffer (current-buffer))
         (root (buffer-value buffer :find-name-root))
         (pattern (buffer-value buffer :find-name-pattern)))
    (unless (and root pattern)
      (editor-error "No find-name search to refresh"))
    (start-find-name-search buffer root pattern :preserve-marks t)))

(define-command lem-yath-find-name-cancel () ()
  "Cancel the find subprocess owned by the current result buffer."
  (let* ((buffer (current-buffer))
         (request (buffer-value buffer :find-name-request)))
    (when (and request (find-name-request-current-p request))
      (cancel-find-name-request request)
      (when (eq request (buffer-value buffer :find-name-request))
        (setf (buffer-value buffer :find-name-request) nil)
        (render-find-name-cancelled
         buffer
         (buffer-value buffer :find-name-root)
         (buffer-value buffer :find-name-pattern)
         (find-name-request-generation request))))))

(define-key *find-name-mode-keymap* "Return" 'lem-yath-find-name-open)
(define-key *find-name-mode-keymap* "g" 'lem-yath-find-name-refresh)
(define-key *find-name-mode-keymap* "m" 'lem-yath-find-name-mark)
(define-key *find-name-mode-keymap* "u" 'lem-yath-find-name-unmark)
(define-key *find-name-mode-keymap* "U" 'lem-yath-find-name-unmark-all)
(define-key *find-name-mode-keymap* "t" 'lem-yath-find-name-toggle-marks)
(define-key *find-name-mode-keymap* "C-c C-k" 'lem-yath-find-name-cancel)
(define-key *find-name-mode-keymap* "q" 'quit-active-window)
