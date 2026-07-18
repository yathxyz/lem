;;;; Transparent editing for existing local SOPS-managed text files.

(in-package :lem-yath)

(defparameter *sops-prefilter-extensions*
  '("yaml" "yml" "json" "env" "ini" "txt"))

(defparameter *sops-timeout-seconds* 300)
(defparameter *sops-output-limit* (* 64 1024 1024))
(defvar *sops-program*
  (or (uiop:getenv "LEM_YATH_SOPS_PROGRAM") :unknown))
(defvar *sops-program-argument*
  (uiop:getenv "LEM_YATH_SOPS_PROGRAM_ARGUMENT"))
(defvar *sops-timeout-program* :unknown)

(defun sops-resolve-program (name cache-symbol)
  (let ((cached (symbol-value cache-symbol)))
    (when (or (eq cached :unknown)
              (null cached)
              (not (uiop:file-exists-p cached)))
      (setf cached (executable-find name)
            (symbol-value cache-symbol) cached))
    cached))

(defun sops-command (arguments)
  (let ((sops (sops-resolve-program "sops" '*sops-program*))
        (timeout (sops-resolve-program "timeout" '*sops-timeout-program*)))
    (unless sops
      (error "the sops executable is unavailable"))
    (unless timeout
      (error "GNU timeout is unavailable; refusing an unbounded sops command"))
    (append (list (namestring timeout)
                  "--signal=TERM"
                  "--kill-after=5s"
                  (format nil "~ds" *sops-timeout-seconds*)
                  (namestring sops))
            (when *sops-program-argument*
              (list *sops-program-argument*))
            arguments)))

(defun sops-run (arguments &key input directory)
  "Run one bounded SOPS argv vector, returning stdout and status.
Stderr is deliberately retained only long enough to drain the child; it may
contain secret material and is never included in a Lem diagnostic."
  (multiple-value-bind (stdout stderr status)
      (if input
          (with-input-from-string (stream input)
            (uiop:run-program (sops-command arguments)
                              :directory directory
                              :input stream
                              :output :string
                              :error-output :string
                              :ignore-error-status t))
          (uiop:run-program (sops-command arguments)
                            :directory directory
                            :output :string
                            :error-output :string
                            :ignore-error-status t))
    (declare (ignore stderr))
    (when (> (length stdout) *sops-output-limit*)
      (error "sops output exceeded the configured limit"))
    (values stdout status)))

(defun sops-prefilter-p (filename)
  (and filename
       (member (string-downcase (or (pathname-type filename) ""))
               *sops-prefilter-extensions*
               :test #'string=)))

(defun sops-filestatus (filename)
  "Return encrypted-p and checked-p for FILENAME."
  (handler-case
      (multiple-value-bind (output status)
          (sops-run (list "filestatus" filename)
                    :directory (directory-namestring filename))
        (if (zerop status)
            (handler-case
                (let ((object (yason:parse output)))
                  (if (hash-table-p object)
                      (multiple-value-bind (encrypted present-p)
                          (gethash "encrypted" object)
                        (if present-p
                            (values (eq encrypted t) t)
                            (values nil nil)))
                      (values nil nil)))
              (error () (values nil nil)))
            (values nil nil)))
    (error () (values nil nil))))

(defun sops-buffer-text (buffer)
  (let ((text (points-to-string (buffer-start-point buffer)
                                (buffer-end-point buffer))))
    (when (> (length text) *sops-output-limit*)
      (editor-error "SOPS buffer exceeds the configured size limit"))
    text))

(defun sops-likely-encrypted-p (buffer)
  (let ((text (sops-buffer-text buffer)))
    (or (search "\"sops\"" text :test #'char-equal)
        (search "sops:" text :test #'char-equal))))

(defun sops-replace-buffer-text (buffer text)
  (let ((undo-enabled-p (buffer-enable-undo-p buffer)))
    (buffer-disable-undo buffer)
    (unwind-protect
         (let ((lem/buffer/internal:*inhibit-modification-hooks* t))
           (with-buffer-read-only buffer nil
             (erase-buffer buffer)
             (insert-string (buffer-start-point buffer) text)))
      (when undo-enabled-p
        (buffer-enable-undo buffer))))
  (buffer-start (buffer-point buffer))
  (buffer-unmark buffer))

(defun sops-decrypt (buffer)
  (let ((filename (buffer-filename buffer)))
    (handler-case
        (multiple-value-bind (plaintext status)
            (sops-run (list "decrypt" filename)
                      :directory (buffer-directory buffer))
          (if (zerop status)
              (progn
                (sops-replace-buffer-text buffer plaintext)
                (setf (buffer-read-only-p buffer) nil
                      (buffer-value buffer 'lem-yath-sops-last-error) nil)
                (lem/buffer/file:update-changed-disk-date buffer)
                t)
              (progn
                (setf (buffer-value buffer 'lem-yath-sops-last-error)
                      (list :exit status))
                nil)))
      (error (condition)
        (setf (buffer-value buffer 'lem-yath-sops-last-error)
              (list :condition (type-of condition)))
        nil))))

(defun sops-write-ciphertext (filename ciphertext)
  (with-open-file (stream filename
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create
                          :external-format :utf-8)
    (write-string ciphertext stream)))

(defun sops-write-buffer (buffer filename)
  "Encrypt BUFFER and write only ciphertext to FILENAME."
  (let ((plaintext (sops-buffer-text buffer)))
    (handler-case
        (multiple-value-bind (ciphertext status)
            (sops-run (list "encrypt" "--filename-override" filename)
                      :input plaintext
                      :directory (buffer-directory buffer))
          (unless (and (zerop status) (plusp (length ciphertext)))
            (editor-error "SOPS encryption failed; file was not written"))
          (sops-write-ciphertext filename ciphertext))
      (editor-error (condition) (error condition))
      (error ()
        (editor-error "SOPS encryption failed; file was not written")))))

(defun sops-activate-buffer (buffer)
  (setf (buffer-value buffer 'lem-yath-sops-active) t
        (buffer-value buffer 'lem/buffer/file::write-file-function)
        #'sops-write-buffer
        (lem-core/commands/file:revert-buffer-function buffer)
        #'sops-revert-buffer))

(defun sops-protect-failed-buffer (buffer)
  (setf (buffer-read-only-p buffer) t
        (buffer-value buffer 'lem-yath-sops-decrypt-failed) t
        (lem-core/commands/file:revert-buffer-function buffer)
        #'sops-revert-buffer)
  (message "SOPS decryption failed; buffer is read-only (revert to retry)"))

(defun sops-revert-buffer (buffer)
  (if (sops-decrypt buffer)
      (progn
        (setf (buffer-value buffer 'lem-yath-sops-decrypt-failed) nil)
        (sops-activate-buffer buffer)
        (lem/buffer/file:update-changed-disk-date buffer)
        ;; Custom reverts must publish the same synchronization lifecycle as
        ;; core file reloads.  Persistence can then advance its ciphertext
        ;; baseline before a queued inotify event arrives, avoiding a redundant
        ;; second decrypt and message replacement.
        (run-hooks lem-core/commands/file:*after-sync-buffer-hook* buffer)
        t)
      (progn
        (sops-protect-failed-buffer buffer)
        nil)))

(defun sops-find-file-hook (buffer)
  (let ((filename (buffer-filename buffer)))
    (when (and (sops-prefilter-p filename)
               (probe-file filename))
      (multiple-value-bind (encrypted-p checked-p)
          (sops-filestatus filename)
        (cond
          (encrypted-p
           (if (sops-decrypt buffer)
               (sops-activate-buffer buffer)
               (sops-protect-failed-buffer buffer)))
          ((and (not checked-p) (sops-likely-encrypted-p buffer))
           (sops-protect-failed-buffer buffer)))))))

(defun sops-buffer-active-p (&optional (buffer (current-buffer)))
  (not (null (buffer-value buffer 'lem-yath-sops-active))))

(remove-hook *find-file-hook* 'sops-find-file-hook)
(add-hook *find-file-hook* 'sops-find-file-hook 15000)

(dolist (buffer (buffer-list))
  (when (and (buffer-filename buffer)
             (not (sops-buffer-active-p buffer)))
    (sops-find-file-hook buffer)))
