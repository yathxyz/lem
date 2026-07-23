;;;; Buffer-local, bounded request context compatible with gptel's text context.
;;;; Directory-local declarations are parsed as data by project-outline.lisp;
;;;; this module never evaluates project Lisp.

(in-package :lem-yath)

(defparameter *llm-context-source-limit* 64)
(defparameter *llm-context-total-byte-limit* (* 1024 1024))
(defparameter *llm-context-directory-candidate-limit* 512)
(defparameter *llm-context-directory-depth-limit* 32)
(defparameter *llm-context-buffer-name* "*gptel-context*")
(defparameter *llm-context-buffer-key* 'lem-yath-llm-context-sources)

(defstruct llm-context-source
  kind
  label
  value)

(defun llm-context-sources (&optional (buffer (current-buffer)))
  "Return BUFFER's request-context sources in insertion order."
  (or (buffer-value buffer *llm-context-buffer-key*) '()))

(defun llm-context-count (&optional (buffer (current-buffer)))
  (length (llm-context-sources buffer)))

(defun llm-context-abbreviate-path (pathname)
  (let ((path (uiop:native-namestring pathname))
        (home (uiop:native-namestring (user-homedir-pathname))))
    (if (and (<= (length home) (length path))
             (string= home path :end2 (length home)))
        (concatenate 'string "~/" (subseq path (length home)))
        path)))

(defun llm-context-source-key (source)
  (case (llm-context-source-kind source)
    (:file (list :file (uiop:native-namestring
                        (llm-context-source-value source))))
    (:buffer (list :buffer (llm-context-source-value source)))
    (otherwise nil)))

(defun llm-context-add-source (buffer source)
  "Add SOURCE to BUFFER, returning true only when it was not already present."
  (let* ((sources (llm-context-sources buffer))
         (key (llm-context-source-key source)))
    (when (and key
               (find key sources :test #'equal
                     :key #'llm-context-source-key))
      (return-from llm-context-add-source nil))
    (when (>= (length sources) *llm-context-source-limit*)
      (editor-error "LLM context is limited to ~d sources"
                    *llm-context-source-limit*))
    (setf (buffer-value buffer *llm-context-buffer-key*)
          (append sources (list source)))
    t))

(defun llm-context-regular-file-p (pathname)
  #+sbcl
  (handler-case
      (= (logand (sb-posix:stat-mode
                  (sb-posix:stat (uiop:native-namestring pathname)))
                 sb-posix:s-ifmt)
         sb-posix:s-ifreg)
    (error () nil))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl nil)

(defun llm-context-symlink-p (pathname)
  #+sbcl
  (handler-case
      (= (logand (sb-posix:stat-mode
                  (sb-posix:lstat (uiop:native-namestring pathname)))
                 sb-posix:s-ifmt)
         sb-posix:s-iflnk)
    (error () nil))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl nil)

(defun llm-context-hidden-directory-p (pathname)
  (let* ((parts (pathname-directory pathname))
         (name (and parts (car (last parts)))))
    (and (stringp name)
         (plusp (length name))
         (char= (char name 0) #\.))))

(defun llm-context-directory-files (directory)
  "Return regular files below DIRECTORY deterministically, without dot dirs."
  (let ((files '()))
    (labels ((walk (current depth)
               (when (> depth *llm-context-directory-depth-limit*)
                 (editor-error "LLM context directory exceeds depth ~d"
                               *llm-context-directory-depth-limit*))
               (dolist (file (sort (copy-list (uiop:directory-files current))
                                   #'string< :key #'uiop:native-namestring))
                 (when (and (llm-context-regular-file-p file)
                            (not (llm-context-symlink-p file)))
                   (when (>= (length files)
                             *llm-context-directory-candidate-limit*)
                     (editor-error
                      "LLM context directory exceeds ~d candidate files"
                      *llm-context-directory-candidate-limit*))
                   (push (truename file) files)))
               (dolist (subdirectory
                         (sort (copy-list (uiop:subdirectories current))
                               #'string< :key #'uiop:native-namestring))
                 (unless (or (llm-context-hidden-directory-p subdirectory)
                             (llm-context-symlink-p subdirectory))
                   (walk subdirectory (1+ depth))))))
      (walk (truename directory) 0))
    (nreverse files)))

(defun llm-context-project-filter-files (directory files)
  "Exclude ignored FILES when DIRECTORY belongs to a Git project."
  (alexandria:if-let ((root (project-git-root directory)))
    (let ((allowed (make-hash-table :test #'equal)))
      (dolist (relative (git-project-files root))
        (alexandria:when-let
            ((resolved
               (ignore-errors
                 (truename (project-native-relative-path root relative)))))
          (setf (gethash (uiop:native-namestring resolved) allowed) t)))
      (remove-if-not
       (lambda (file)
         (gethash (uiop:native-namestring (truename file)) allowed))
       files))
    files))

(defun llm-context-read-file (pathname)
  "Read PATHNAME as bounded, stable UTF-8 text."
  (let* ((resolved (truename pathname))
         (root (uiop:pathname-directory-pathname resolved)))
    (unless (llm-context-regular-file-p resolved)
      (error "Not a regular file: ~a" pathname))
    (llm-tool-read-utf8-file resolved root)))

(defun llm-context-file-source (pathname)
  (let ((resolved (truename pathname)))
    (make-llm-context-source
     :kind :file
     :label (llm-context-abbreviate-path resolved)
     :value resolved)))

(defun llm-context-path-files (pathname)
  (let ((path (pathname pathname)))
    (cond
      ((uiop:directory-exists-p path)
       (when (llm-context-symlink-p path)
         (editor-error "Refusing a symlinked context directory: ~a" pathname))
       (llm-context-project-filter-files
        path (llm-context-directory-files path)))
      ((uiop:file-exists-p path)
       (list (truename path)))
      (t (editor-error "Context path does not exist: ~a" pathname)))))

(defun llm-context-attach-files (buffer files)
  "Atomically attach readable UTF-8 FILES to BUFFER.
Return added, duplicate, and skipped counts."
  (let* ((existing (llm-context-sources buffer))
         (existing-keys (remove nil (mapcar #'llm-context-source-key existing)))
         (seen (copy-list existing-keys))
         (new-sources '())
         (duplicates 0)
         (skipped 0))
    (dolist (file files)
      (let* ((source (llm-context-file-source file))
             (key (llm-context-source-key source)))
        (cond
          ((member key seen :test #'equal)
           (incf duplicates))
          ((handler-case
               (progn (llm-context-read-file file) t)
             (error () nil))
           (push key seen)
           (push source new-sources))
          (t (incf skipped)))))
    (setf new-sources (nreverse new-sources))
    (when (> (+ (length existing) (length new-sources))
             *llm-context-source-limit*)
      (editor-error "LLM context is limited to ~d sources"
                    *llm-context-source-limit*))
    (setf (buffer-value buffer *llm-context-buffer-key*)
          (append existing new-sources))
    (values (length new-sources) duplicates skipped)))

(defun llm-context-add-path (buffer pathname)
  "Attach PATHNAME to BUFFER.  Return added, duplicate, and skipped counts."
  (llm-context-attach-files buffer (llm-context-path-files pathname)))

(defun llm-context-buffer-text (buffer)
  (unless (and buffer (not (deleted-buffer-p buffer)))
    (error "An attached buffer was deleted"))
  (let ((start (buffer-start-point buffer))
        (end (buffer-end-point buffer)))
    (when (> (count-characters start end) *llm-context-total-byte-limit*)
      (error "Attached buffer exceeds the LLM context byte limit"))
    (points-to-string start end)))

(defun llm-context-source-text (source)
  (ecase (llm-context-source-kind source)
    (:file (llm-context-read-file (llm-context-source-value source)))
    (:buffer (llm-context-buffer-text (llm-context-source-value source)))
    (:region (llm-context-source-value source))))

(defun llm-context-source-language (source)
  (case (llm-context-source-kind source)
    (:file (or (pathname-type (llm-context-source-value source)) ""))
    (:buffer
     (let ((name (symbol-name
                  (buffer-major-mode (llm-context-source-value source)))))
       (string-downcase
        (if (alexandria:ends-with-subseq "-MODE" name)
            (subseq name 0 (- (length name) 5))
            name))))
    (otherwise "text")))

(defun llm-context-source-header (source)
  (format nil "In ~a `~a`:"
          (if (eq (llm-context-source-kind source) :file) "file" "buffer")
          (llm-context-source-label source)))

(defun llm-context-render (&optional (buffer (current-buffer)))
  "Render BUFFER's live text context, or NIL when it has none."
  (let ((sources (llm-context-sources buffer)))
    (when sources
      (let ((byte-count 0))
        (with-output-to-string (stream)
          (format stream "Request context:~2%")
          (loop :for tail :on sources
                :for source := (car tail)
                :for text := (llm-context-source-text source)
                :for bytes := (length (babel:string-to-octets
                                       text :encoding :utf-8))
                :do (incf byte-count bytes)
                    (when (> byte-count *llm-context-total-byte-limit*)
                      (error "LLM context exceeds the ~d-byte request limit"
                             *llm-context-total-byte-limit*))
                    (format stream "~a~2%```~a~%~a~%```"
                            (llm-context-source-header source)
                            (llm-context-source-language source)
                            text)
                    (when (cdr tail)
                      (format stream "~2%"))))))))

(defun llm-context-wrap-prompt (buffer prompt)
  "Append BUFFER's request context to PROMPT like gptel's default user context."
  (alexandria:if-let ((context (llm-context-render buffer)))
    (format nil "~a~2%~a" prompt context)
    prompt))

(defun llm-context-region-bounds (buffer)
  (unless (buffer-mark-p buffer)
    (editor-error "Select a region before adding region context"))
  (let ((global-mode (current-global-mode)))
    (values (region-beginning-using-global-mode global-mode buffer)
            (region-end-using-global-mode global-mode buffer))))

(define-command lem-yath-llm-context-add-region () ()
  "Add a snapshot of the active region to this buffer's LLM context."
  (let ((buffer (current-buffer)))
    (multiple-value-bind (start end) (llm-context-region-bounds buffer)
      (let ((text (points-to-string start end)))
        (when (> (length (babel:string-to-octets text :encoding :utf-8))
                 *llm-context-total-byte-limit*)
          (editor-error "Region exceeds the LLM context byte limit"))
        (llm-context-add-source
         buffer
         (make-llm-context-source
          :kind :region
          :label (format nil "~a (lines ~d-~d)"
                         (buffer-name buffer)
                         (line-number-at-point start)
                         (line-number-at-point end))
          :value text))
        (message "Region added to LLM context (~d source~:p)"
                 (llm-context-count buffer))))))

(define-command lem-yath-llm-context-add-buffer () ()
  "Prompt for a live buffer and add its full text as request context."
  (let* ((owner (current-buffer))
         (choice (prompt-for-buffer "Context buffer: " :existing t))
         (buffer (and choice (get-buffer choice))))
    (unless buffer (editor-error "No such buffer: ~a" choice))
    (llm-context-buffer-text buffer)
    (llm-context-add-source
     owner
     (make-llm-context-source
      :kind :buffer :label (buffer-name buffer) :value buffer))
    (message "Buffer added to LLM context (~d source~:p)"
             (llm-context-count owner))))

(define-command lem-yath-llm-context-add-file () ()
  "Prompt for a text file or directory and add live file context."
  (let* ((buffer (current-buffer))
         (choice (prompt-for-file
                  "Context file or directory: "
                  :directory (or (buffer-directory buffer) (uiop:getcwd))
                  :default nil :existing t)))
    (when choice
      (multiple-value-bind (added duplicates skipped)
          (llm-context-add-path buffer choice)
        (message "LLM context: ~d added, ~d already present, ~d non-text skipped"
                 added duplicates skipped)))))

(define-command lem-yath-llm-context-clear () ()
  "Remove every request-context source from the current buffer."
  (let ((count (llm-context-count)))
    (setf (buffer-value (current-buffer) *llm-context-buffer-key*) nil)
    (message "Removed ~d LLM context source~:p" count)))

;;; --- exact configured Emacs helper -------------------------------------

(defun llm-context-named-form-p (form name length)
  (and (listp form)
       (= (length form) length)
       (project-outline-symbol-name-p (first form) name)))

(defun llm-context-expand-config-path-p (form expected)
  (and (llm-context-named-form-p form "EXPAND-FILE-NAME" 3)
       (stringp (second form))
       (string= (second form) expected)
       (project-outline-symbol-name-p (third form) "USER-EMACS-DIRECTORY")))

(defun llm-context-emacs-helper-option-p (option)
  "Whether OPTION is the exact configured gptel context helper declaration."
  (and (consp option)
       (project-outline-symbol-name-p (car option) "EVAL")
       (let ((form (cdr option)))
         (and (llm-context-named-form-p form "DEFUN" 5)
              (project-outline-symbol-name-p
               (second form) "VILE-CONFIG/ADD-ELISP-TO-GPTEL-CONTEXT")
              (null (third form))
              (llm-context-named-form-p (fourth form) "INTERACTIVE" 1)
              (let ((mapcar-form (fifth form)))
                (and (llm-context-named-form-p mapcar-form "MAPCAR" 3)
                     (let ((function-form (second mapcar-form)))
                       (and (llm-context-named-form-p
                             function-form "FUNCTION" 2)
                            (project-outline-symbol-name-p
                             (second function-form) "GPTEL-ADD-FILE")))
                     (let ((paths (third mapcar-form)))
                       (and (llm-context-named-form-p paths "LIST" 4)
                            (llm-context-expand-config-path-p
                             (second paths) "./early-init.el")
                            (llm-context-expand-config-path-p
                             (third paths) "./init.el")
                            (llm-context-expand-config-path-p
                             (fourth paths) "./lisp/")))))))))

(defun llm-context-emacs-helper-declared-p (form)
  (handler-case
      (let ((mode-entry
              (find-if
               (lambda (entry)
                 (and (consp entry)
                      (project-outline-symbol-name-p
                       (car entry) "EMACS-LISP-MODE")))
               form)))
        (and mode-entry
             (some #'llm-context-emacs-helper-option-p (cdr mode-entry))))
    (error () nil)))

(defun llm-context-emacs-config-root (&optional (buffer (current-buffer)))
  "Return BUFFER's audited Emacs config root, if its helper is declared."
  (alexandria:when-let* ((filename (buffer-filename buffer))
                         (directory (uiop:pathname-directory-pathname filename))
                         (root (find-up directory ".dir-locals.el"))
                         (file (merge-pathnames ".dir-locals.el" root))
                         (form (project-outline-read-dir-locals file)))
    (and (llm-context-emacs-helper-declared-p form) root)))

(define-command lem-yath-add-elisp-to-llm-context () ()
  "Attach the exact Emacs config files declared by the audited local helper."
  (let* ((buffer (current-buffer))
         (root (llm-context-emacs-config-root buffer)))
    (unless root
      (editor-error
       "Current tree does not declare the audited Emacs gptel context helper"))
    (let ((files
            (mapcan
             (lambda (relative)
               (llm-context-path-files (merge-pathnames relative root)))
             '("early-init.el" "init.el" "lisp/"))))
      (multiple-value-bind (added duplicates skipped)
          (llm-context-attach-files buffer files)
        (message
         "Emacs config context: ~d added, ~d already present, ~d non-text skipped"
         added duplicates skipped)))))

(define-command vile-config/add-elisp-to-gptel-context () ()
  "Run the configured Emacs helper through Lem's safe context implementation."
  (lem-yath-add-elisp-to-llm-context))

(define-command lem-yath-llm-context-inspect () ()
  "Open a read-only rendering of the current buffer's request context."
  (let* ((source (current-buffer))
         (rendered
           (handler-case (llm-context-render source)
             (error (condition)
               (editor-error "Could not inspect LLM context: ~a" condition))))
         (buffer (make-buffer *llm-context-buffer-name* :enable-undo-p nil)))
    (setf (buffer-read-only-p buffer) nil)
    (erase-buffer buffer)
    (insert-string (buffer-start-point buffer)
                   (or rendered "There are no active LLM contexts.\n"))
    (handler-case
        (change-buffer-mode buffer 'lem-markdown-mode:markdown-mode)
      (error () nil))
    (clear-buffer-edit-history buffer)
    (buffer-unmark buffer)
    (setf (buffer-read-only-p buffer) t)
    (buffer-start (buffer-point buffer))
    (switch-to-buffer buffer)))
