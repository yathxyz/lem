;;;; Persistent find-name-dired-style results for M-s f.

(in-package :lem-yath)

(defparameter *find-name-buffer-name* "*Find*")
(defconstant +find-name-buffer-owner+ 'lem-yath-find-name)
(defvar *find-name-mode-keymap* (make-keymap))
(defvar *find-name-vi-keymap* (make-keymap))
(defvar *find-name-program* nil
  "Absolute find executable override, primarily for controlled tests.")

(define-attribute find-name-marked-attribute
  (t :foreground :base0E :bold t))

(defstruct (find-name-result
            (:constructor make-find-name-result (display path size)))
  display
  path
  size)

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
  (setf (variable-value 'line-wrap :buffer (current-buffer)) nil)
  (setf (buffer-read-only-p (current-buffer)) t))

;; Pinned Lem's Vi keymap assembly does not include ordinary major-mode maps.
(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-find-name-mode))
  (list *find-name-vi-keymap*))

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
  "Turn GNU find's NUL OUTPUT into sorted, metadata-bearing entries."
  (sort
   (mapcar
    (lambda (record)
      (let ((path (find-name-absolute-path root record)))
        (make-find-name-result
         record path (dirvish-size-field path))))
    (find-name-split-nul output))
   #'string<
   :key #'find-name-result-display))

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
  (buffer-unmark buffer)
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
    (buffer-unmark buffer)
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
      (setf (gethash (find-name-mark-key (find-name-result-path result))
                     present)
            t))
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
                 (let ((marked-p
                         (find-name-marked-p
                          buffer (find-name-result-path result))))
                   (insert-string point (if marked-p "* " "  "))
                   (insert-string
                    point
                    (format nil "~a~%"
                            (find-name-display-string
                             (find-name-result-display result))))
                   (put-text-property
                    start point :find-name-path (find-name-result-path result))
                   (put-text-property
                    start point :dirvish-size (find-name-result-size result))
                   (when marked-p
                     (put-text-property start point :attribute
                                        'find-name-marked-attribute)))))
             (move-point (buffer-point buffer) first-result))))))
    (setf (buffer-read-only-p buffer) t)
    (buffer-unmark buffer)
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

(defun find-name-native-path (path)
  (etypecase path
    (string path)
    (pathname (uiop:native-namestring path))))

(defun find-name-path-stat (path)
  "Return PATH's lstat data, including for dangling symbolic links."
  #+sbcl
  (handler-case
      (sb-posix:lstat (find-name-native-path path))
    (error () nil))
  #-sbcl
  (error "Find-name file operations require the supported SBCL runtime"))

(defun find-name-path-exists-p (path)
  (not (null (find-name-path-stat path))))

(defun find-name-real-directory-p (path)
  "Return true only for an actual directory, never a symlink to one."
  (alexandria:when-let ((stat (find-name-path-stat path)))
    (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
       sb-posix:s-ifdir)))

(defun find-name-program-path (name)
  (or (executable-find name)
      (editor-error "Required file-operation program is unavailable: ~a" name)))

(defun find-name-run-file-program (name arguments)
  "Run NAME with exact argv ARGUMENTS and return its standard output."
  (multiple-value-bind (output error-output exit-code)
      (uiop:run-program
       (cons (namestring (find-name-program-path name)) arguments)
       :output :string
       :error-output :string
       :ignore-error-status t)
    (unless (and (integerp exit-code) (zerop exit-code))
      (let ((detail
              (string-trim '(#\Space #\Tab #\Newline #\Return)
                           error-output)))
        (error "~a failed~@[ (~a)~]: ~a"
               name exit-code
               (if (plusp (length detail)) detail "no diagnostic"))))
    output))

(defun find-name-directory-nonempty-p (path)
  "Return whether real directory PATH has at least one child."
  (plusp
   (length
    (find-name-run-file-program
     "find"
     (list (find-name-native-path path)
           "-mindepth" "1" "-maxdepth" "1" "-printf" "." "-quit")))))

