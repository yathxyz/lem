;;;; Stable, project-aware buffer formatting.
;;;;
;;;; Apheleia is enabled from prog-mode in the Emacs configuration.  This
;;;; module keeps its important contract: format unsaved buffer text, apply a
;;;; patch without throwing point back to the start, and format again after a
;;;; normal save before LSP's didSave hook observes the buffer.  External
;;;; commands are always argv vectors and receive the buffer on stdin.

(in-package :lem-yath)

(defparameter *formatting-timeout* 10
  "Maximum wall-clock seconds allowed for one external formatter.")

(defparameter *formatting-output-limit* (* 16 1024 1024)
  "Largest formatter stdout accepted into a buffer.")

(defparameter *formatting-alignment-limit* 400
  "Largest replacement region given character-level point alignment.")

(defstruct formatter-spec
  id
  mode-class
  command-builder
  function
  (priority 0))

(defvar *formatter-spec-registry* (make-hash-table :test #'eq))
(defvar *registered-builtin-formatter-ids* nil)

(defun formatting-mode-class-p (class)
  (and (consp class)
       (stringp (car class))
       (stringp (cdr class))))

(defun register-format-backend
    (id mode-class &key command-builder function (priority 0))
  "Register or replace one formatter backend under stable symbol ID.

MODE-CLASS is a (PACKAGE-NAME . CLASS-NAME) pair.  COMMAND-BUILDER receives
the buffer and returns a direct argv list or NIL when its executable is not
available.  FUNCTION, used for an in-process formatter, receives the buffer
text and buffer and returns formatted text."
  (check-type id symbol)
  (check-type priority real)
  (unless (formatting-mode-class-p mode-class)
    (error "Invalid formatter mode class: ~s" mode-class))
  (unless (or command-builder function)
    (error "Formatter ~a needs a command builder or function" id))
  (when (and command-builder function)
    (error "Formatter ~a cannot be both external and in-process" id))
  (setf (gethash id *formatter-spec-registry*)
        (make-formatter-spec
         :id id
         :mode-class mode-class
         :command-builder (and command-builder
                               (alexandria:ensure-function command-builder))
         :function (and function (alexandria:ensure-function function))
         :priority priority))
  id)

(defun register-builtin-format-backend (id mode-class &rest options)
  (apply #'register-format-backend id mode-class options)
  (pushnew id *registered-builtin-formatter-ids*)
  id)

(defun clear-builtin-format-backends ()
  (dolist (id *registered-builtin-formatter-ids*)
    (remhash id *formatter-spec-registry*))
  (setf *registered-builtin-formatter-ids* nil))

(defun formatter-specs ()
  (sort (loop :for spec :being :each :hash-value
                :of *formatter-spec-registry*
              :collect spec)
        (lambda (left right)
          (or (< (formatter-spec-priority left)
                 (formatter-spec-priority right))
              (and (= (formatter-spec-priority left)
                      (formatter-spec-priority right))
                   (string< (symbol-name (formatter-spec-id left))
                            (symbol-name (formatter-spec-id right))))))))

(defun formatting-spec-matches-buffer-p (spec buffer)
  (let ((mode (ignore-errors
                (ensure-mode-object (buffer-major-mode buffer)))))
    (and mode
         (mode-object-typep mode (formatter-spec-mode-class spec)))))

(defun formatting-resolve-spec (&optional (buffer (current-buffer)))
  "Return the most specific registered formatter for BUFFER, if any."
  (find-if (lambda (spec)
             (formatting-spec-matches-buffer-p spec buffer))
           (formatter-specs)))

;;; --- safe command construction -------------------------------------------

(defun formatting-native-name (path)
  (etypecase path
    (pathname (uiop:native-namestring path))
    (string path)))

(defun formatting-executable (name)
  (alexandria:when-let ((path (executable-find name)))
    (formatting-native-name path)))

(defun formatting-parent-directory (directory)
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (parent (uiop:pathname-parent-directory-pathname directory)))
    (unless (uiop:pathname-equal directory parent)
      parent)))

(defun formatting-project-executable (name buffer)
  "Resolve NAME from node_modules/.bin above BUFFER, then from PATH."
  (loop :with directory = (ignore-errors
                            (uiop:ensure-directory-pathname
                             (buffer-directory buffer)))
        :while directory
        :for candidate = (merge-pathnames
                          (format nil "node_modules/.bin/~a" name)
                          directory)
        :when (uiop:file-exists-p candidate)
          :return (formatting-native-name candidate)
        :do (setf directory (formatting-parent-directory directory))
        :finally (return (formatting-executable name))))

(defun formatting-buffer-pathname (buffer extension)
  (or (buffer-filename buffer)
      (merge-pathnames (format nil "lem-yath-buffer.~a" extension)
                       (buffer-directory buffer))))

(defun formatting-command (executable &rest arguments)
  (when executable
    (cons executable arguments)))

(defun formatting-black-command (buffer)
  (formatting-command
   (formatting-executable "black")
   "--quiet"
   "--stdin-filename"
   (formatting-native-name (formatting-buffer-pathname buffer "py"))
   "-"))

(defun formatting-rustfmt-command (buffer)
  (declare (ignore buffer))
  (formatting-command (formatting-executable "rustfmt")
                      "--quiet" "--emit" "stdout"))

(defun formatting-gofmt-command (buffer)
  (declare (ignore buffer))
  (formatting-command (formatting-executable "gofmt")))

(defun formatting-nixfmt-command (buffer)
  (declare (ignore buffer))
  (formatting-command
   (or (formatting-executable "nixfmt-rfc-style")
       (formatting-executable "nixfmt")
       (formatting-executable "alejandra"))))

(defun formatting-clang-command (buffer)
  (formatting-command
   (formatting-executable "clang-format")
   "-assume-filename"
   (formatting-native-name (formatting-buffer-pathname buffer "c"))))

(defun formatting-prettier-command (buffer)
  (alexandria:when-let
      ((executable (formatting-project-executable "prettier" buffer)))
    (let ((command
            (list executable
                  "--stdin-filepath"
                  (formatting-native-name
                   (formatting-buffer-pathname buffer "js")))))
      (if (variable-value 'indent-tabs-mode :default buffer)
          (append command (list "--use-tabs"))
          (append command
                  (list "--tab-width"
                        (princ-to-string
                         (variable-value 'tab-width :default buffer))))))))

(defun formatting-google-java-command (buffer)
  (declare (ignore buffer))
  (formatting-command (formatting-executable "google-java-format") "-"))

(defun formatting-cljfmt-command (buffer)
  (declare (ignore buffer))
  (formatting-command (formatting-executable "cljfmt") "fix" "-"))

(defun formatting-tofu-command (buffer)
  (declare (ignore buffer))
  (formatting-command (or (formatting-executable "tofu")
                          (formatting-executable "terraform"))
                      "fmt" "-"))

(defun formatting-zig-command (buffer)
  (declare (ignore buffer))
  (formatting-command (formatting-executable "zig") "fmt" "--stdin"))

(defun formatting-stylua-command (buffer)
  (declare (ignore buffer))
  (formatting-command (formatting-executable "stylua") "-"))

(defun formatting-lisp-text (text buffer)
  (let ((temporary (make-buffer " *lem-yath-formatting*"
                                :temporary t
                                :enable-undo-p nil)))
    (unwind-protect
         (progn
           (insert-string (buffer-start-point temporary) text)
           (change-buffer-mode temporary (buffer-major-mode buffer))
           (indent-buffer temporary)
           (points-to-string (buffer-start-point temporary)
                             (buffer-end-point temporary)))
      (unless (deleted-buffer-p temporary)
        (delete-buffer temporary)))))

;;; --- bounded formatter execution -----------------------------------------

(defun formatting-timeout-command (command)
  (let ((timeout (formatting-executable "timeout")))
    (unless timeout
      (error "GNU timeout is unavailable; refusing to run an unbounded formatter"))
    (append (list timeout
                  "--signal=TERM"
                  "--kill-after=1"
                  (princ-to-string *formatting-timeout*))
            command)))

(defun formatting-error-summary (text &optional (limit 2000))
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return)
                           (or text ""))))
    (if (<= (length text) limit)
        text
        (concatenate 'string (subseq text 0 limit) "…"))))

(defun formatting-run-command (buffer command input)
  (multiple-value-bind (stdout stderr status)
      (with-input-from-string (stream input)
        (uiop:run-program
         (formatting-timeout-command command)
         :directory (buffer-directory buffer)
         :input stream
         :output :string
         :error-output :string
         :ignore-error-status t))
    (unless (zerop status)
      (error "Formatter ~a exited ~d~@[ — ~a~]"
             (file-namestring (first command))
             status
             (let ((summary (formatting-error-summary stderr)))
               (unless (zerop (length summary)) summary))))
    (when (> (length stdout) *formatting-output-limit*)
      (error "Formatter ~a produced more than ~d characters"
             (file-namestring (first command))
             *formatting-output-limit*))
    stdout))

(defun formatting-spec-output (spec buffer input)
  (cond
    ((formatter-spec-function spec)
     (funcall (formatter-spec-function spec) input buffer))
    (t
     (alexandria:when-let
         ((command (funcall (formatter-spec-command-builder spec) buffer)))
       (formatting-run-command buffer command input)))))

;;; --- RCS diff and stable point mapping -----------------------------------

(defstruct format-rcs-command
  kind
  start
  lines
  text)

(defstruct format-edit
  start
  end
  replacement
  old-text)

(defun formatting-read-addition (stream count)
  (with-output-to-string (out)
    (dotimes (index count)
      (multiple-value-bind (line missing-newline-p)
          (read-line stream nil nil)
        (unless line
          (error "Malformed RCS patch: truncated addition"))
        (write-string line out)
        (unless missing-newline-p
          (write-char #\Newline out))
        (when (and missing-newline-p (< index (1- count)))
          (error "Malformed RCS patch: truncated addition"))))))

(defun formatting-parse-rcs-patch (patch)
  (with-input-from-string (stream patch)
    (loop :for line = (read-line stream nil nil)
          :while line
          :collect
          (cl-ppcre:register-groups-bind (kind start lines)
              ("^([ad])(\\d+) (\\d+)$" line)
            (unless kind
              (error "Malformed RCS patch command: ~s" line))
            (let ((count (parse-integer lines)))
              (make-format-rcs-command
               :kind (if (string= kind "a") :add :delete)
               :start (parse-integer start)
               :lines count
               :text (when (string= kind "a")
                       (formatting-read-addition stream count))))))))

(defun formatting-rcs-patch (old new)
  (alexandria:if-let ((diff (formatting-executable "diff")))
    (uiop:with-temporary-file
        (:pathname old-path :stream old-stream
         :direction :output :element-type 'character)
      (write-string old old-stream)
      (finish-output old-stream)
      (close old-stream)
      (uiop:with-temporary-file
          (:pathname new-path :stream new-stream
           :direction :output :element-type 'character)
        (write-string new new-stream)
        (finish-output new-stream)
        (close new-stream)
        (multiple-value-bind (stdout stderr status)
            (uiop:run-program
             (list diff "--rcs"
                   (formatting-native-name old-path)
                   (formatting-native-name new-path))
             :output :string
             :error-output :string
             :ignore-error-status t)
          (case status
            (0 nil)
            (1 (formatting-parse-rcs-patch stdout))
            (otherwise
             (error "diff failed with status ~d~@[ — ~a~]"
                    status
                    (let ((summary (formatting-error-summary stderr)))
                      (unless (zerop (length summary)) summary))))))))
    (error "diff is unavailable; stable formatting cannot be applied")))

(defun formatting-line-starts (string)
  (let ((starts (list 0)))
    (loop :for index :from 0 :below (length string)
          :when (char= (char string index) #\Newline)
            :do (push (1+ index) starts))
    (nreverse starts)))

(defun formatting-line-offset (starts line fallback)
  (or (nth line starts) fallback))

(defun formatting-command-offsets (command starts old-length)
  (let ((line (format-rcs-command-start command))
        (count (format-rcs-command-lines command)))
    (ecase (format-rcs-command-kind command)
      (:add
       (let ((position (formatting-line-offset starts line old-length)))
         (values position position)))
      (:delete
       (let ((start (formatting-line-offset starts (1- line) old-length))
             (end (formatting-line-offset starts (+ (1- line) count)
                                          old-length)))
         (values start end))))))

(defun formatting-commands-to-edits (commands old)
  (let ((starts (formatting-line-starts old))
        (old-length (length old))
        (edits nil))
    (loop :while commands
          :for command = (pop commands)
          :do
          (multiple-value-bind (start end)
              (formatting-command-offsets command starts old-length)
            (if (and (eq (format-rcs-command-kind command) :delete)
                     commands
                     (eq (format-rcs-command-kind (first commands)) :add))
                (multiple-value-bind (add-start add-end)
                    (formatting-command-offsets (first commands)
                                                starts old-length)
                  (declare (ignore add-end))
                  (if (= add-start end)
                      (let ((addition (pop commands)))
                        (push (make-format-edit
                               :start start
                               :end end
                               :replacement (format-rcs-command-text addition)
                               :old-text (subseq old start end))
                              edits))
                      (push (make-format-edit
                             :start start :end end :replacement ""
                             :old-text (subseq old start end))
                            edits)))
                (push (make-format-edit
                       :start start
                       :end end
                       :replacement (or (format-rcs-command-text command) "")
                       :old-text (subseq old start end))
                      edits))))
    (sort edits #'< :key #'format-edit-start)))

(defun formatting-edit-distance-table (old new)
  (let* ((old-length (length old))
         (new-length (length new))
         (table (make-array (list (1+ old-length) (1+ new-length))
                            :element-type 'fixnum)))
    (dotimes (old-index (1+ old-length))
      (setf (aref table old-index 0) old-index))
    (dotimes (new-index (1+ new-length))
      (setf (aref table 0 new-index) new-index))
    (loop :for old-index :from 1 :to old-length
          :do (loop :for new-index :from 1 :to new-length
                    :for substitution = (+ (aref table
                                                  (1- old-index)
                                                  (1- new-index))
                                              (if (char= (char old (1- old-index))
                                                         (char new (1- new-index)))
                                                  0 1))
                    :do (setf (aref table old-index new-index)
                              (min (1+ (aref table old-index (1- new-index)))
                                   (1+ (aref table (1- old-index) new-index))
                                   substitution))))
    table))

(defun formatting-align-offset (old new old-offset)
  (if (> (max (length old) (length new)) *formatting-alignment-limit*)
      (min old-offset (length new))
      (let* ((table (formatting-edit-distance-table old new))
             (old-index (length old))
             (new-index (length new))
             (new-offset old-offset))
        (loop :until (and (zerop old-index) (zerop new-index))
              :for insertion = (if (plusp new-index)
                                   (1+ (aref table old-index (1- new-index)))
                                   most-positive-fixnum)
              :for deletion = (if (plusp old-index)
                                  (1+ (aref table (1- old-index) new-index))
                                  most-positive-fixnum)
              :for substitution =
                (if (and (plusp old-index) (plusp new-index))
                    (+ (aref table (1- old-index) (1- new-index))
                       (if (char= (char old (1- old-index))
                                  (char new (1- new-index)))
                           0 1))
                    most-positive-fixnum)
              :for cost = (min insertion deletion substitution)
              :do (cond
                    ((= cost substitution)
                     (decf old-index)
                     (decf new-index))
                    ((= cost insertion)
                     (decf new-index)
                     (when (< old-index old-offset)
                       (incf new-offset)))
                    (t
                     (decf old-index)
                     (when (< old-index old-offset)
                       (decf new-offset)))))
        (max 0 (min new-offset (length new))))))

(defun formatting-map-offset (offset edits)
  (let ((delta 0))
    (dolist (edit edits (+ offset delta))
      (let* ((start (format-edit-start edit))
             (end (format-edit-end edit))
             (old-length (- end start))
             (new-length (length (format-edit-replacement edit))))
        (cond
          ((< offset start)
           (return (+ offset delta)))
          ((= start end)
           (when (>= offset start)
             (incf delta new-length)))
          ((>= offset end)
           (incf delta (- new-length old-length)))
          (t
           (let ((relative
                   (formatting-align-offset
                    (format-edit-old-text edit)
                    (format-edit-replacement edit)
                    (- offset start))))
             (return (+ start delta relative)))))))))

(defun formatting-buffer-points (buffer)
  (let* ((point (buffer-point buffer))
         (mark (cursor-mark point))
         (points (list point)))
    (when (mark-point mark)
      (push (mark-point mark) points))
    (dolist (window (window-list))
      (when (eq buffer (window-buffer window))
        (push (window-point window) points)
        (push (window-view-point window) points)))
    (remove-duplicates points :test #'eq)))

(defun formatting-apply-output (buffer old new)
  "Apply NEW to BUFFER as diff hunks while preserving registered points."
  (when (string= old new)
    (return-from formatting-apply-output nil))
  (when (buffer-read-only-p buffer)
    (error "The buffer is read-only"))
  (let* ((commands (formatting-rcs-patch old new))
         (edits (formatting-commands-to-edits commands old))
         (points (formatting-buffer-points buffer))
         (positions (mapcar (lambda (point)
                              (cons point
                                    (1- (position-at-point point))))
                            points))
         (mark (cursor-mark (buffer-point buffer)))
         (mark-active (mark-active-p mark)))
    (dolist (edit (reverse (copy-list edits)))
      (with-point ((start (buffer-start-point buffer))
                   (end (buffer-start-point buffer)))
        (move-to-position start (1+ (format-edit-start edit)))
        (move-to-position end (1+ (format-edit-end edit)))
        (delete-between-points start end)
        (insert-string start (format-edit-replacement edit))))
    (dolist (entry positions)
      (move-to-position
       (car entry)
       (1+ (max 0
                (min (length new)
                     (formatting-map-offset (cdr entry) edits))))))
    (setf (mark-active-p mark) mark-active)
    t))

;;; --- CLI/LSP dispatch and save lifecycle ---------------------------------

(defun formatting-lsp-workspace (buffer)
  (let ((workspace (buffer-value buffer 'lsp-workspace)))
    (when (and workspace
               (eq :ready (ignore-errors
                            (lem-lsp-mode::workspace-state workspace)))
               (ignore-errors
                 (lem-lsp-mode::workspace-response-current-p workspace buffer))
               (ignore-errors (lem-lsp-mode::provide-formatting-p workspace)))
      workspace)))

(defun formatting-run-lsp (buffer)
  (when (formatting-lsp-workspace buffer)
    (let ((jsonrpc:*default-timeout* *formatting-timeout*))
      (lem-lsp-mode::text-document/formatting buffer))
    t))

(defun formatting-run-spec (buffer spec)
  (let* ((old (points-to-string (buffer-start-point buffer)
                                (buffer-end-point buffer)))
         (new (formatting-spec-output spec buffer old)))
    (when new
      (values (formatting-apply-output buffer old new) t))))

(defun format-buffer-1 (buffer &key manual)
  "Format BUFFER, returning true when a formatter was available."
  (let ((spec (formatting-resolve-spec buffer)))
    (cond
      (spec
       (multiple-value-bind (changed available)
           (formatting-run-spec buffer spec)
         (cond
           (available
            (when manual
              (message "Formatted with ~a~:[~; (changed)~]"
                       (formatter-spec-id spec) changed))
            t)
           ((and manual (formatting-run-lsp buffer))
            (message "Formatted with LSP")
            t)
           (manual
            (editor-error "Formatter ~a is unavailable and no ready LSP formatter exists"
                          (formatter-spec-id spec)))
           (t nil))))
      ((and manual (formatting-run-lsp buffer))
       (message "Formatted with LSP")
       t)
      (manual
       (editor-error "No formatter is configured for this buffer"))
      (t nil))))

(define-command lem-yath-format-buffer () ()
  "Format the current buffer without saving it."
  (handler-case
      (format-buffer-1 (current-buffer) :manual t)
    (editor-abort (condition) (error condition))
    (error (condition)
      (message "Format failed: ~a" condition))))

(defun lem-yath-format-after-save (buffer)
  "Apheleia-style post-save formatting for one programming BUFFER."
  (when (and (programming-buffer-p buffer)
             (buffer-filename buffer)
             (not (buffer-value buffer 'lem-yath-format-after-save-active)))
    (setf (buffer-value buffer 'lem-yath-format-after-save-active) t)
    (unwind-protect
         (handler-case
             (when (format-buffer-1 buffer)
               (editorconfig-normalize-buffer buffer)
               (lem/buffer/file:write-to-file-without-write-hook
                buffer (buffer-filename buffer))
               (lem/buffer/file:update-changed-disk-date buffer))
           (error (condition)
             (message "Format-on-save failed: ~a" condition)))
      (setf (buffer-value buffer 'lem-yath-format-after-save-active) nil))))

(defun formatting-configure-buffer (buffer)
  (remove-hook (variable-value 'after-save-hook :buffer buffer)
               'lem-yath-format-after-save)
  (when (programming-buffer-p buffer)
    ;; Run before LSP's weight-zero didSave hook, so it observes the final
    ;; formatted buffer and receives any formatter-induced didChange events.
    (add-hook (variable-value 'after-save-hook :buffer buffer)
              'lem-yath-format-after-save 1000))
  (setf (buffer-value buffer 'lem-yath-formatting-mode)
        (buffer-major-mode buffer)))

(defun formatting-find-file-hook (buffer)
  (formatting-configure-buffer buffer))

(defun formatting-before-save-hook (buffer)
  ;; Lem's core process-file hook reactivates the detected major mode on every
  ;; save, which clears buffer-local editor variables, including after-save-hook.
  ;; Reinstall our callback after that mode activation and after EditorConfig.
  (formatting-configure-buffer buffer))

(defun formatting-post-command-hook ()
  (let ((buffer (current-buffer)))
    (unless (eq (buffer-value buffer 'lem-yath-formatting-mode)
                (buffer-major-mode buffer))
      (formatting-configure-buffer buffer))))

;;; --- built-in mappings ----------------------------------------------------

(clear-builtin-format-backends)

;; More-derived modes use lower priorities than their parent-family mapping.
(register-builtin-format-backend
 'python '("LEM-PYTHON-MODE" . "PYTHON-MODE")
 :command-builder #'formatting-black-command :priority 10)
(register-builtin-format-backend
 'rust '("LEM-RUST-MODE" . "RUST-MODE")
 :command-builder #'formatting-rustfmt-command :priority 10)
(register-builtin-format-backend
 'go '("LEM-GO-MODE" . "GO-MODE")
 :command-builder #'formatting-gofmt-command :priority 10)
(register-builtin-format-backend
 'nix '("LEM-NIX-MODE" . "NIX-MODE")
 :command-builder #'formatting-nixfmt-command :priority 10)
(register-builtin-format-backend
 'c '("LEM-C-MODE" . "C-MODE")
 :command-builder #'formatting-clang-command :priority 10)
(register-builtin-format-backend
 'typescript '("LEM-TYPESCRIPT-MODE" . "TYPESCRIPT-MODE")
 :command-builder #'formatting-prettier-command :priority 5)
(register-builtin-format-backend
 'json '("LEM-JSON-MODE" . "JSON-MODE")
 :command-builder #'formatting-prettier-command :priority 5)
(register-builtin-format-backend
 'javascript '("LEM-JS-MODE" . "JS-MODE")
 :command-builder #'formatting-prettier-command :priority 10)
(register-builtin-format-backend
 'java '("LEM-JAVA-MODE" . "JAVA-MODE")
 :command-builder #'formatting-google-java-command :priority 10)
(register-builtin-format-backend
 'clojure '("LEM-CLOJURE-MODE" . "CLOJURE-MODE")
 :command-builder #'formatting-cljfmt-command :priority 5)
(register-builtin-format-backend
 'terraform '("LEM-TERRAFORM-MODE" . "TERRAFORM-MODE")
 :command-builder #'formatting-tofu-command :priority 10)
(register-builtin-format-backend
 'zig '("LEM-ZIG-MODE" . "ZIG-MODE")
 :command-builder #'formatting-zig-command :priority 10)
(register-builtin-format-backend
 'lua '("LEM-LUA-MODE" . "LUA-MODE")
 :command-builder #'formatting-stylua-command :priority 10)
(register-builtin-format-backend
 'lisp '("LEM-LISP-MODE" . "LISP-MODE")
 :function #'formatting-lisp-text :priority 20)

;; Reloading replaces hook weights as well as definitions.
(remove-hook *find-file-hook* 'formatting-find-file-hook)
(add-hook *find-file-hook* 'formatting-find-file-hook 3000)
(remove-hook (variable-value 'before-save-hook :global t)
             'formatting-before-save-hook)
(add-hook (variable-value 'before-save-hook :global t)
          'formatting-before-save-hook -100)
(remove-hook *post-command-hook* 'formatting-post-command-hook)
(add-hook *post-command-hook* 'formatting-post-command-hook)

(dolist (buffer (buffer-list))
  (formatting-configure-buffer buffer))
