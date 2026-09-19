(defpackage :lem-daemon/recovery
  (:use :cl :lem)
  (:local-nicknames (:store :lem-daemon/recovery-store))
  (:export :enable :disable :checkpoint-now :check-checkpoint-limits
           :list-checkpoints :restore-checkpoint
           :discard-checkpoint :buffer-recovery-origin :*last-error*
           :recovery-list :recovery-restore :recovery-checkpoint :recovery-discard))
(in-package :lem-daemon/recovery)

(defconstant +maximum-batch-characters+ (* 16 1024 1024))

(defvar *directory* nil)
(defvar *timer* nil)
(defvar *writer* nil)
(defvar *writer-error* nil)
(defvar *writer-ticks* nil)
(defvar *written-ticks* (make-hash-table :test #'equal))
(defvar *last-error* nil "Last checkpoint failure, retained for inspection until a successful write.")

(defun recovery-directory () (or *directory* (store:default-directory)))

(defun buffer-recovery-origin (buffer)
  "Return the recovered record's ID, source filename and disk status as a plist."
  (copy-list (buffer-value buffer 'recovery-origin)))

(defun observe-file (buffer)
  ;; Run before mode/find-file hooks can alter the buffer. Unknown is conservative
  ;; for buffers already modified when recovery is enabled.
  (when (buffer-filename buffer)
    (setf (buffer-value buffer 'file-baseline)
          (store:file-baseline (buffer-filename buffer)))))

(defun checkpoint-buffer-p (buffer)
  (and (buffer-modified-p buffer)
       (not (buffer-temporary-p buffer))
       (not (buffer-read-only-p buffer))
       (not (buffer-value buffer 'recovery-exclude))))

(defun oversized-buffer-p (buffer)
  (> (1- (position-at-point (buffer-end-point buffer))) store:+maximum-text-length+))

(defun check-checkpoint-limits ()
  "Check eligible buffer sizes without copying text or writing records.
Call before exit hooks tear down services. Storage errors still require the
final checkpoint itself; this check only rejects known size-limit failures."
  (dolist (buffer (buffer-list))
    (when (and (checkpoint-buffer-p buffer) (oversized-buffer-p buffer))
      (editor-error "Recovery cannot checkpoint ~a (limit ~d characters). Save or reduce the buffer before exiting."
                    (buffer-name buffer) store:+maximum-text-length+)))
  t)

(defun snapshot-buffer (buffer)
  (when (checkpoint-buffer-p buffer)
    (when (oversized-buffer-p buffer)
      (error "Recovery skipped oversized buffer ~a (limit ~d characters)"
             (buffer-name buffer) store:+maximum-text-length+))
    (let* ((id (or (buffer-value buffer 'recovery-id)
                   (setf (buffer-value buffer 'recovery-id) (store:new-id))))
           (origin (buffer-recovery-origin buffer))
           (filename (or (buffer-filename buffer) (getf origin :filename)))
           (record (store:object
                    "version" 1 "id" id "name" (buffer-name buffer)
                    "filename" (when filename (uiop:native-namestring filename))
                    "baseline" (or (buffer-value buffer 'file-baseline) "unknown")
                    "created" (get-universal-time)
                    "point" (1- (position-at-point (buffer-point buffer)))
                    "text" (buffer-text buffer))))
      (values record (buffer-modified-tick buffer)))))

(defun collect-snapshots ()
  (let ((records nil) (ticks nil) (errors nil) (characters 0))
    (dolist (buffer (buffer-list))
      ;; Avoid copying unchanged documents. A busy batch defers further buffers
      ;; until the next idle pass; completed ticks let later buffers make progress.
      (unless (eql (buffer-modified-tick buffer)
                   (gethash (buffer-value buffer 'recovery-id) *written-ticks*))
        (handler-case
            (multiple-value-bind (record tick) (snapshot-buffer buffer)
              (when (and record
                         (<= (+ characters (length (store:field record "text")))
                             +maximum-batch-characters+))
                (incf characters (length (store:field record "text")))
                (push record records)
                (push (cons (store:field record "id") tick) ticks)))
          ;; One large/unsupported buffer must not prevent other documents recovering.
          (error (condition) (push (princ-to-string condition) errors)))))
    (values records ticks errors)))

(defun report-failure (failure)
  (let ((previous *last-error*))
    (setf *last-error* failure)
    (unless (equal previous failure)
      (handler-case (message "Recovery checkpoint failed: ~a" failure)
        (error (condition)
          (format *error-output* "~&Recovery checkpoint failed: ~a (display: ~a)~%"
                  failure condition))))))

(defun finish-writer (&key wait)
  (when (and *writer* (or wait (not (bt2:thread-alive-p *writer*))))
    (bt2:join-thread *writer*)
    (setf *writer* nil)
    (dolist (tick *writer-ticks*) (setf (gethash (car tick) *written-ticks*) (cdr tick)))
    (if *writer-error*
        (report-failure *writer-error*)
        (setf *last-error* nil))
    (setf *writer-ticks* nil)))

(defun checkpoint-periodically ()
  ;; Only buffer text is copied on the editor thread. File writes and fsyncs run
  ;; on a worker, and a slow worker cannot accumulate an unbounded snapshot queue.
  (finish-writer)
  (unless *writer*
    (multiple-value-bind (records ticks errors) (collect-snapshots)
      (when errors (report-failure errors))
      (when records
        (let ((directory (recovery-directory)))
          (setf *writer-error* errors *writer-ticks* nil)
          (setf *writer*
                (bt2:make-thread
                 (lambda ()
                   (dolist (record records)
                     (handler-case
                         (progn (store:write-record directory record)
                                (push (assoc (store:field record "id") ticks :test #'equal)
                                      *writer-ticks*))
                       (error (condition) (push (princ-to-string condition) *writer-error*)))))
                 :name "Lem durable buffer checkpoints")))))))

(defun checkpoint-now ()
  "Synchronously publish current modified text. Call on the editor thread.
Return record IDs; signal failures. No file visits, provider calls or prompts."
  (finish-writer :wait t)
  (let ((ids nil) (errors nil))
    ;; Capture/write one document at a time so an explicit full checkpoint does
    ;; not hold the text of the entire workspace in an additional memory batch.
    (dolist (buffer (buffer-list))
      (handler-case
          (multiple-value-bind (record tick) (snapshot-buffer buffer)
            (when record
              (store:write-record (recovery-directory) record)
              (let ((id (store:field record "id")))
                (setf (gethash id *written-ticks*) tick)
                (push id ids))))
        (error (condition) (push (princ-to-string condition) errors))))
    (when errors (report-failure errors) (error "Some buffers could not be checkpointed: ~{~a~^; ~}" errors))
    (setf *last-error* nil)
    (nreverse ids)))

(defun saved-buffer (buffer)
  ;; An old background write must finish before its now-saved record is removed.
  (handler-case
      (progn
        (finish-writer :wait t)
        (let ((id (buffer-value buffer 'recovery-id)))
          (when id
            (store:discard-record (recovery-directory) id)
            (remhash id *written-ticks*)))
        (setf (buffer-value buffer 'recovery-origin) nil)
        (observe-file buffer))
    (error (condition) (report-failure (princ-to-string condition)))))

(defun enable (&key directory (server-name "default") (interval 5))
  "Enable idle checkpoints for modified file and non-temporary scratch buffers.
No automatic restore: old checkpoints remain available for explicit inspection."
  (unless (and (realp interval) (> interval 0)) (error "Recovery interval must be positive"))
  (disable)
  (setf *directory* (or directory (store:default-directory server-name))
        *written-ticks* (make-hash-table :test #'equal)
        *last-error* nil)
  (store::ensure-private-directory *directory*)
  (dolist (buffer (buffer-list))
    (when (and (buffer-filename buffer) (not (buffer-modified-p buffer))) (observe-file buffer)))
  (add-hook *find-file-hook* 'observe-file 100000)
  (add-hook (variable-value 'after-save-hook :global t) 'saved-buffer)
  (setf *timer* (start-timer (make-idle-timer 'checkpoint-periodically
                                            :name "durable buffer recovery")
                            (* 1000 interval) :repeat t))
  *directory*)

(defun disable ()
  "Stop periodic checkpoints; retain existing recovery files."
  (when *timer* (stop-timer *timer*) (setf *timer* nil))
  (finish-writer :wait t)
  (remove-hook *find-file-hook* 'observe-file)
  (remove-hook (variable-value 'after-save-hook :global t) 'saved-buffer)
  t)

(defun disk-status (record)
  (let ((filename (store:field record "filename"))
        (baseline (store:field record "baseline")))
    (cond ((null filename) :scratch)
          ((equal baseline "unknown") :unknown)
          (t (let ((current (store:file-baseline filename)))
               (cond ((equal current "unknown") :unknown)
                     ((equal baseline current) :unchanged)
                     (t :conflict)))))))

(defun list-checkpoints (&optional (directory (recovery-directory)))
  "Return validated records and separate diagnostics; does not restore anything."
  (store:list-records directory))

(defun restore-checkpoint (id &key (directory (recovery-directory)))
  "Restore plain text into a new modified buffer with no visited filename.
Existing buffers/files and checkpoint stay intact. Return buffer and disk status."
  (let* ((record (store:read-record directory id))
         (status (disk-status record))
         (buffer (make-buffer (unique-buffer-name
                               (format nil "*Recovered ~a*" (store:field record "name"))))))
    (insert-string (buffer-point buffer) (store:field record "text"))
    (move-to-position (buffer-point buffer) (1+ (store:field record "point")))
    (setf (buffer-value buffer 'recovery-id) (store:new-id)
          (buffer-value buffer 'file-baseline) (store:field record "baseline")
          (buffer-value buffer 'recovery-origin)
          (list :id id :filename (store:field record "filename") :disk-status status))
    ;; Even an empty recovered document remains an unsaved recovery artifact.
    (when (zerop (length (store:field record "text")))
      (insert-character (buffer-point buffer) #\Space)
      (delete-character (buffer-start-point buffer)))
    (values buffer status)))

(defun discard-checkpoint (id)
  (finish-writer :wait t)
  (prog1 (store:discard-record (recovery-directory) id)
    (remhash id *written-ticks*)))

(define-command recovery-checkpoint () ()
  "Durably checkpoint modified buffers now, waiting for storage."
  (message "Wrote ~d recovery checkpoints" (length (checkpoint-now))))

(define-command recovery-list () ()
  "List checkpoint IDs, source paths and disk conflicts without restoring them."
  (multiple-value-bind (records failures) (list-checkpoints)
    (let ((buffer (make-buffer "*Recovery*")))
      (with-buffer-read-only buffer nil
        (erase-buffer buffer)
        (setf (buffer-value buffer 'recovery-exclude) t)
        (insert-string
         (buffer-point buffer)
         (with-output-to-string (out)
           (format out "Recovery checkpoints~%~%Use recovery-restore with an ID. Restored text opens in a separate unsaved buffer.~%~%")
           (dolist (record records)
             (format out "~a  ~a~%  ~a~%  ~a~%~%"
                     (store:field record "id") (disk-status record)
                     (store:field record "name") (or (store:field record "filename") "Scratch buffer")))
           (dolist (failure failures) (format out "Unreadable checkpoint ~a: ~a~%" (car failure) (cdr failure)))))
        (buffer-start (buffer-point buffer))
        (buffer-mark-saved buffer))
      (setf (buffer-read-only-p buffer) t)
      (pop-to-buffer buffer))))

(define-command recovery-restore (id) ((:string "Recovery ID: "))
  "Restore one checkpoint into a new unsaved buffer."
  (multiple-value-bind (buffer status) (restore-checkpoint id)
    (pop-to-buffer buffer)
    (message "Recovered separate buffer; original disk status: ~a" status)))

(define-command recovery-discard (id) ((:string "Discard recovery ID: "))
  "Delete one recovery record after explicit confirmation."
  (when (prompt-for-y-or-n-p "Permanently discard this checkpoint? ")
    (discard-checkpoint id)))
