(defpackage :lem/checkpoint
  (:use :cl :lem)
  (:documentation
   "DS-3 mechanism: crash-recovery checkpoints. While CHECKPOINT-MODE is on, the
content of every modified file-backed buffer is periodically written to a private
checkpoint file under $XDG_DATA_HOME/lem/autosave/ -- never to the real file and
never clearing the buffer's modified flag. A successful manual save deletes the
buffer's checkpoint; a crash leaves it behind. On FIND-FILE, if a checkpoint newer
than the file survives, the user is offered a chance to recover the edits. The
mechanism is off by default; the fork's daily-driver-defaults layer enables it.
See SPEC.md, DS-3.")
  (:export :checkpoint-mode
           :toggle-checkpoint-mode
           :recover-this-file
           :*checkpoint-directory*
           :checkpoint-directory
           :checkpoint-filename
           :checkpoint-buffer
           :checkpoint-modified-buffers
           :delete-checkpoint
           :maybe-offer-recovery
           :recover-buffer-from-checkpoint)
  #+sbcl
  (:lock t))
(in-package :lem/checkpoint)

;;; Editor variables: how often to checkpoint.

(define-editor-variable checkpoint-interval-seconds 5
  "Seconds between periodic checkpoints of modified buffers.")

(define-editor-variable checkpoint-key-threshold 256
  "Keystrokes in a buffer between checkpoints of that buffer.")

(defvar *checkpoint-directory* nil
  "When non-nil, the directory checkpoints are written to instead of the default
$XDG_DATA_HOME/lem/autosave/. Intended for tests.")

(defvar *timer* nil
  "The single global periodic checkpoint timer, or NIL when disabled.")

(defvar *reported-error-p* nil
  "Guards against spamming the message area when a checkpoint write keeps failing:
the failure is reported once and then silenced until a write succeeds again.")

;;; Checkpoint minor mode.

(define-minor-mode checkpoint-mode
    (:name "CP"
     :global t
     :enable-hook 'enable
     :disable-hook 'disable))

;;; Locating checkpoint files.

(defun checkpoint-directory ()
  "Return the directory (a pathname) checkpoint files live in."
  (or *checkpoint-directory*
      (uiop:xdg-data-home "lem/autosave/")))

(defun encode-path (path)
  "Injectively encode PATH into a single filesystem-safe name component.
Every #\\! in the output starts a two-character escape — \"!s\" for #\\/ and
\"!!\" for a literal #\\! — forming a prefix code, so distinct paths never
encode to the same string and their checkpoints never collide."
  (with-output-to-string (out)
    (loop :for c :across path
          :do (case c
                ((#\/) (write-string "!s" out))
                ((#\!) (write-string "!!" out))
                (t (write-char c out))))))

(defun checkpoint-filename (filename)
  "Return the checkpoint pathname for the file at FILENAME. The name encodes the
file's absolute path so it is stable across editor restarts (crash recovery) and
ends in #\\# so checkpoints are easy to recognize. Overlong encodings fall back to
a hash plus a readable tail to stay within filesystem name limits."
  (let* ((true (namestring (or (ignore-errors (truename filename)) filename)))
         (encoded (encode-path true)))
    (merge-pathnames
     (if (< (length encoded) 200)
         (format nil "~A#" encoded)
         (format nil "~(~36R~)-~A#" (sxhash true) (file-namestring true)))
     (checkpoint-directory))))

;;; Writing checkpoints.

(defun write-string-to-file-atomically (path string)
  "Write STRING to PATH, creating parent directories, via a temp file in the same
directory followed by a rename, so a crash mid-write never leaves a torn
checkpoint in place of a good one."
  (ensure-directories-exist path)
  (let ((temp (format nil "~A.~36R.tmp" (namestring path) (random (expt 36 12)))))
    (unwind-protect
         (progn
           (with-open-file (out temp
                                :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create
                                :external-format :utf-8)
             (write-string string out)
             (finish-output out))
           #+sbcl (sb-posix:rename temp (namestring path))
           #-sbcl (rename-file temp path))
      (uiop:delete-file-if-exists temp))))

(defun checkpointable-buffer-p (buffer)
  "Return T when BUFFER is a modified, writable, file-backed buffer worth
checkpointing."
  (and (buffer-filename buffer)
       (buffer-modified-p buffer)
       (not (buffer-read-only-p buffer))))

(defun checkpoint-buffer (buffer)
  "Write BUFFER's current content to its checkpoint file, without touching the
real file and without clearing BUFFER's modified flag. A failing write is reported
at most once and never breaks editing. Does nothing for buffers that are not
checkpointable."
  (when (checkpointable-buffer-p buffer)
    (handler-case
        (progn
          (write-string-to-file-atomically
           (checkpoint-filename (buffer-filename buffer))
           (points-to-string (buffer-start-point buffer)
                             (buffer-end-point buffer)))
          (setf *reported-error-p* nil))
      (error (condition)
        (unless *reported-error-p*
          (setf *reported-error-p* t)
          (message "Checkpoint write failed: ~A" condition))))))

(defun checkpoint-modified-buffers ()
  "Checkpoint every modified file-backed buffer. This is the periodic timer's
target."
  (dolist (buffer (buffer-list))
    (checkpoint-buffer buffer)))

(defun delete-checkpoint (buffer)
  "Delete BUFFER's checkpoint file if it exists. Called from the after-save hook
so a successful manual save clears the checkpoint, while checkpoints of buffers
that were never saved survive a crash."
  (let ((filename (buffer-filename buffer)))
    (when filename
      (ignore-errors
       (uiop:delete-file-if-exists (checkpoint-filename filename))))))

;;; Keystroke- and timer-driven triggers.

(defun count-keys (key)
  "Input-hook function: checkpoint the current buffer once its keystroke count
since the last checkpoint reaches CHECKPOINT-KEY-THRESHOLD."
  (declare (ignore key))
  (let* ((buffer (current-buffer))
         (count (incf (buffer-value buffer 'key-count 0)))
         (threshold (variable-value 'checkpoint-key-threshold)))
    (when (and (numberp threshold) (<= threshold count))
      (setf (buffer-value buffer 'key-count) 0)
      (checkpoint-buffer buffer))))

;;; Recovery.

(defun checkpoint-newer-than-file-p (filename)
  "Return T when a checkpoint for FILENAME exists and is newer than the on-disk
file. A checkpoint older than the file (the file was saved elsewhere since) is not
offered."
  (let ((checkpoint (checkpoint-filename filename)))
    (and (probe-file checkpoint)
         (probe-file filename)
         (>= (file-write-date checkpoint)
             (file-write-date filename)))))

(defun read-checkpoint-string (filename)
  "Return the content of FILENAME's checkpoint file as a string."
  (with-open-file (in (checkpoint-filename filename)
                      :direction :input
                      :external-format :utf-8)
    (let ((string (make-string (file-length in))))
      (subseq string 0 (read-sequence string in)))))

(defun recover-buffer-from-checkpoint (buffer)
  "Replace BUFFER's content with its checkpoint's content. The real file is left
untouched; BUFFER ends up modified so the recovered edits are only persisted when
the user chooses to save."
  (let ((content (read-checkpoint-string (buffer-filename buffer))))
    (erase-buffer buffer)
    (insert-string (buffer-start-point buffer) content)
    buffer))

(defun prompt-recovery-choice (filename)
  "Prompt for what to do with a surviving checkpoint of FILENAME. Returns one of
:RECOVER, :IGNORE or :DELETE."
  (loop :for c := (prompt-for-character
                   (format nil "Newer checkpoint for ~A: (r)ecover / (i)gnore / (d)elete? "
                           (file-namestring filename)))
        :do (case c
              ((#\r #\R) (return :recover))
              ((#\i #\I) (return :ignore))
              ((#\d #\D) (return :delete)))))

(defun maybe-offer-recovery (buffer)
  "FIND-FILE-HOOK function: when BUFFER's file has a newer checkpoint, prompt the
user to recover, ignore or delete it."
  (let ((filename (buffer-filename buffer)))
    (when (and filename (checkpoint-newer-than-file-p filename))
      (case (prompt-recovery-choice filename)
        (:recover (recover-buffer-from-checkpoint buffer))
        (:delete (delete-checkpoint buffer))
        (:ignore nil)))))

(defun delete-checkpoint-on-save (buffer)
  "AFTER-SAVE-HOOK function: remove the just-saved buffer's checkpoint."
  (delete-checkpoint buffer))

;;; Commands.

(define-command recover-this-file () ()
  "Restore the current buffer's content from its checkpoint file, if one exists.
The real file is not touched; the buffer is left modified so the recovery is only
persisted on save."
  (let* ((buffer (current-buffer))
         (filename (buffer-filename buffer)))
    (unless filename
      (editor-error "This buffer is not visiting a file."))
    (unless (probe-file (checkpoint-filename filename))
      (editor-error "No checkpoint exists for ~A." (file-namestring filename)))
    (recover-buffer-from-checkpoint buffer)))

(define-command toggle-checkpoint-mode () ()
  "Toggle the global checkpoint (crash-recovery auto-save) minor mode."
  (checkpoint-mode))

;;; Enable / disable.

(defun enable ()
  (unless *timer*
    (let ((interval (variable-value 'checkpoint-interval-seconds)))
      (when (and (numberp interval) (plusp interval))
        (setf *timer*
              (start-timer
               (make-idle-timer 'checkpoint-modified-buffers
                                :handle-function (lambda (condition)
                                                   (pop-up-backtrace condition)
                                                   (disable))
                                :name "checkpoint")
               (* interval 1000)
               :repeat t)))))
  (add-hook *input-hook* 'count-keys)
  (add-hook *find-file-hook* 'maybe-offer-recovery)
  (add-hook (variable-value 'after-save-hook :global t) 'delete-checkpoint-on-save))

(defun disable ()
  (when *timer*
    (stop-timer *timer*)
    (setf *timer* nil))
  (remove-hook *input-hook* 'count-keys)
  (remove-hook *find-file-hook* 'maybe-offer-recovery)
  (remove-hook (variable-value 'after-save-hook :global t) 'delete-checkpoint-on-save))
