;;;; Remote source-buffer undo for the native Org agenda.

(in-package :lem-yath)

(defstruct agenda-undo-context
  buffer
  tick)

(defstruct agenda-undo-record
  label
  restore-key
  contexts)

(defvar *agenda-undo-current-transaction* nil)
(defvar *agenda-undo-post-functions* nil)

(defun agenda-undo-records (&optional (buffer (current-buffer)))
  (buffer-value buffer 'lem-yath-agenda-undo-records))

(defun (setf agenda-undo-records) (records &optional (buffer (current-buffer)))
  (setf (buffer-value buffer 'lem-yath-agenda-undo-records) records))

(defun agenda-undo-clear (&optional (buffer (current-buffer)))
  "Discard BUFFER's remote-undo history, as an explicit Org agenda redo does."
  (setf (agenda-undo-records buffer) nil))

(defun agenda-undo-track-buffer (buffer)
  "Register BUFFER before its first edit in the current agenda transaction."
  (when *agenda-undo-current-transaction*
    (unless (find buffer
                  (agenda-undo-record-contexts
                   *agenda-undo-current-transaction*)
                  :key #'agenda-undo-context-buffer :test #'eq)
      (buffer-undo-boundary buffer)
      (push (make-agenda-undo-context
             :buffer buffer
             :tick (buffer-modified-tick buffer))
            (agenda-undo-record-contexts
             *agenda-undo-current-transaction*))))
  buffer)

(defun agenda-undo-commit (agenda-buffer record)
  "Commit RECORD when its tracked source buffers actually changed."
  (let ((changed
          (remove-if
           (lambda (context)
             (= (agenda-undo-context-tick context)
                (buffer-modified-tick
                 (agenda-undo-context-buffer context))))
           (nreverse (agenda-undo-record-contexts record)))))
    (when changed
      (dolist (context changed)
        (buffer-undo-boundary (agenda-undo-context-buffer context)))
      (setf (agenda-undo-record-contexts record) changed
            (agenda-undo-records agenda-buffer)
            (cons record (agenda-undo-records agenda-buffer)))))
  record)

(defmacro with-agenda-undo-transaction
    ((agenda-buffer label restore-key) &body body)
  "Run BODY as one remote agenda edit and record each tracked source buffer."
  (let ((outer (gensym "OUTER"))
        (record (gensym "RECORD")))
    `(let ((,outer *agenda-undo-current-transaction*))
       (if ,outer
           (progn ,@body)
           (let ((,record
                   (make-agenda-undo-record
                    :label ,label
                    :restore-key ,restore-key)))
             (let ((*agenda-undo-current-transaction* ,record))
               (multiple-value-prog1
                   (progn ,@body)
                 (agenda-undo-commit ,agenda-buffer ,record))))))))

(defun agenda-undo-context-buffer-live-p (context)
  (let ((buffer (agenda-undo-context-buffer context)))
    (and (not (deleted-buffer-p buffer))
         (member buffer (buffer-list) :test #'eq)
         (buffer-enable-undo-p buffer))))