(defun find-name-operation-paths ()
  "Return existing marked paths, or the existing current-row path."
  (ensure-current-find-name-buffer)
  (when (buffer-value (current-buffer) :find-name-request)
    (editor-error "Wait for the find-name search to finish, or cancel it"))
  (let ((paths (find-name-marked-paths)))
    (when (null paths)
      (multiple-value-bind (line current) (find-name-current-row)
        (declare (ignore line))
        (unless current
          (editor-error "No marked or current find result"))
        (setf paths (list (find-name-native-path current)))))
    (dolist (path paths)
      (unless (find-name-path-exists-p path)
        (editor-error "Find result no longer exists: ~a"
                      (find-name-display-string path))))
    paths))

(defun find-name-native-basename (path)
  (let* ((native (string-right-trim '(#\/) (find-name-native-path path)))
         (slash (position #\/ native :from-end t)))
    (when (zerop (length native))
      (editor-error "Cannot derive a destination name for filesystem root"))
    (subseq native (if slash (1+ slash) 0))))

(defun find-name-path-below (directory basename)
  (uiop:parse-native-namestring
   (concatenate 'string
                (string-right-trim '(#\/) (find-name-native-path directory))
                "/"
                basename)))

(defun find-name-destination-pairs (sources target)
  "Resolve SOURCES to exact destinations beneath TARGET where appropriate."
  (let* ((target (find-name-native-path target))
         (target-directory-p (find-name-real-directory-p target)))
    (when (and (rest sources) (not target-directory-p))
      (editor-error "The destination for multiple files must be an existing directory"))
    (let ((pairs
            (mapcar
             (lambda (source)
               (cons source
                     (find-name-native-path
                      (if target-directory-p
                          (find-name-path-below
                           target (find-name-native-basename source))
                          target))))
             sources)))
      (dolist (pair pairs)
        (when (string= (car pair) (cdr pair))
          (editor-error "Source and destination are the same: ~a"
                        (find-name-display-string (car pair))))
        (when (and (member (cdr pair) sources :test #'string=)
                   (not (string= (car pair) (cdr pair))))
          (editor-error "A destination is also a selected source: ~a"
                        (find-name-display-string (cdr pair)))))
      (let ((seen (make-hash-table :test #'equal)))
        (dolist (pair pairs)
          (when (gethash (cdr pair) seen)
            (editor-error "Selected entries have the same destination: ~a"
                          (find-name-display-string (cdr pair))))
          (setf (gethash (cdr pair) seen) t)))
      pairs)))

(defun find-name-confirm-overwrites (pairs)
  "Preflight PAIRS and omit existing destinations the user declines."
  (loop :for pair :in pairs
        :unless (and (find-name-path-exists-p (cdr pair))
                     (not
                      (prompt-for-y-or-n-p
                       (format nil "Overwrite ~a?"
                               (find-name-display-string (cdr pair))))))
          :collect pair))

(defun find-name-confirm-recursive-copies (pairs)
  "Apply Dired's top-level confirmation policy to directory copies."
  (loop :for pair :in pairs
        :unless (and (find-name-real-directory-p (car pair))
                     (not
                      (prompt-for-y-or-n-p
                       (format nil "Recursively copy directory ~a?"
                               (find-name-display-string (car pair))))))
          :collect pair))

(defun find-name-refresh-after-operation ()
  (start-find-name-search
   (current-buffer)
   (buffer-value (current-buffer) :find-name-root)
   (buffer-value (current-buffer) :find-name-pattern)
   :preserve-marks t))

(defun find-name-perform-pairs (verb pairs program arguments mark-renames-p)
  "Apply PROGRAM to PAIRS, refreshing even after a partial failure."
  (let ((completed 0)
        (failure nil)
        (marks (find-name-marks (current-buffer))))
    (dolist (pair pairs)
      (handler-case
          (progn
            (find-name-run-file-program
             program (append arguments (list (car pair) (cdr pair))))
            (when (and mark-renames-p
                       (gethash (find-name-mark-key (car pair)) marks))
              (remhash (find-name-mark-key (car pair)) marks)
              (setf (gethash (find-name-mark-key (cdr pair)) marks) t))
            (incf completed))
        (error (condition)
          (setf failure condition)
          (return))))
    (when (plusp completed)
      (find-name-refresh-after-operation))
    (when failure
      (editor-error "~a stopped after ~d of ~d entries: ~a"
                    verb completed (length pairs) failure))
    (if (plusp completed)
        (message "~a ~d ~a"
                 verb completed (if (= completed 1) "entry" "entries"))
        (message "No entries changed"))))

(defun find-name-prompt-destination (prompt)
  (prompt-for-file prompt
                   :directory (buffer-directory (current-buffer))
                   :existing nil))

(defun find-name-copy-to (target)
  (let* ((sources (find-name-operation-paths))
         (pairs (find-name-confirm-overwrites
                 (find-name-confirm-recursive-copies
                  (find-name-destination-pairs sources target)))))
    (find-name-perform-pairs
     "Copied" pairs "cp" '("-aT" "--remove-destination" "--") nil)))

(define-command lem-yath-find-name-copy () ()
  "Copy marked entries, or the current entry, like Dired C."
  (find-name-copy-to (find-name-prompt-destination "Copy to: ")))

(defun find-name-rename-to (target)
  (let* ((sources (find-name-operation-paths))
         (pairs (find-name-confirm-overwrites
                 (find-name-destination-pairs sources target))))
    (find-name-perform-pairs "Renamed" pairs "mv" '("-T" "--") t)))

(define-command lem-yath-find-name-rename () ()
  "Rename marked entries, or the current entry, like Dired R."
  (find-name-rename-to (find-name-prompt-destination "Rename to: ")))

(define-command lem-yath-find-name-delete () ()
  "Delete marked entries, or the current entry, like Dired D."
  (let ((paths (find-name-operation-paths)))
    (unless
        (prompt-for-y-or-n-p
         (format nil "Delete ~d selected ~a?"
                 (length paths) (if (= (length paths) 1) "entry" "entries")))
      (message "No deletions performed")
      (return-from lem-yath-find-name-delete nil))
    (let ((completed 0)
          (failure nil)
          (marks (find-name-marks (current-buffer))))
      (dolist (path paths)
        (unless (and (find-name-real-directory-p path)
                     (find-name-directory-nonempty-p path)
                     (not
                      (prompt-for-y-or-n-p
                       (format nil "Recursively delete directory ~a?"
                               (find-name-display-string path)))))
          (handler-case
              (progn
                (find-name-run-file-program
                 "rm" (list (if (find-name-real-directory-p path) "-rf" "-f")
                            "--" path))
                (remhash (find-name-mark-key path) marks)
                (incf completed))
            (error (condition)
              (setf failure condition)
              (return)))))
      (when (plusp completed)
        (find-name-refresh-after-operation))
      (when failure
        (editor-error "Delete stopped after ~d of ~d entries: ~a"
                      completed (length paths) failure))
      (message "Deleted ~d ~a"
               completed (if (= completed 1) "entry" "entries")))))

(defun find-name-set-row-mark (line path marked-p)
  (let ((buffer (current-buffer))
        (key (find-name-mark-key path))
        (size (text-property-at line :dirvish-size)))
    (if marked-p
        (setf (gethash key (find-name-marks buffer)) t)
        (remhash key (find-name-marks buffer)))
    (with-buffer-read-only buffer nil
      (delete-character line 1)
      (insert-character line (if marked-p #\* #\Space))
      (with-point ((end line :right-inserting))
        (line-end end)
        (put-text-property line end :find-name-path path)
        (put-text-property line end :dirvish-size size)
        (put-text-property line end :attribute
                           (and marked-p 'find-name-marked-attribute))))
    (buffer-unmark buffer)))

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

(dolist (keymap (list *find-name-mode-keymap* *find-name-vi-keymap*))
  (define-key keymap "Return" 'lem-yath-find-name-open)
  (define-key keymap "g" 'lem-yath-find-name-refresh)
  (define-key keymap "m" 'lem-yath-find-name-mark)
  (define-key keymap "u" 'lem-yath-find-name-unmark)
  (define-key keymap "U" 'lem-yath-find-name-unmark-all)
  (define-key keymap "t" 'lem-yath-find-name-toggle-marks)
  (define-key keymap "C" 'lem-yath-find-name-copy)
  (define-key keymap "R" 'lem-yath-find-name-rename)
  (define-key keymap "D" 'lem-yath-find-name-delete)
  (define-key keymap "C-c C-k" 'lem-yath-find-name-cancel)
  (define-key keymap "q" 'quit-active-window))
